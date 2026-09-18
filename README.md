# MediaWiki Managed Docker Image

A declarative, configuration-first approach to running MediaWiki in Docker. Configure your entire MediaWiki installation—including extensions, skins, and settings—through environment variables in your `docker-compose.yml` file.

## Key Features

- **100% Environment Variable Configuration**: All configuration via docker-compose.yml
- **Auto-Update Extensions**: Extensions and skins update automatically on container restart
- **State Management**: Automatically removes extensions/skins when removed from config
- **Persistent Secrets**: Secret keys generated once and persisted across restarts
- **Version Change Detection**: Automatically runs database updates when MediaWiki version changes
- **Watchtower Compatible**: Base image updates work seamlessly
- **Convention over Configuration**: Sensible defaults with override capability
- **Composer Support**: Manage packages alongside git-based extensions

## Quick Start

```yaml
version: '3.8'

services:
  mediawiki:
    image: ghcr.io/nkcx/mediawiki-docker:1.43
    ports:
      - "8080:80"
    volumes:
      - config:/config
      - extensions:/extensions
      - skins:/skins
      - uploads:/var/www/html/images
    environment:
      # Database
      MW_DB_SERVER: database
      MW_DB_NAME: mediawiki
      MW_DB_USER: wikiuser
      MW_DB_PASSWORD: wikipass
      
      # Site
      MW_SITE_NAME: "My Wiki"
      MW_SITE_LANG: en
      MW_SITE_SERVER: "http://localhost:8080"
      
      # Extensions (line-separated)
      MW_EXTENSIONS: |
        Cite
        ParserFunctions
        VisualEditor
      
      # Skins
      MW_SKINS: |
        Vector
        Timeless
      
      MW_AUTO_UPDATE: "true"
    depends_on:
      - database

  database:
    image: mariadb:10.11
    volumes:
      - db:/var/lib/mysql
    environment:
      MYSQL_DATABASE: mediawiki
      MYSQL_USER: wikiuser
      MYSQL_PASSWORD: wikipass
      MYSQL_ROOT_PASSWORD: rootpass

volumes:
  config:
  extensions:
  skins:
  uploads:
  db:
```

## Environment Variables Reference

### Core Database Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MW_DB_SERVER` | Yes | - | Database hostname (e.g., `database` for docker-compose) |
| `MW_DB_NAME` | Yes | - | Database name |
| `MW_DB_USER` | Yes | - | Database username |
| `MW_DB_PASSWORD` | Yes | - | Database password |
| `MW_DB_TYPE` | No | `mysql` | Database type (`mysql` or `postgres`) |
| `MW_DB_PREFIX` | No | `""` | Table prefix (empty by default) |

### Site Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MW_SITE_NAME` | Yes | - | Wiki name displayed in title |
| `MW_SITE_LANG` | No | `en` | Language code (e.g., `en`, `de`, `fr`) |
| `MW_SITE_SERVER` | Yes | - | Full URL to your wiki (e.g., `http://localhost:8080`) |
| `MW_SCRIPT_PATH` | No | `""` | URL path MediaWiki is served from. Empty (document root) suits this image; MediaWiki's own default of `/wiki` would break canonical URLs |
| `MW_EMERGENCY_CONTACT` | No | `""` | Email for emergency contact |
| `MW_PASSWORD_SENDER` | No | `""` | Email address for password resets |

### First-Time Installation

An empty database cannot be bootstrapped by `update.php`. When the entrypoint
detects that no wiki schema exists, it runs `install.php` first — but only if
`MW_ADMIN_PASSWORD` is set. Without it, the wiki is left uninstalled and a
message is logged, so that restoring a database dump is never overwritten.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MW_ADMIN_USER` | No | `Admin` | Administrator account created on first install |
| `MW_ADMIN_PASSWORD` | No | - | Administrator password. If unset, no install is attempted |

### Email Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MW_ENABLE_EMAIL` | `false` | Enable email functionality |
| `MW_ENABLE_USER_EMAIL` | `false` | Allow users to email each other |

### Uploads Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MW_ENABLE_UPLOADS` | `false` | Enable file uploads |
| `MW_LOGO` | `""` | Path to logo file (e.g., `/images/logo.png`) |

