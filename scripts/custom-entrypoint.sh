#!/bin/bash
set -e

MEDIAWIKI_ROOT="/var/www/html"
EXTENSIONS_MANIFEST="/extensions/.managed-manifest"
SKINS_MANIFEST="/skins/.managed-manifest"
COMPOSER_MANIFEST="/extensions/.composer-manifest"
SECRETS_FILE="/extensions/.secrets"
COMPOSER_LOCK_STORE="/config/composer.lock"
COMPOSER_FINGERPRINT_STORE="/config/composer.fingerprint"
COMPOSER_CACHE_MOUNT="/composer-cache"

# Get MediaWiki version from the installation
get_mediawiki_version() {
    if [ -f "$MEDIAWIKI_ROOT/includes/Defines.php" ]; then
        CURRENT_VERSION=$(grep "define( 'MW_VERSION'" "$MEDIAWIKI_ROOT/includes/Defines.php" | cut -d"'" -f4)
        MW_VERSION_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
        MW_VERSION_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
        export MW_VERSION_BRANCH="REL${MW_VERSION_MAJOR}_${MW_VERSION_MINOR}"
    else
        export MW_VERSION_BRANCH="REL1_43"
    fi
}

log() {
    echo "[MediaWiki Init] $1"
}

# Install additional system packages and PHP extensions at runtime
install_runtime_packages() {
    if [ -z "${MW_APT_PACKAGES}" ] && [ -z "${MW_PHP_EXTENSIONS}" ] && [ -z "${MW_PECL_EXTENSIONS}" ]; then
        return
    fi

    log "Checking runtime packages..."
    local did_apt_update=false

    if [ -n "${MW_APT_PACKAGES}" ]; then
        local missing_pkgs=""
        for pkg in ${MW_APT_PACKAGES}; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing_pkgs="$missing_pkgs $pkg"
            fi
        done
        if [ -n "$missing_pkgs" ]; then
            log "  Installing APT packages:${missing_pkgs}"
            apt-get update -qq
            did_apt_update=true
            apt-get install -y --no-install-recommends ${missing_pkgs}
        else
            log "  APT packages already installed"
        fi
    fi

    if [ -n "${MW_PHP_EXTENSIONS}" ]; then
        local missing_exts=""
        for ext in ${MW_PHP_EXTENSIONS}; do
            if ! php -m 2>/dev/null | grep -qi "^${ext}$"; then
                missing_exts="$missing_exts $ext"
            fi
        done
        if [ -n "$missing_exts" ]; then
            log "  Installing PHP extensions:${missing_exts}"
            if [ "$did_apt_update" = false ]; then
                apt-get update -qq
                did_apt_update=true
            fi
            docker-php-ext-install ${missing_exts}
        else
            log "  PHP extensions already installed"
        fi
    fi

    if [ -n "${MW_PECL_EXTENSIONS}" ]; then
        for ext in ${MW_PECL_EXTENSIONS}; do
            if ! php -m 2>/dev/null | grep -qi "^${ext}$"; then
                log "  Installing PECL extension: ${ext}"
                pecl install "$ext"
                docker-php-ext-enable "$ext"
            fi
        done
    fi

    if [ "$did_apt_update" = true ]; then
        rm -rf /var/lib/apt/lists/*
    fi
}

# Ensure secret keys are generated once and persisted
ensure_secret_keys() {
    # Load persisted secrets if they exist
    if [ -f "$SECRETS_FILE" ]; then
        source "$SECRETS_FILE"
    fi
    
    # Generate SECRET_KEY if not provided by env or persisted
    if [ -z "${MW_SECRET_KEY}" ] && [ -z "${PERSISTED_SECRET_KEY}" ]; then
        PERSISTED_SECRET_KEY=$(openssl rand -hex 32)
        echo "PERSISTED_SECRET_KEY='${PERSISTED_SECRET_KEY}'" >> "$SECRETS_FILE"
        log "Generated new SECRET_KEY (persisted in /extensions/.secrets)"
    fi
    
    # Generate UPGRADE_KEY if not provided by env or persisted
    if [ -z "${MW_UPGRADE_KEY}" ] && [ -z "${PERSISTED_UPGRADE_KEY}" ]; then
        PERSISTED_UPGRADE_KEY=$(openssl rand -hex 16)
        echo "PERSISTED_UPGRADE_KEY='${PERSISTED_UPGRADE_KEY}'" >> "$SECRETS_FILE"
        log "Generated new UPGRADE_KEY (persisted in /extensions/.secrets)"
    fi
    
    # Use env vars if provided, otherwise use persisted
    export EFFECTIVE_SECRET_KEY="${MW_SECRET_KEY:-$PERSISTED_SECRET_KEY}"
    export EFFECTIVE_UPGRADE_KEY="${MW_UPGRADE_KEY:-$PERSISTED_UPGRADE_KEY}"
}

# Replace the bundled extensions or skins on the volume with the image's copies,
# so a MediaWiki point release actually delivers its bundled-extension fixes.
# Git-managed copies are left alone.
refresh_bundled() {
    local kind="$1" src="$MEDIAWIKI_ROOT/$1" dst="/$1" name count=0
    while IFS= read -r name; do
        { [ -n "$name" ] && [ -e "$src/$name" ]; } || continue
        if [ -d "$dst/$name/.git" ]; then
            log "  $name: git-managed, keeping it"
            continue
        fi
        rm -rf "${dst:?}/$name"
        # Not cp -a, which would also copy the image's SELinux labels onto the volume
        cp -R --preserve=mode,timestamps "$src/$name" "$dst/$name"
        count=$((count + 1))
    done < "/usr/local/share/mediawiki-bundled-$kind"
    log "  Refreshed $count bundled $kind from the image"
}

# Initialize extension/skin volumes from base image
init_volumes() {
    log "Checking volumes for MediaWiki $CURRENT_VERSION..."

    local kind
    for kind in extensions skins; do
        mkdir -p "/$kind"
        if [ "$(cat "/$kind/.initialized" 2>/dev/null)" != "$CURRENT_VERSION" ]; then
            if [ -L "$MEDIAWIKI_ROOT/$kind" ]; then
                # A restarted rather than recreated container: the image's copy
                # was already replaced by the link, so there is nothing to copy.
                log "  WARNING: cannot refresh bundled $kind in a restarted container; will retry when it is recreated"
            else
                log "Syncing bundled $kind for MediaWiki $CURRENT_VERSION..."
                refresh_bundled "$kind"
                # Only after a successful copy, so a failure is retried
                echo "$CURRENT_VERSION" > "/$kind/.initialized"
            fi
        fi
    done

    # Link volumes to MediaWiki directories
    rm -rf $MEDIAWIKI_ROOT/extensions $MEDIAWIKI_ROOT/skins
    ln -sf /extensions $MEDIAWIKI_ROOT/extensions
    ln -sf /skins $MEDIAWIKI_ROOT/skins
}

# Generate stub LocalSettings.php that loads from /config
generate_stub_config() {
    if [ ! -f $MEDIAWIKI_ROOT/LocalSettings.php ]; then
        log "Generating stub LocalSettings.php..."
        cat > $MEDIAWIKI_ROOT/LocalSettings.php << 'EOF'
<?php
// Stub configuration - redirects to /config volume
$wgExtensionDirectory = "/extensions";
$wgStyleDirectory = "/skins";

// Load actual configuration
if (file_exists('/config/LocalSettings.php')) {
    require '/config/LocalSettings.php';
} else {
    die('ERROR: /config/LocalSettings.php not found. Configuration must be provided via environment variables.');
}
EOF
    fi
}

# Read previous state from manifest files
read_previous_state() {
    declare -gA PREV_EXTENSIONS
    declare -gA PREV_SKINS
    declare -gA PREV_COMPOSER
    
    if [ -f "$EXTENSIONS_MANIFEST" ]; then
        while IFS=: read -r type name source; do
            case "$type" in
                extension)
                    PREV_EXTENSIONS["$name"]="$source"
                    ;;
            esac
        done < "$EXTENSIONS_MANIFEST"
    fi
    
    if [ -f "$SKINS_MANIFEST" ]; then
        while IFS=: read -r type name source; do
            case "$type" in
                skin)
                    PREV_SKINS["$name"]="$source"
                    ;;
            esac
        done < "$SKINS_MANIFEST"
    fi
    
    if [ -f "$COMPOSER_MANIFEST" ]; then
        while IFS= read -r pkg; do
            PREV_COMPOSER["$pkg"]=1
        done < "$COMPOSER_MANIFEST"
    fi
}

# Build current desired state from environment variables
build_desired_state() {
    declare -gA DESIRED_EXTENSIONS
    declare -gA DESIRED_SKINS
    declare -gA DESIRED_COMPOSER
    declare -gA COMPOSER_PROVIDED_EXTENSIONS
    
    # Parse MW_COMPOSER_PACKAGES first to know which extensions come from Composer
    if [ -n "${MW_COMPOSER_PACKAGES}" ]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
            pkg=$(echo "$pkg" | xargs)
            pkg_name="${pkg%%:*}"
            DESIRED_COMPOSER["$pkg_name"]=1
            
            # Work out which extensions directory the package installs into.
            # MW_COMPOSER_<PACKAGE>_FOLDER wins (e.g. mediawiki/image-map ->
            # MW_COMPOSER_MEDIAWIKI_IMAGE_MAP_FOLDER); it also lets packages
            # outside the mediawiki/ vendor be loaded as extensions. Otherwise
            # guess kebab-case to PascalCase:
            #   mediawiki/page-forms         -> PageForms
            #   mediawiki/semantic-media-wiki -> SemanticMediaWiki
            local pkg_env folder_var
            pkg_env=$(echo "$pkg_name" | tr '[:lower:]' '[:upper:]' | tr '/.-' '___')
            folder_var="MW_COMPOSER_${pkg_env}_FOLDER"
            ext_name="${!folder_var}"
            if [ -n "$ext_name" ]; then
                log "  Composer will provide: ${ext_name} (from ${folder_var})"
            elif [[ "$pkg_name" =~ ^mediawiki/ ]]; then
                ext_name="${pkg_name#mediawiki/}"
                ext_name=$(echo "$ext_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1' | sed 's/ //g')
                log "  Composer will provide: ${ext_name}"
            fi
            [ -n "$ext_name" ] && COMPOSER_PROVIDED_EXTENSIONS["$ext_name"]=1
        done <<< "$MW_COMPOSER_PACKAGES"
    fi
    
    # Parse MW_EXTENSIONS
    if [ -n "${MW_EXTENSIONS}" ]; then
        while IFS= read -r ext; do
            [[ -z "$ext" || "$ext" =~ ^[[:space:]]*# ]] && continue
            ext=$(echo "$ext" | xargs)
            DESIRED_EXTENSIONS["$ext"]=1
        done <<< "$MW_EXTENSIONS"
    fi
    
    # Parse MW_SKINS
    if [ -n "${MW_SKINS}" ]; then
        while IFS= read -r skin; do
            [[ -z "$skin" || "$skin" =~ ^[[:space:]]*# ]] && continue
            skin=$(echo "$skin" | xargs)
            DESIRED_SKINS["$skin"]=1
        done <<< "$MW_SKINS"
    fi
}

# Remove extensions/skins no longer in desired state
cleanup_removed_items() {
    log "Checking for removed extensions/skins..."
    
    local removed=0
    
    # Remove extensions
    for name in "${!PREV_EXTENSIONS[@]}"; do
        # Composer-provided extensions are recorded in the manifest too, so
        # without the second check they were deleted every boot and
        # re-downloaded.
        if [ -z "${DESIRED_EXTENSIONS[$name]}" ] && [ -z "${COMPOSER_PROVIDED_EXTENSIONS[$name]}" ]; then
            log "  Removing extension: $name (no longer requested)"
            rm -rf "/extensions/$name"
            removed=1
        fi
    done
    
    # Remove skins
    for name in "${!PREV_SKINS[@]}"; do
        if [ -z "${DESIRED_SKINS[$name]}" ]; then
            log "  Removing skin: $name (no longer requested)"
            rm -rf "/skins/$name"
            removed=1
        fi
    done
    
    if [ $removed -eq 0 ]; then
        log "  No items to remove"
    fi
}

# Update existing git extension
update_git_extension() {
    local name=$1
    local ext_path="/extensions/${name}"
    
    # Get configuration
    local ext_env=$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
    local repo_var="MW_EXT_${ext_env}_REPO"
    local branch_var="MW_EXT_${ext_env}_BRANCH"
    local tag_var="MW_EXT_${ext_env}_TAG"
    local commit_var="MW_EXT_${ext_env}_COMMIT"
    local post_var="MW_EXT_${ext_env}_POST_INSTALL"
    
    local branch="${!branch_var}"
    local tag="${!tag_var}"
    local commit="${!commit_var}"
    local post_install="${!post_var}"
    
    # Default branch
    if [ -z "$branch" ] && [ -z "$tag" ] && [ -z "$commit" ]; then
        branch="$MW_VERSION_BRANCH"
    fi
    
    # Update the repository
    git -C "$ext_path" fetch --all --tags 2>/dev/null || {
        log "    WARNING: Failed to fetch updates for ${name}"
        return 0
    }
    
    if [ -n "$commit" ]; then
        git -C "$ext_path" checkout "$commit" 2>/dev/null
    elif [ -n "$tag" ]; then
        git -C "$ext_path" checkout "tags/$tag" 2>/dev/null
    elif [ -n "$branch" ]; then
        git -C "$ext_path" checkout "$branch" 2>/dev/null
        git -C "$ext_path" reset --hard "origin/$branch" 2>/dev/null || \
        git -C "$ext_path" pull 2>/dev/null || true
    fi
    
    # Run post-install
    if [ -n "$post_install" ]; then
        log "    Running post-install: ${post_install}"
        (cd "$ext_path" && bash -c "$post_install") || {
            log "    WARNING: Post-install failed for ${name}"
        }
    fi
}

# Install new git extension
install_git_extension() {
    local name=$1
    local ext_path="/extensions/${name}"
    
    # Get configuration
    local ext_env=$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
    local repo_var="MW_EXT_${ext_env}_REPO"
    local branch_var="MW_EXT_${ext_env}_BRANCH"
    local tag_var="MW_EXT_${ext_env}_TAG"
    local commit_var="MW_EXT_${ext_env}_COMMIT"
    local post_var="MW_EXT_${ext_env}_POST_INSTALL"
    
    local repo="${!repo_var}"
    local branch="${!branch_var}"
    local tag="${!tag_var}"
    local commit="${!commit_var}"
    local post_install="${!post_var}"
    
    # Apply defaults
    if [ -z "$repo" ]; then
        repo="https://gerrit.wikimedia.org/r/mediawiki/extensions/${name}"
    fi
    
    if [ -z "$branch" ] && [ -z "$tag" ] && [ -z "$commit" ]; then
        branch="$MW_VERSION_BRANCH"
    fi
    
    # Clone
    git clone "$repo" "$ext_path" || {
        log "    ERROR: Failed to clone ${name} from ${repo}"
        return 1
    }
    
    # Checkout specific ref
    if [ -n "$commit" ]; then
        git -C "$ext_path" checkout "$commit" 2>/dev/null
    elif [ -n "$tag" ]; then
        git -C "$ext_path" checkout "tags/$tag" 2>/dev/null
    elif [ -n "$branch" ]; then
        git -C "$ext_path" checkout "$branch" 2>/dev/null
    fi
    
    # Run post-install
    if [ -n "$post_install" ]; then
        log "    Running post-install: ${post_install}"
        (cd "$ext_path" && bash -c "$post_install") || {
            log "    WARNING: Post-install failed for ${name}"
        }
    fi
}

# Process Composer packages
process_composer_env() {
    if [ -z "${MW_COMPOSER_PACKAGES}" ]; then
        # Clean up composer.local.json if no packages requested
        if [ -f "$MEDIAWIKI_ROOT/composer.local.json" ]; then
            log "Removing Composer configuration (no packages requested)..."
            rm -f "$MEDIAWIKI_ROOT/composer.local.json"
        fi
        rm -f "$COMPOSER_LOCK_STORE" "$COMPOSER_FINGERPRINT_STORE"
        > "$COMPOSER_MANIFEST"
        return
    fi
    
    log "Processing Composer packages..."
    
    # Generate composer.local.json
    cat > "$MEDIAWIKI_ROOT/composer.local.json" << 'COMPOSER_START'
{
    "require": {
COMPOSER_START
    
    # Clear manifest
    > "$COMPOSER_MANIFEST"
    
    local first=true
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" =~ ^[[:space:]]*# ]] && continue
        
        pkg=$(echo "$pkg" | xargs)
        
        # Split package:version
        local pkg_name
        local pkg_version
        if [[ "$pkg" == *":"* ]]; then
            pkg_name="${pkg%%:*}"
            pkg_version="${pkg#*:}"
        else
            pkg_name="$pkg"
            pkg_version="*"
        fi
        
        # Add to manifest
        echo "$pkg_name" >> "$COMPOSER_MANIFEST"
        
        # Add comma if not first entry
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$MEDIAWIKI_ROOT/composer.local.json"
        fi
        
        echo -n "        \"${pkg_name}\": \"${pkg_version}\"" >> "$MEDIAWIKI_ROOT/composer.local.json"
        
    done <<< "$MW_COMPOSER_PACKAGES"
    
    cat >> "$MEDIAWIKI_ROOT/composer.local.json" << 'COMPOSER_END'

    }
}
COMPOSER_END

    # Fix file ownership so www-data can run Composer.
    # The upstream MW image extracts files owned by UID 1000; the entrypoint
    # runs as root (UID 0). Neither can write these files without chown.
    cd "$MEDIAWIKI_ROOT"
    chown www-data:www-data "$MEDIAWIKI_ROOT/composer.json" "$MEDIAWIKI_ROOT/composer.local.json"
    [ -f "$MEDIAWIKI_ROOT/composer.lock" ] && chown www-data:www-data "$MEDIAWIKI_ROOT/composer.lock"
    chown -R www-data:www-data "$MEDIAWIKI_ROOT/vendor"
    # composer/installers creates extension and skin directories in these
    # volumes, which are root-owned, so www-data needs write access on them.
    chown www-data:www-data /extensions /skins
    local composer_home="/var/www/.composer"
    mkdir -p "$composer_home"
    chown www-data:www-data "$composer_home"

    # Configure allow-plugins in the main composer.json so the merge plugin
    # and installer plugin are permitted. Then run composer update using the
    # main composer.json — its merge plugin pulls in composer.local.json and
    # resolves all deps together, avoiding version conflicts with MW core.
    su -s /bin/bash www-data -c 'composer config --no-plugins allow-plugins.composer/installers true'
    su -s /bin/bash www-data -c 'composer config --no-plugins allow-plugins.wikimedia/composer-merge-plugin true'

    # Merge the composer.json of every extension and skin that Composer does
    # NOT manage - bundled ones and git clones - alongside composer.local.json.
    # Without this, composer update prunes packages required only by bundled
    # extensions (OATHAuth's base32/qr-code/hotp chain, AbuseFilter's equivset).
    #
    # Composer-installed packages must be left out: their requirements are
    # already known as dependencies, and merging their composer.json into the
    # root project as well makes resolution fail. This is an allowlist rather
    # than excluding Composer packages by folder name, so a wrong folder-name
    # guess cannot break Composer.
    #
    # Paths are enumerated rather than passed as an "extensions/*" glob:
    # merge-plugin does not expand wildcards through the symlinked extensions
    # and skins directories, and silently merges nothing.
    local includes='"composer.local.json"'
    local merged=()
    local cfg dir kind name
    for cfg in extensions/*/composer.json skins/*/composer.json; do
        [ -f "$cfg" ] || continue
        dir="${cfg%/composer.json}"
        kind="${dir%%/*}"
        name="${dir#*/}"
        if [ -d "$dir/.git" ] || grep -qxF "$name" "/usr/local/share/mediawiki-bundled-${kind}" 2>/dev/null; then
            includes="${includes},\"${cfg}\""
            merged+=("$cfg")
        fi
    done
    su -s /bin/bash www-data -c "composer config --no-plugins --json extra.merge-plugin.include '[${includes}]'"

    # Resolve on every start so floating constraints pick up new releases, the
    # same way git-managed extensions pull on every start; pin a version in
    # MW_COMPOSER_PACKAGES to hold it. The last successful result is kept as a
    # fallback for when resolution fails (e.g. Packagist is unreachable), but
    # only when nothing that affects resolution has changed since: the image
    # (core's composer.json, its bundled libraries and Composer itself), the
    # requested packages, and every merged composer.json. Otherwise an old lock
    # could reinstall stale core libraries over a newer image.
    local fingerprint saved_fp=""
    fingerprint=$(cat /usr/local/share/mediawiki-image-fingerprint composer.local.json "${merged[@]}" | sha256sum | cut -d' ' -f1)
    [ -f "$COMPOSER_FINGERPRINT_STORE" ] && saved_fp=$(cat "$COMPOSER_FINGERPRINT_STORE")

    # Optional download cache volume, so unchanged packages are served locally
    local cache_env=""
    if [ -d "$COMPOSER_CACHE_MOUNT" ]; then
        chown www-data:www-data "$COMPOSER_CACHE_MOUNT"
        cache_env="COMPOSER_CACHE_DIR=$COMPOSER_CACHE_MOUNT "
        log "  Using Composer download cache at $COMPOSER_CACHE_MOUNT"
    fi

    log "  Resolving package versions..."
    rm -f composer.lock
    if su -s /bin/bash www-data -c "${cache_env}composer update --no-dev --no-interaction"; then
        cp composer.lock "$COMPOSER_LOCK_STORE"
        printf '%s\n' "$fingerprint" > "$COMPOSER_FINGERPRINT_STORE"
        log "  Saved as last known good: $COMPOSER_LOCK_STORE"
        return 0
    fi

    if [ -f "$COMPOSER_LOCK_STORE" ] && [ "$fingerprint" = "$saved_fp" ]; then
        log "  WARNING: Composer update failed - installing last known good versions from $COMPOSER_LOCK_STORE"
        cp "$COMPOSER_LOCK_STORE" composer.lock
        chown www-data:www-data composer.lock
        if su -s /bin/bash www-data -c "${cache_env}composer install --no-dev --no-interaction"; then
            return 0
        fi
    fi

    log "  ERROR: Composer update failed"
    return 1
}

