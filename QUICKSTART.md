# Quick Start Guide

Get MediaWiki running in 5 minutes with declarative configuration.

## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2+

## Step 1: Create Project Directory

```bash
mkdir my-wiki
cd my-wiki
```

## Step 2: Create docker-compose.yml

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
      MW_DB_SERVER: database
      MW_DB_NAME: mediawiki
      MW_DB_USER: wikiuser
      MW_DB_PASSWORD: changeme123
      
      MW_SITE_NAME: "My Wiki"
      MW_SITE_LANG: en
      MW_SITE_SERVER: "http://localhost:8080"
      
      MW_EXTENSIONS: |
        Cite
        ParserFunctions
      
      MW_SKINS: |
        Vector
      
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
      MYSQL_PASSWORD: changeme123
      MYSQL_ROOT_PASSWORD: rootpass123

volumes:
  config:
  extensions:
  skins:
  uploads:
  db:
```

## Step 3: Start Services

```bash
docker-compose up -d
```

## Step 4: Access Wiki

Open your browser to: http://localhost:8080

## Adding More Extensions

Edit `docker-compose.yml` and add to `MW_EXTENSIONS`:

```yaml
MW_EXTENSIONS: |
  Cite
  ParserFunctions
  VisualEditor
  SyntaxHighlight_GeSHi
```

Then restart:

```bash
docker-compose restart mediawiki
```

## Customizing Configuration

Add custom PHP to `MW_CONFIG_APPEND`:

```yaml
MW_CONFIG_APPEND: |
  $wgEnableUploads = true;
  $wgFileExtensions = array_merge($wgFileExtensions, ['pdf', 'docx']);
  $wgGroupPermissions['*']['edit'] = false;
```

## Common Commands

```bash
# View logs
docker-compose logs -f mediawiki

# Restart services
docker-compose restart

# Stop services
docker-compose down

# Update images (with Watchtower or manually)
docker-compose pull
docker-compose up -d

# Run maintenance scripts
docker-compose exec mediawiki php maintenance/run.php update.php
```

## Next Steps

- Read the full [README.md](README.md) for all configuration options
- Review [docker-compose.example.yml](docker-compose.example.yml) for advanced examples
- Set up automatic updates with Watchtower
- Configure backups for volumes

## Troubleshooting

**Extensions not loading?**
- Check logs: `docker-compose logs mediawiki`
- Verify extensions installed: `docker-compose exec mediawiki ls /extensions`

**Database connection errors?**
- Ensure database service is healthy: `docker-compose ps`
- Check credentials match between services

**Need help?**
- Check the full [README.md](README.md)
- Review Docker logs
- Visit the GitHub issues page