### Security Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MW_SECRET_KEY` | auto-generated | Secret key for cookies. If not provided, one is generated and persisted in `/config/.secrets` |
| `MW_UPGRADE_KEY` | auto-generated | Key for running upgrades. If not provided, one is generated and persisted in `/config/.secrets` |
| `MW_ALLOW_ANONYMOUS_EDIT` | `false` | Allow anonymous users to edit pages |

**Important**: Secret keys are automatically generated on first run and stored in `/config/.secrets` within the `config` volume. They persist across container restarts. To regenerate them, delete the `/config/.secrets` file or set explicit values via environment variables.

### Extensions Management

#### MW_EXTENSIONS

**Format**: Line-separated list of extension names

**Example**:
```yaml
MW_EXTENSIONS: |
  Cite
  ParserFunctions
  VisualEditor
  SyntaxHighlight_GeSHi
```

**Default Behavior**:
- Repository: `https://gerrit.wikimedia.org/r/mediawiki/extensions/<ExtensionName>`
- Branch: Matches MediaWiki version (e.g., `REL1_43`)
- Load: `wfLoadExtension('<ExtensionName>');`

#### Extension-Specific Overrides

Format: `MW_EXT_<NAME>_<FEATURE>`

**Name Transformation Rules**:
- Convert to UPPERCASE
- Replace hyphens with underscores
- Replace spaces with underscores

**Examples**:
- `Cite` → `MW_EXT_CITE_`
- `VisualEditor` → `MW_EXT_VISUALEDITOR_`
- `SyntaxHighlight_GeSHi` → `MW_EXT_SYNTAXHIGHLIGHT_GESHI_`
- `My-Custom-Extension` → `MW_EXT_MY_CUSTOM_EXTENSION_`

#### Available Extension Overrides

| Override Variable | Description | Example |
|-------------------|-------------|---------|
| `MW_EXT_<NAME>_REPO` | Git repository URL | `https://github.com/me/MyExtension` |
| `MW_EXT_<NAME>_BRANCH` | Git branch to use | `master`, `REL1_39` |
| `MW_EXT_<NAME>_TAG` | Git tag (overrides branch) | `v2.1.0` |
| `MW_EXT_<NAME>_COMMIT` | Specific commit hash | `abc123def456` |
| `MW_EXT_<NAME>_POST_INSTALL` | Shell commands after install | `composer install --no-dev` |
| `MW_EXT_<NAME>_LOAD` | Custom load command | `require_once "$IP/extensions/Ext/Ext.php";` |

#### Extension Override Examples

```yaml
environment:
  MW_EXTENSIONS: |
    Cite
    VisualEditor
    MyCustomExtension
  
  # Use master branch for Cite instead of release branch
  MW_EXT_CITE_BRANCH: "master"
  
  # VisualEditor needs submodules initialized
  MW_EXT_VISUALEDITOR_POST_INSTALL: "git submodule update --init"
  
  # Custom extension from GitHub
  MW_EXT_MYCUSTOMEXTENSION_REPO: "https://github.com/me/MyCustomExtension"
  MW_EXT_MYCUSTOMEXTENSION_BRANCH: "main"
  MW_EXT_MYCUSTOMEXTENSION_POST_INSTALL: "composer install --no-dev"
```

### Skins Management

#### MW_SKINS

**Format**: Line-separated list of skin names

**Example**:
```yaml
MW_SKINS: |
  Vector
  Timeless
  Monobook
```

**Default Behavior**:
- Repository: `https://gerrit.wikimedia.org/r/mediawiki/skins/<SkinName>`
- Branch: Matches MediaWiki version (e.g., `REL1_39`)
- Load: `wfLoadSkin('<SkinName>');`

#### MW_SKIN_DEFAULT

Set the default skin for your wiki:

```yaml
MW_SKIN_DEFAULT: "Vector"
```

#### Skin-Specific Overrides

Format: `MW_SKIN_<NAME>_<FEATURE>`

**Available Skin Overrides**:

| Override Variable | Description | Example |
|-------------------|-------------|---------|
| `MW_SKIN_<NAME>_REPO` | Git repository URL | `https://github.com/me/MySkin` |
| `MW_SKIN_<NAME>_BRANCH` | Git branch to use | `master`, `REL1_39` |
| `MW_SKIN_<NAME>_TAG` | Git tag | `v1.2.0` |
| `MW_SKIN_<NAME>_POST_INSTALL` | Shell commands after install | `npm install && npm run build` |

