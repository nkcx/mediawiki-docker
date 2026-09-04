# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A custom Docker image wrapping the official `mediawiki:1.43` image with a bash entrypoint (`scripts/custom-entrypoint.sh`) that turns environment variables into a fully configured MediaWiki installation—extensions, skins, composer packages, and `LocalSettings.php` are all generated at container start, with no manual PHP editing.

## Build & Lint

```bash
make build           # docker build → mediawiki-docker:1.43
make build-no-cache  # rebuild from scratch
make lint            # shellcheck scripts/*.sh (requires shellcheck)
```

There is no test suite. `make test` does a build + `docker-compose up` + a single `curl -f` health check.

## CI

GitHub Actions (`.github/workflows/build-image.yml`) builds and pushes to `ghcr.io/nkcx/mediawiki-docker:1.43` on push to `main`, manual dispatch, or a daily cron that detects upstream `mediawiki:1.43` image changes.

## Architecture

The image has exactly one moving part: **`scripts/custom-entrypoint.sh`** (~690 lines of bash). It runs before Apache and does everything in order:

1. **Version detection** — reads `MW_VERSION` from the installed MediaWiki, derives `REL1_43`-style branch name.
2. **Secret key persistence** — generates `MW_SECRET_KEY` / `MW_UPGRADE_KEY` once, stores in `/extensions/.secrets`, reuses on subsequent boots.
3. **Volume init** — copies bundled extensions/skins into `/extensions` and `/skins` volumes on first run (or version change), then symlinks those volumes back into the webroot.
4. **State diffing** — reads previous manifest files (`.managed-manifest`) and compares against current `MW_EXTENSIONS` / `MW_SKINS` / `MW_COMPOSER_PACKAGES` env vars. Removes items no longer listed, updates existing git repos, clones new ones.
5. **Composer** — generates `composer.local.json` from `MW_COMPOSER_PACKAGES` and runs `composer update`.
6. **Extension/skin loading** — writes `wfLoadExtension()` / `wfLoadSkin()` calls to temp files, or uses custom `MW_EXT_<NAME>_LOAD` overrides.
7. **LocalSettings.php generation** — builds `/config/LocalSettings.php` from env vars, appends skin/extension loads, then appends raw PHP from `MW_CONFIG_APPEND`.
8. **DB update** — runs `maintenance/run.php update.php` if `MW_AUTO_UPDATE` is true (default).
9. **Handoff** — `exec docker-php-entrypoint "$@"` starts Apache.

A stub `LocalSettings.php` in the webroot just `require`s `/config/LocalSettings.php`.

### Environment variable naming convention for overrides

Extension: `MW_EXT_<NAME>_<FEATURE>` — name is uppercased, hyphens/spaces → underscores.  
Skin: `MW_SKIN_<NAME>_<FEATURE>` — same transform.  
Features: `REPO`, `BRANCH`, `TAG`, `COMMIT`, `POST_INSTALL`, `LOAD`.

### Manifest files (state tracking)

- `/extensions/.managed-manifest` — `extension:<name>:<source>` lines
- `/skins/.managed-manifest` — `skin:<name>:<source>` lines
- `/extensions/.composer-manifest` — package names

### Key gotcha: Docker Compose `$` interpolation in MW_CONFIG_APPEND

Docker Compose interprets `$` in YAML values as variable references. PHP config like `$wgGroupPermissions` gets silently expanded to empty, producing PHP parse errors. Users must either escape as `$$wgGroupPermissions` in compose files, or use `MW_CONFIG_FILE` to mount a PHP file (which bypasses Compose interpolation entirely). The entrypoint's heredoc uses `'EOF'` (quoted) to prevent shell-level expansion of PHP variables.
