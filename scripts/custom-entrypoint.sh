#!/bin/bash
set -e

MEDIAWIKI_ROOT="/var/www/html"
EXTENSIONS_MANIFEST="/extensions/.managed-manifest"
SKINS_MANIFEST="/skins/.managed-manifest"
COMPOSER_MANIFEST="/extensions/.composer-manifest"
SECRETS_FILE="/extensions/.secrets"

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

# Initialize extension/skin volumes from base image
init_volumes() {
    log "Checking volumes for MediaWiki $CURRENT_VERSION..."
    
    # Extensions
    if [ ! -f /extensions/.initialized ] || [ "$(cat /extensions/.initialized 2>/dev/null)" != "$CURRENT_VERSION" ]; then
        log "Syncing base extensions..."
        mkdir -p /extensions
        cp -rn $MEDIAWIKI_ROOT/extensions/* /extensions/ 2>/dev/null || true
        echo "$CURRENT_VERSION" > /extensions/.initialized
    fi
    
    # Skins
    if [ ! -f /skins/.initialized ] || [ "$(cat /skins/.initialized 2>/dev/null)" != "$CURRENT_VERSION" ]; then
        log "Syncing base skins..."
        mkdir -p /skins
        cp -rn $MEDIAWIKI_ROOT/skins/* /skins/ 2>/dev/null || true
        echo "$CURRENT_VERSION" > /skins/.initialized
    fi
    
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
            
            # Track which extensions are provided by Composer
            # Common patterns: 
            # - mediawiki/page-forms -> PageForms
            # - mediawiki/semantic-media-wiki -> SemanticMediaWiki
            if [[ "$pkg_name" =~ ^mediawiki/ ]]; then
                ext_name="${pkg_name#mediawiki/}"
                # Convert kebab-case to PascalCase
                ext_name=$(echo "$ext_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1' | sed 's/ //g')
                COMPOSER_PROVIDED_EXTENSIONS["$ext_name"]=1
                log "  Composer will provide: ${ext_name}"
            fi
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
        if [ -z "${DESIRED_EXTENSIONS[$name]}" ]; then
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
    
    # Run composer update (not install) to update existing packages
    log "  Running composer update..."
    cd "$MEDIAWIKI_ROOT"
    COMPOSER=composer.local.json composer update --no-dev --no-interaction || {
        log "  ERROR: Composer update failed"
        return 1
    }
}

# Process extensions from environment
process_extensions() {
    if [ -z "${MW_EXTENSIONS}" ]; then
        # Clear manifest if no extensions requested
        > "$EXTENSIONS_MANIFEST"
        return
    fi
    
    log "Processing extensions..."
    
    # Clear manifest and load tracking
    > "$EXTENSIONS_MANIFEST"
    > /tmp/extension_loads.txt
    
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
    
    cat > /config/LocalSettings.php << EOF
<?php
# Generated from environment variables
# Configuration is 100% managed via docker-compose.yml

# Database
\$wgDBserver = getenv('MW_DB_SERVER');
\$wgDBname = getenv('MW_DB_NAME');
\$wgDBuser = getenv('MW_DB_USER');
\$wgDBpassword = getenv('MW_DB_PASSWORD');
\$wgDBtype = getenv('MW_DB_TYPE') ?: 'mysql';
\$wgDBprefix = getenv('MW_DB_PREFIX') ?: '';

# Site
\$wgSitename = getenv('MW_SITE_NAME');
\$wgLanguageCode = getenv('MW_SITE_LANG') ?: 'en';
\$wgServer = getenv('MW_SITE_SERVER');

# Email
\$wgEmergencyContact = getenv('MW_EMERGENCY_CONTACT') ?: '';
\$wgPasswordSender = getenv('MW_PASSWORD_SENDER') ?: '';
\$wgEnableEmail = getenv('MW_ENABLE_EMAIL') === 'true';
\$wgEnableUserEmail = getenv('MW_ENABLE_USER_EMAIL') === 'true';

# Uploads
\$wgEnableUploads = getenv('MW_ENABLE_UPLOADS') === 'true';
\$wgLogo = getenv('MW_LOGO') ?: '';

# Secret keys (persisted across restarts in /extensions/.secrets)
# These are auto-generated on first boot if not provided via MW_SECRET_KEY/MW_UPGRADE_KEY
\$wgSecretKey = '${EFFECTIVE_SECRET_KEY}';
\$wgUpgradeKey = '${EFFECTIVE_UPGRADE_KEY}';

# Authentication
\$wgAuthenticationTokenVersion = "1";

# Permissions
\$wgGroupPermissions['*']['edit'] = getenv('MW_ALLOW_ANONYMOUS_EDIT') === 'true';

EOF

    # Add skin loads
    if [ -f /tmp/skin_loads.txt ]; then
        echo "" >> /config/LocalSettings.php
        echo "# Skins" >> /config/LocalSettings.php
        cat /tmp/skin_loads.txt >> /config/LocalSettings.php
    fi
    
    # Set default skin
    if [ -n "${MW_SKIN_DEFAULT}" ]; then
        echo "\$wgDefaultSkin = '${MW_SKIN_DEFAULT}';" >> /config/LocalSettings.php
    fi

    # Add extension loads
    if [ -f /tmp/extension_loads.txt ]; then
        echo "" >> /config/LocalSettings.php
        echo "# Extensions" >> /config/LocalSettings.php
        cat /tmp/extension_loads.txt >> /config/LocalSettings.php
    fi
    
    # Append custom config
    if [ -n "${MW_CONFIG_APPEND}" ]; then
        echo "" >> /config/LocalSettings.php
        echo "# Custom Configuration" >> /config/LocalSettings.php
        echo "${MW_CONFIG_APPEND}" >> /config/LocalSettings.php
    fi
}

# Run database update (critical for version upgrades)
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
    
    ensure_secret_keys
    init_volumes
    
    # Read what was installed previously
    read_previous_state
    
    # Build what should be installed now
    build_desired_state
    
    # Clean up removed items FIRST
    cleanup_removed_items
    
    # Process Composer (updates existing, installs new)
    process_composer_env
    
    # Process extensions (updates existing, installs new)
    process_extensions
    
    # Process skins (same pattern)
    process_skins
    
    # Generate LocalSettings.php
    generate_localsettings
    
    generate_stub_config
    
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
main