#### Skin Override Example

```yaml
environment:
  MW_SKINS: |
    Vector
    MyCustomSkin
  
  MW_SKIN_DEFAULT: "Vector"
  
  MW_SKIN_MYCUSTOMSKIN_REPO: "https://github.com/me/MyCustomSkin"
  MW_SKIN_MYCUSTOMSKIN_BRANCH: "develop"
  MW_SKIN_MYCUSTOMSKIN_POST_INSTALL: "npm install && npm run build"
```

### Composer Packages

#### MW_COMPOSER_PACKAGES

**Format**: Line-separated list of `package:version` pairs

**Example**:
```yaml
MW_COMPOSER_PACKAGES: |
  mediawiki/semantic-media-wiki:~4.0
  mediawiki/page-forms:^5.3
  wikimedia/parsoid:*
```

**Notes**:
- If no version is specified it defaults to `*`, which means the **newest release**, not the newest one compatible with your MediaWiki. Extensions declare their supported MediaWiki versions in `extension.json`, which Composer never reads, so it cannot tell. An incompatible extension stops the whole wiki from starting. Pin versions, e.g. `mediawiki/lingo:~3.2.0` (Lingo 3.3.0 requires MediaWiki 1.45)
- Extensions installed via Composer are loaded automatically; listing them in `MW_EXTENSIONS` as well is optional
- Git-managed extensions are fetched before Composer runs, so their own `composer.json` dependencies are installed on the first start
- `composer update` runs on every container start, the same way git-managed extensions pull on every start. A floating constraint such as `^14` or `*` picks up new releases on restart; pin a constraint such as `14.2.1` to hold a version
- Mount the optional `vendor` volume (below) so installed packages persist like on a normal install. Composer then only changes what has actually changed, and if it cannot reach Packagist the start continues with the installed versions. Without the volume, packages are reinstalled on every start and a failed update stops the container
- A new release that installs cleanly but is incompatible with your MediaWiki will still be picked up, since Composer cannot see MediaWiki compatibility. Pin anything you cannot afford to have change under you

#### Persisting vendor/ (recommended)

```yaml
volumes:
  - vendor:/var/www/html/vendor:z
```

Mount it at exactly this path, not via a symlink: Composer's autoloader derives file locations from the real path of `vendor/`. It holds core's own libraries as well as Composer packages, so whenever the image changes (a MediaWiki upgrade, or a rebuild) the entrypoint restores core's copy from the image and `composer update` re-adds your packages. That step needs network access.

#### Composer download cache (optional)

Mount a volume at `/composer-cache` to keep Composer's downloads between containers. Packages whose version has not changed are then installed from the cache rather than downloaded again, which mostly matters without the `vendor` volume or after an image upgrade.

```yaml
volumes:
  - composer-cache:/composer-cache:z
```

#### Extension folder names

To load a Composer-installed extension, the entrypoint needs the directory Composer put it in. For `mediawiki/` packages it converts the package name from kebab-case to PascalCase:

| Package | Assumed folder |
|---------|----------------|
| `mediawiki/page-forms` | `PageForms` |
| `mediawiki/semantic-media-wiki` | `SemanticMediaWiki` |

When a package installs somewhere else, set `MW_COMPOSER_<PACKAGE>_FOLDER`. `<PACKAGE>` is the package name uppercased with `/`, `-` and `.` turned into `_`. This also lets a package from a vendor other than `mediawiki/` be loaded as an extension:

```yaml
MW_COMPOSER_PACKAGES: |
  acme/wiki-widgets
MW_COMPOSER_ACME_WIKI_WIDGETS_FOLDER: Widgets
```

If the folder has no readable `extension.json`, the extension is skipped and the log says so, rather than failing the whole wiki.

#### Complete Composer + Extensions Example

```yaml
environment:
  # Install via Composer
  MW_COMPOSER_PACKAGES: |
    mediawiki/semantic-media-wiki:~4.0
    mediawiki/page-forms:^5.3
  
  # Git-managed or bundled extensions. Composer ones load automatically.
  MW_EXTENSIONS: |
    Cite
    ParserFunctions
```

### Custom Configuration

#### MW_CONFIG_FILE (Recommended)

**Format**: Path to a PHP file mounted into the container