# Process extensions from environment
process_extensions() {
    log "Processing extensions..."

    # Clear manifest and load tracking
    > "$EXTENSIONS_MANIFEST"
    > /tmp/extension_loads.txt

    if [ -z "${MW_EXTENSIONS}" ]; then
        return
    fi

    while IFS= read -r ext; do
        [[ -z "$ext" || "$ext" =~ ^[[:space:]]*# ]] && continue
        ext=$(echo "$ext" | xargs)
        local ext_path="/extensions/${ext}"
        
        # Check if this extension is provided by Composer
        if [ -n "${COMPOSER_PROVIDED_EXTENSIONS[$ext]}" ]; then
            log "  ${ext}: Provided by Composer (skipping git)"
            echo "extension:${ext}:composer" >> "$EXTENSIONS_MANIFEST"
        elif [ -d "$ext_path/.git" ]; then
            log "  ${ext}: Updating..."
            update_git_extension "$ext"
            echo "extension:${ext}:git" >> "$EXTENSIONS_MANIFEST"
        elif [ -d "$ext_path" ] && [ "$(ls -A $ext_path 2>/dev/null)" ]; then
            log "  ${ext}: Already exists (from Composer or bundled, skipping git)"
            echo "extension:${ext}:existing" >> "$EXTENSIONS_MANIFEST"
        else
            log "  ${ext}: Installing..."
            install_git_extension "$ext"
            if [ $? -eq 0 ]; then
                echo "extension:${ext}:git" >> "$EXTENSIONS_MANIFEST"
            fi
        fi
        
        # Add load command
        local ext_env=$(echo "$ext" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
        local load_var="MW_EXT_${ext_env}_LOAD"
        local load_cmd="${!load_var}"
        
        if [ -z "$load_cmd" ]; then
            load_cmd="wfLoadExtension( '${ext}' );"
        fi
        
        echo "$load_cmd" >> /tmp/extension_loads.txt

    done <<< "$MW_EXTENSIONS"
}

# Composer-installed extensions still need wfLoadExtension(). Without this,
# a package listed only in MW_COMPOSER_PACKAGES is installed into
# /extensions but never registered, so MediaWiki ignores it entirely.
load_composer_extensions() {
    local ext
    for ext in "${!COMPOSER_PROVIDED_EXTENSIONS[@]}"; do
        # Already handled by the MW_EXTENSIONS loop
        [ -n "${DESIRED_EXTENSIONS[$ext]}" ] && continue

        local ext_env load_var load_cmd
        ext_env=$(echo "$ext" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
        load_var="MW_EXT_${ext_env}_LOAD"
        load_cmd="${!load_var}"

        # Only emit a default wfLoadExtension() when its manifest is actually
        # readable. The package-name-to-directory guess can be wrong, and a
        # directory can exist while being unreadable (an SELinux MCS label from
        # the container that created it, for instance). Either way MediaWiki
        # would abort with a configuration error and take the whole wiki down,
        # so skip and say so instead. A custom LOAD override is trusted as-is.
        if [ -z "$load_cmd" ] && [ ! -r "/extensions/${ext}/extension.json" ]; then
            if [ -d "/extensions/${ext}" ]; then
                log "  ${ext}: /extensions/${ext}/extension.json unreadable - not loading"
            else
                log "  ${ext}: Composer package installed but /extensions/${ext} not found - not loading"
            fi
            continue
        fi

        log "  ${ext}: Loading (installed by Composer)"
        echo "extension:${ext}:composer" >> "$EXTENSIONS_MANIFEST"

        [ -z "$load_cmd" ] && load_cmd="wfLoadExtension( '${ext}' );"
        echo "$load_cmd" >> /tmp/extension_loads.txt
    done
}

# Update existing git skin
update_git_skin() {
    local name=$1
    local skin_path="/skins/${name}"
    
    # Get configuration
    local skin_env=$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
    local repo_var="MW_SKIN_${skin_env}_REPO"
    local branch_var="MW_SKIN_${skin_env}_BRANCH"
    local tag_var="MW_SKIN_${skin_env}_TAG"
    local post_var="MW_SKIN_${skin_env}_POST_INSTALL"
    
    local branch="${!branch_var}"
    local tag="${!tag_var}"
    local post_install="${!post_var}"
    
    # Default branch
    if [ -z "$branch" ] && [ -z "$tag" ]; then
        branch="$MW_VERSION_BRANCH"
    fi
    
    # Update the repository
    git -C "$skin_path" fetch --all --tags 2>/dev/null || {
        log "    WARNING: Failed to fetch updates for ${name}"
        return 0
    }
    
    if [ -n "$tag" ]; then
        git -C "$skin_path" checkout "tags/$tag" 2>/dev/null
    elif [ -n "$branch" ]; then
        git -C "$skin_path" checkout "$branch" 2>/dev/null
        git -C "$skin_path" reset --hard "origin/$branch" 2>/dev/null || \
        git -C "$skin_path" pull 2>/dev/null || true
    fi
    
    # Run post-install
    if [ -n "$post_install" ]; then
        log "    Running post-install: ${post_install}"
        (cd "$skin_path" && bash -c "$post_install")
    fi
}

# Install new git skin
install_git_skin() {
    local name=$1
    local skin_path="/skins/${name}"
    
    # Get configuration
    local skin_env=$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr ' ' '_')
    local repo_var="MW_SKIN_${skin_env}_REPO"
    local branch_var="MW_SKIN_${skin_env}_BRANCH"
    local tag_var="MW_SKIN_${skin_env}_TAG"
    local post_var="MW_SKIN_${skin_env}_POST_INSTALL"
    
    local repo="${!repo_var}"
    local branch="${!branch_var}"
    local tag="${!tag_var}"
    local post_install="${!post_var}"
    
    # Apply defaults
    if [ -z "$repo" ]; then
        repo="https://gerrit.wikimedia.org/r/mediawiki/skins/${name}"
    fi
    
    if [ -z "$branch" ] && [ -z "$tag" ]; then
        branch="$MW_VERSION_BRANCH"
    fi
    
    # Clone
    git clone "$repo" "$skin_path" || {
        log "    ERROR: Failed to clone ${name} from ${repo}"
        return 1
    }
    
    # Checkout specific ref
    if [ -n "$tag" ]; then
        git -C "$skin_path" checkout "tags/$tag" 2>/dev/null
    elif [ -n "$branch" ]; then
        git -C "$skin_path" checkout "$branch" 2>/dev/null
    fi
    
    # Run post-install
    if [ -n "$post_install" ]; then
        log "    Running post-install: ${post_install}"
        (cd "$skin_path" && bash -c "$post_install")
    fi
}

# Process skins from environment
process_skins() {
    if [ -z "${MW_SKINS}" ]; then
        # Clear manifest if no skins requested
        > "$SKINS_MANIFEST"
        return
    fi
    
    log "Processing skins..."
    
    # Clear manifest and load tracking
    > "$SKINS_MANIFEST"
    > /tmp/skin_loads.txt
    
    while IFS= read -r skin; do
        [[ -z "$skin" || "$skin" =~ ^[[:space:]]*# ]] && continue
        skin=$(echo "$skin" | xargs)
        local skin_path="/skins/${skin}"
        
        if [ -d "$skin_path/.git" ]; then
            log "  ${skin}: Updating..."
            update_git_skin "$skin"
            echo "skin:${skin}:git" >> "$SKINS_MANIFEST"
        elif [ -d "$skin_path" ] && [ "$(ls -A $skin_path 2>/dev/null)" ]; then
            log "  ${skin}: Already exists (bundled or from Composer)"
            echo "skin:${skin}:bundled" >> "$SKINS_MANIFEST"
        else
            log "  ${skin}: Installing..."
            install_git_skin "$skin"
            if [ $? -eq 0 ]; then
                echo "skin:${skin}:git" >> "$SKINS_MANIFEST"
            fi
        fi
        
        # Add load command
        echo "wfLoadSkin( '${skin}' );" >> /tmp/skin_loads.txt
        
    done <<< "$MW_SKINS"
}

# Generate LocalSettings.php from environment variables
generate_localsettings() {
    log "Generating LocalSettings.php from environment variables..."

    mkdir -p /config

    # Quoted heredoc ('EOF') prevents shell expansion — PHP $variables are written literally
    cat > /config/LocalSettings.php << 'EOF'
<?php
# Generated from environment variables
# Configuration is 100% managed via docker-compose.yml

# Database
$wgDBserver = getenv('MW_DB_SERVER');
$wgDBname = getenv('MW_DB_NAME');
$wgDBuser = getenv('MW_DB_USER');
$wgDBpassword = getenv('MW_DB_PASSWORD');
$wgDBtype = getenv('MW_DB_TYPE') ?: 'mysql';
$wgDBprefix = getenv('MW_DB_PREFIX') ?: '';

# Site
$wgSitename = getenv('MW_SITE_NAME');
$wgLanguageCode = getenv('MW_SITE_LANG') ?: 'en';
$wgServer = getenv('MW_SITE_SERVER');
# Apache serves MediaWiki from the document root in this image. Without this,
# $wgScriptPath keeps its core default of '/wiki' and every canonical URL
# points at a path that does not exist.
$wgScriptPath = getenv('MW_SCRIPT_PATH') ?: '';

# Email
$wgEmergencyContact = getenv('MW_EMERGENCY_CONTACT') ?: '';
$wgPasswordSender = getenv('MW_PASSWORD_SENDER') ?: '';
$wgEnableEmail = getenv('MW_ENABLE_EMAIL') === 'true';
$wgEnableUserEmail = getenv('MW_ENABLE_USER_EMAIL') === 'true';

# Uploads
$wgEnableUploads = getenv('MW_ENABLE_UPLOADS') === 'true';
# An empty logo makes getAvailableLogos() yield no '1x' entry, and the
# siteinfo API then calls UrlUtils::expand(null) and throws a TypeError.
# Fall back to core's placeholder, which is what install.php writes.
$wgLogo = getenv('MW_LOGO') ?: '/resources/assets/change-your-logo.svg';

# Authentication
$wgAuthenticationTokenVersion = "1";

# Permissions
$wgGroupPermissions['*']['edit'] = getenv('MW_ALLOW_ANONYMOUS_EDIT') === 'true';

EOF

    # Secret keys need shell expansion — separate unquoted heredoc with escaped PHP $
    cat >> /config/LocalSettings.php << EOF

# Secret keys (persisted across restarts in /extensions/.secrets)
\$wgSecretKey = '${EFFECTIVE_SECRET_KEY}';
\$wgUpgradeKey = '${EFFECTIVE_UPGRADE_KEY}';
EOF

    # Add skin loads
    if [ -f /tmp/skin_loads.txt ]; then
        printf '\n# Skins\n' >> /config/LocalSettings.php
        cat /tmp/skin_loads.txt >> /config/LocalSettings.php
    fi

    # Set default skin
    if [ -n "${MW_SKIN_DEFAULT}" ]; then
        printf "\$wgDefaultSkin = '%s';\n" "${MW_SKIN_DEFAULT}" >> /config/LocalSettings.php
    fi

    # Add extension loads
    if [ -f /tmp/extension_loads.txt ]; then
        printf '\n# Extensions\n' >> /config/LocalSettings.php
        cat /tmp/extension_loads.txt >> /config/LocalSettings.php
    fi

    # Append custom config from file (recommended for complex PHP config with $ variables)
    if [ -n "${MW_CONFIG_FILE}" ]; then
        if [ -f "${MW_CONFIG_FILE}" ]; then
            log "Appending custom config from ${MW_CONFIG_FILE}"
            printf '\n# Custom Configuration (from %s)\n' "${MW_CONFIG_FILE}" >> /config/LocalSettings.php
            cat "${MW_CONFIG_FILE}" >> /config/LocalSettings.php
        else
            log "WARNING: MW_CONFIG_FILE set to '${MW_CONFIG_FILE}' but file not found"
        fi
    fi

    # Append custom config from environment variable
    # In docker-compose.yml, literal $ must be written as $$ due to Compose interpolation
    if [ -n "${MW_CONFIG_APPEND}" ]; then
        printf '\n# Custom Configuration\n' >> /config/LocalSettings.php
        printf '%s\n' "${MW_CONFIG_APPEND}" >> /config/LocalSettings.php
    fi
}

# Run database update (critical for version upgrades)
# True when the wiki schema already exists in the database.
# sql.php can exit 0 while reporting a missing table, so the output is
# inspected as well as the exit status.
wiki_is_installed() {
    cd "$MEDIAWIKI_ROOT"
    local out rc
    out=$(php maintenance/run.php sql.php --query="SELECT 1 FROM ${MW_DB_PREFIX:-}user LIMIT 1" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qiE "doesn't exist|does not exist|no such table|unknown table|error"; then
        log "  No wiki schema detected (sql.php rc=${rc})"
        return 1
    fi
    log "  Wiki schema present"
    return 0
}

# Install MediaWiki into an empty database. update.php cannot bootstrap a
# fresh database - it fails with "Can not upgrade from versions older than
# 1.35" - so a greenfield wiki needs install.php first.
run_database_install() {
    log "Checking database installation state..."
    if [ ! -f "$MEDIAWIKI_ROOT/LocalSettings.php" ]; then
        log "  No LocalSettings.php yet - skipping install check"
        return 0
    fi
    cd "$MEDIAWIKI_ROOT"

    if wiki_is_installed; then
        return 0
    fi

    if [ -z "${MW_ADMIN_PASSWORD}" ]; then
        log "Database is empty but MW_ADMIN_PASSWORD is not set - skipping install."
        log "  Set MW_ADMIN_PASSWORD to auto-install, or restore a database dump."
        return 0
    fi

    log "Empty database detected - running install.php..."
    local confdir="/tmp/mw-install"
    mkdir -p "$confdir"

    # install.php refuses to run while a LocalSettings.php is present, and we
    # generate our own, so move the stub aside for the duration.
    mv "$MEDIAWIKI_ROOT/LocalSettings.php" "$confdir/LocalSettings.stub.php"

    local install_status=0
    php maintenance/run.php install.php \
        --dbtype="${MW_DB_TYPE:-mysql}" \
        --dbserver="${MW_DB_SERVER}" \
        --dbname="${MW_DB_NAME}" \
        --dbuser="${MW_DB_USER}" \
        --dbpass="${MW_DB_PASSWORD}" \
        --server="${MW_SITE_SERVER}" \
        --scriptpath="" \
        --lang="${MW_SITE_LANG:-en}" \
        --pass="${MW_ADMIN_PASSWORD}" \
        --confpath="$confdir" \
        "${MW_SITE_NAME:-MediaWiki}" "${MW_ADMIN_USER:-Admin}" || install_status=$?

    mv "$confdir/LocalSettings.stub.php" "$MEDIAWIKI_ROOT/LocalSettings.php"
    rm -f "$confdir/LocalSettings.php"

    if [ "$install_status" -ne 0 ]; then
        log "ERROR: install.php failed"
        return 1
    fi
    log "  Install complete (admin user: ${MW_ADMIN_USER:-Admin})"
}

run_database_update() {
    if [ -f "$MEDIAWIKI_ROOT/LocalSettings.php" ]; then
        log "Running database updates (update.php)..."
        cd "$MEDIAWIKI_ROOT"
        php maintenance/run.php update.php --quick || {
            log "WARNING: Database update failed or had issues"
        }
    fi
}

# Main execution
main() {
    log "=== MediaWiki Managed Docker ===" 
    log "Repository: https://github.com/nkcx/mediawiki-docker"
    log "Configuration: 100% environment variables"
    log ""
    
    get_mediawiki_version
    log "MediaWiki version: $CURRENT_VERSION"
    log "Default branch: $MW_VERSION_BRANCH"
    log ""

    install_runtime_packages

    ensure_secret_keys
    init_volumes
    
    # Read what was installed previously
    read_previous_state
    
    # Build what should be installed now
    build_desired_state
    
    # Clean up removed items FIRST
    cleanup_removed_items
    
    # Git-managed extensions and skins first, so their own composer.json
    # files are on disk when Composer builds its merge list
    process_extensions
    process_skins

    # Composer (updates existing, installs new), then register what it installed
    process_composer_env
    load_composer_extensions
    
    # Generate LocalSettings.php
    generate_localsettings
    
    generate_stub_config
    
    # Bootstrap an empty database before update.php, which cannot install one
    run_database_install

    # Always run database updates by default (MW_AUTO_UPDATE defaults to true)
    if [ "${MW_AUTO_UPDATE:-true}" = "true" ]; then
        run_database_update
    else
        log "Skipping database update (MW_AUTO_UPDATE=false)"
    fi
    
    log ""
    log "=== Initialization complete ==="
    exec docker-php-entrypoint "$@"
}

# Run main
main "$@"
