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
| `MW_EMERGENCY_CONTACT` | No | `""` | Email for emergency contact |
| `MW_PASSWORD_SENDER` | No | `""` | Email address for password resets |

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
- Branch: Matches MediaWiki version (e.g., `REL1_39`)
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
- If no version specified, defaults to `*` (latest compatible)
- Extensions installed via Composer should also be listed in `MW_EXTENSIONS` for loading
- Composer packages are updated (not just installed) on each container start

#### Complete Composer + Extensions Example

```yaml
environment:
  # Install via Composer
  MW_COMPOSER_PACKAGES: |
    mediawiki/semantic-media-wiki:~4.0
    mediawiki/page-forms:^5.3
  
  # Load extensions (some from Composer, some from git)
  MW_EXTENSIONS: |
    SemanticMediaWiki
    PageForms
    Cite
    ParserFunctions
```

### Custom Configuration

#### MW_CONFIG_APPEND

**Format**: Multi-line string with raw PHP code

Append custom PHP configuration to `LocalSettings.php`. This is inserted at the end of the generated configuration.

**Example**:
```yaml
MW_CONFIG_APPEND: |
  # Advanced upload settings
  $wgEnableUploads = true;
  $wgUseImageMagick = true;
  $wgImageMagickConvertCommand = '/usr/bin/convert';
  $wgFileExtensions = array_merge($wgFileExtensions, ['pdf', 'doc', 'docx', 'xls', 'xlsx']);
  $wgMaxUploadSize = 104857600; // 100MB
  
  # Restrict editing to logged-in users
  $wgGroupPermissions['*']['edit'] = false;
  $wgGroupPermissions['user']['edit'] = true;
  
  # Custom namespace
  define("NS_DOCUMENTATION", 3000);
  define("NS_DOCUMENTATION_TALK", 3001);
  $wgExtraNamespaces[NS_DOCUMENTATION] = "Documentation";
  $wgExtraNamespaces[NS_DOCUMENTATION_TALK] = "Documentation_talk";
  
  # Semantic MediaWiki settings
  enableSemantics('example.com');
  $smwgDefaultStore = 'SMWSQLStore3';
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
```

**Note**: The `config` volume stores generated `LocalSettings.php` and persisted secret keys in `/config/.secrets`.

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
- **Git and Composer Extensions Only**: Extensions must be available via git or Composer
- **Single Container**: Not designed for multi-server deployments
- **Sequential Updates**: Extensions update one at a time on startup

## Contributing

Issues and pull requests welcome at: https://github.com/nkcx/mediawiki-docker

## Acknowledgements
The work on this docker container is inspired by and draws on the work from these amazing projects:

* Official Mediawiki Docker Container - https://github.com/wikimedia/mediawiki-docker
* University of British Columbia Mediawiki Docker Container - https://github.com/ubc/mediawiki-docker
* Libre Space Mediawiki Container - https://gitlab.com/librespacefoundation/ops/docker-mediawiki