The recommended way to add custom PHP configuration. Mount a PHP file into the container and set `MW_CONFIG_FILE` to its path. The file contents are appended to `LocalSettings.php` — do not include a `<?php` opening tag.

**Example**:

Create `custom-settings.php`:
```php
# Advanced upload settings
$wgEnableUploads = true;
$wgUseImageMagick = true;
$wgImageMagickConvertCommand = '/usr/bin/convert';
$wgFileExtensions = array_merge($wgFileExtensions, ['pdf', 'doc', 'docx', 'xls', 'xlsx']);
$wgMaxUploadSize = 104857600; // 100MB

# Restrict editing to logged-in users
$wgGroupPermissions['*']['edit'] = false;
$wgGroupPermissions['user']['edit'] = true;
```

Mount it in `docker-compose.yml`:
```yaml
services:
  mediawiki:
    volumes:
      - ./custom-settings.php:/custom-config/custom.php:ro
    environment:
      MW_CONFIG_FILE: /custom-config/custom.php
```

#### MW_CONFIG_APPEND

**Format**: Multi-line string with raw PHP code

Append custom PHP configuration inline via environment variable. This is inserted at the end of the generated `LocalSettings.php`.

> **⚠️ Docker Compose `$` escaping**: Docker Compose interprets `$` as a variable reference. When using `MW_CONFIG_APPEND` in `docker-compose.yml`, you must escape every literal `$` as `$$` (e.g., `$$wgGroupPermissions`). For complex PHP config, use `MW_CONFIG_FILE` instead to avoid this issue.

**Example**:
```yaml
MW_CONFIG_APPEND: |
  # In docker-compose.yml, use $$ for literal $ signs
  $$wgEnableUploads = true;
  $$wgUseImageMagick = true;
  $$wgImageMagickConvertCommand = '/usr/bin/convert';
  $$wgFileExtensions = array_merge($$wgFileExtensions, ['pdf', 'doc', 'docx', 'xls', 'xlsx']);
  $$wgMaxUploadSize = 104857600; // 100MB
  
  # Restrict editing to logged-in users
  $$wgGroupPermissions['*']['edit'] = false;
  $$wgGroupPermissions['user']['edit'] = true;
  
  # Custom namespace
  define("NS_DOCUMENTATION", 3000);
  define("NS_DOCUMENTATION_TALK", 3001);
  $$wgExtraNamespaces[NS_DOCUMENTATION] = "Documentation";
  $$wgExtraNamespaces[NS_DOCUMENTATION_TALK] = "Documentation_talk";
  
  # Semantic MediaWiki settings
  enableSemantics('example.com');
  $$smwgDefaultStore = 'SMWSQLStore3';
```

### Runtime Package Installation

The image ships with a curated set of PHP extensions commonly needed by popular MediaWiki extensions:

| Extension | Use Case |
|-----------|----------|
| `ldap` | LDAPProvider, LDAPAuthentication2, PluggableAuth |
| `apcu` | Recommended object cache for MediaWiki (included in base image) |

For anything beyond the curated set, three environment variables let you install additional packages at container startup without building a custom image:

| Variable | Default | Description |
|----------|---------|-------------|
| `MW_APT_PACKAGES` | `""` | Space-separated list of APT packages to install at startup |
| `MW_PHP_EXTENSIONS` | `""` | Space-separated list of PHP extensions to install via `docker-php-ext-install` |
| `MW_PECL_EXTENSIONS` | `""` | Space-separated list of PECL extensions to install at startup |

**Important notes:**
- PHP extensions often require system dev libraries. Install those via `MW_APT_PACKAGES` alongside `MW_PHP_EXTENSIONS`.
- Packages are only installed when missing — container restarts within the same container are fast. Container recreation (e.g., `docker-compose up --force-recreate`) will reinstall.
- This adds to first-boot time. For production deployments with many runtime packages, consider building a custom image instead.

#### Example: Adding Redis for Object Caching

```yaml
environment:
  MW_APT_PACKAGES: "libzstd-dev"
  MW_PECL_EXTENSIONS: "redis"
  MW_CONFIG_APPEND: |
    $$wgObjectCaches['redis'] = [
        'class' => 'RedisBagOStuff',
        'servers' => ['redis:6379'],
    ];
    $$wgMainCacheType = 'redis';
```

#### Example: Adding PostgreSQL Support

```yaml
environment:
  MW_APT_PACKAGES: "libpq-dev"
  MW_PHP_EXTENSIONS: "pgsql pdo_pgsql"
  MW_DB_TYPE: "postgres"
```

### Automation Flags

| Variable | Default | Description |
|----------|---------|-------------|
| `MW_AUTO_UPDATE` | `false` | Automatically run `update.php` on startup |
| `MW_AUTO_INSTALL_EXTENSIONS` | `true` | Process extensions from environment (internal flag) |

## State Management

The system tracks installed extensions and skins to detect changes:

### On Each Container Start:

1. **Compare** current environment to previous state
2. **Remove** extensions/skins no longer in environment
3. **Update** existing extensions/skins (via `git pull`)
4. **Install** newly added extensions/skins
5. **Update** Composer packages

### Manifest Files

State is tracked in volume-mounted directories:

- `/extensions/.managed-manifest` - Tracks installed extensions
- `/skins/.managed-manifest` - Tracks installed skins
- `/extensions/.composer-manifest` - Tracks Composer packages

These files are automatically maintained; you don't need to interact with them.

## Volume Management

### Required Volumes

```yaml
volumes:
  - config:/config            # Generated config and secrets
  - extensions:/extensions     # Extension storage
  - skins:/skins              # Skin storage
  - uploads:/var/www/html/images  # User uploads
  # Recommended with Composer packages, see "Persisting vendor/"
  # - vendor:/var/www/html/vendor
  # Optional: Composer download cache, see "Composer download cache"
  # - composer-cache:/composer-cache
```

**Note**: The `config` volume stores generated `LocalSettings.php`, persisted secret keys in `/config/.secrets`.

### SELinux hosts require `:z`

On hosts with SELinux enforcing (Fedora, RHEL, Fedora CoreOS), mount the volumes with `:z`:

```yaml
volumes:
  - config:/config:z
  - extensions:/extensions:z
  - skins:/skins:z
  - uploads:/var/www/html/images:z
```

Composer writes extension directories into the `extensions` volume at runtime, and those directories inherit the MCS category of the container that created them:

```
/extensions           container_file_t:s0
/extensions/Maps      container_file_t:s0:c137,c549
```

Every recreated container gets a different category, so on the *next* deployment the extension becomes unreadable — even to root — and MediaWiki aborts with `Error Loading extension. Unable to open file .../extension.json`. The first deployment succeeds, which makes this easy to miss until a redeploy. `:z` relabels the content as shared and avoids it.

## Common Use Cases

### Basic Wiki with Essential Extensions

```yaml
environment:
  MW_DB_SERVER: database
  MW_DB_NAME: wiki
  MW_DB_USER: wikiuser
  MW_DB_PASSWORD: password123
  
  MW_SITE_NAME: "My Wiki"
  MW_SITE_SERVER: "http://localhost:8080"
  
  MW_EXTENSIONS: |
    Cite
    ParserFunctions
    InputBox
  
  MW_SKINS: |
    Vector
  
  MW_ENABLE_UPLOADS: "true"
  MW_AUTO_UPDATE: "true"
```

### Semantic Wiki

```yaml
environment:
  MW_COMPOSER_PACKAGES: |
    mediawiki/semantic-media-wiki:~4.0
    mediawiki/page-forms:^5.3
  
  MW_EXTENSIONS: |
    SemanticMediaWiki
    PageForms
    Cite
    ParserFunctions
  
  MW_CONFIG_APPEND: |
    enableSemantics('example.com');
    $smwgDefaultStore = 'SMWSQLStore3';
    $smwgQMaxSize = 5000;
```

### Visual Editor Setup

```yaml
environment:
  MW_EXTENSIONS: |
    VisualEditor
    Parsoid
  
  MW_EXT_VISUALEDITOR_POST_INSTALL: "git submodule update --init"
  
  MW_CONFIG_APPEND: |
    $wgDefaultUserOptions['visualeditor-enable'] = 1;
    $wgVisualEditorAvailableNamespaces = [
      NS_MAIN => true,
      NS_USER => true,
      NS_PROJECT => true
    ];
```

### Private Wiki (Login Required)

```yaml
environment:
  MW_ALLOW_ANONYMOUS_EDIT: "false"
  
  MW_CONFIG_APPEND: |
    # Prevent anonymous viewing
    $wgGroupPermissions['*']['read'] = false;
    $wgGroupPermissions['*']['edit'] = false;
    $wgGroupPermissions['*']['createaccount'] = false;
    
    # Allow logged-in users
    $wgGroupPermissions['user']['read'] = true;
    $wgGroupPermissions['user']['edit'] = true;
```

### Custom Extension from GitHub

```yaml
environment:
  MW_EXTENSIONS: |
    Cite
    MyCustomWidget
  
  MW_EXT_MYCUSTOMWIDGET_REPO: "https://github.com/me/MyCustomWidget"
  MW_EXT_MYCUSTOMWIDGET_BRANCH: "main"
  MW_EXT_MYCUSTOMWIDGET_POST_INSTALL: "composer install --no-dev && npm run build"
```

## Updating Extensions

Extensions and skins update automatically on container restart:

```bash
# Restart container to update all extensions/skins
docker-compose restart mediawiki

# Or with Watchtower running, just wait for the schedule
```

To force a re-clone of an extension, delete it from the volume:

```bash
docker-compose exec mediawiki rm -rf /extensions/ExtensionName
docker-compose restart mediawiki
```

## Removing Extensions

Simply remove them from your environment variables:

**Before**:
```yaml
MW_EXTENSIONS: |
  Cite
  ParserFunctions
  VisualEditor
```

**After**:
```yaml
MW_EXTENSIONS: |
  Cite
  ParserFunctions
```

On next container start, `VisualEditor` will be automatically removed.

## Troubleshooting

### Check Logs

```bash
docker-compose logs -f mediawiki
```

Look for `[MediaWiki Init]` prefixed messages showing extension installation/updates.

### Verify Extension Installation

```bash
# List installed extensions
docker-compose exec mediawiki ls -la /extensions

# Check if extension was cloned
docker-compose exec mediawiki ls -la /extensions/ExtensionName
```

### Manually Run Database Update

```bash
docker-compose exec mediawiki php maintenance/run.php update.php
```

### View Generated LocalSettings.php

```bash
docker-compose exec mediawiki cat /config/LocalSettings.php
```

### Reset Everything

To start fresh:

```bash
# Stop containers
docker-compose down

# Remove volumes
docker volume rm projectname_extensions
docker volume rm projectname_skins
docker volume rm projectname_db

# Start fresh
docker-compose up -d
```

## Building Your Own Image

### Directory Structure

```
mediawiki-managed/
├── Dockerfile
├── scripts/
│   └── custom-entrypoint.sh
└── .github/
    └── workflows/
        └── build-image.yml
```

### Build Command

```bash
docker build -t nkcx/mediawiki-docker:1.43 .
```

### GitHub Actions Auto-Build

The image can be configured to auto-rebuild when the upstream MediaWiki image updates. See `.github/workflows/build-image.yml` for an example workflow.

## Best Practices

1. **Use Named Volumes**: Persist extensions, skins, and uploads
2. **Set `MW_AUTO_UPDATE: "true"`**: Keep database schema current
3. **Version Your Image**: Pin to specific MediaWiki versions (e.g., `1.43`)
4. **Use Environment Variables**: Keep configuration in docker-compose
5. **Backup Volumes**: Regular backups of database and upload volumes
6. **Test Extension Updates**: Review extension changes before deploying
7. **Use Secrets**: Store passwords in `.env` files or Docker secrets

## Limitations

- **No ARM Support**: Currently only builds for x86_64
- **Single Container**: Not designed for multi-server deployments
- **Sequential Updates**: Extensions update one at a time on startup
- **Runtime Packages**: `MW_PHP_EXTENSIONS` / `MW_PECL_EXTENSIONS` are compiled at startup, adding boot time. For many runtime extensions, a custom image is faster.

## Contributing

Issues and pull requests welcome at: https://github.com/nkcx/mediawiki-docker

## Acknowledgements
Most of the code in this repository was written through Claude Code.

The work on this docker container is inspired by and draws on the work from these amazing projects:

* Official Mediawiki Docker Container - https://github.com/wikimedia/mediawiki-docker
* University of British Columbia Mediawiki Docker Container - https://github.com/ubc/mediawiki-docker
* Libre Space Mediawiki Container - https://gitlab.com/librespacefoundation/ops/docker-mediawiki
