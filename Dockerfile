FROM composer:2 AS composer

FROM mediawiki:1.43

COPY --from=composer /usr/bin/composer /usr/bin/composer

# Curated PHP extensions for common MediaWiki production stacks:
#   ldap      - LDAPProvider, LDAPAuthentication2, PluggableAuth
#   redis     - Object caching, sessions, job queue
#   imagick   - Preferred image backend for thumbnailing and SVG rendering
#   wikidiff2 - Fast native inline diffs (recommended by MediaWiki for production)
# (apcu and luasandbox are already included in the base mediawiki image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libldap2-dev \
    libmagickwand-dev \
    libthai-dev \
    pkg-config \
    g++ \
    git \
    && docker-php-ext-install ldap \
    && pecl install redis && docker-php-ext-enable redis \
    && pecl install imagick && docker-php-ext-enable imagick \
    && git clone --depth 1 https://gerrit.wikimedia.org/r/mediawiki/php/wikidiff2 /tmp/wikidiff2 \
    && cd /tmp/wikidiff2 && phpize && ./configure && make && make install \
    && docker-php-ext-enable wikidiff2 \
    && rm -rf /tmp/wikidiff2 \
    && apt-get purge -y --auto-remove g++ pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies for extension management and runtime package installation.
# unzip is required by Composer to extract dist packages; without it every
# download fails with "The zip extension and unzip/7z commands are both missing".
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    git \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (if needed in the future)
# RUN pip3 install --no-cache-dir pyyaml gitpython

# Record which extensions and skins ship with MediaWiki. They share the
# /extensions and /skins volumes with Composer-installed packages at runtime,
# and the entrypoint must tell them apart.
RUN find /var/www/html/extensions -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        > /usr/local/share/mediawiki-bundled-extensions \
    && find /var/www/html/skins -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        > /usr/local/share/mediawiki-bundled-skins

# Clean copy of core's vendor/. A persisted vendor volume is restored from it
# whenever the image changes, so core never runs against stale libraries.
RUN cp -a /var/www/html/vendor /usr/local/share/mediawiki-vendor

# Fingerprint of everything in the image that vendor/ depends on. A persisted
# vendor volume records it, and is restored from the image when it differs.
RUN cd /var/www/html \
    && sha256sum composer.json vendor/composer/installed.json /usr/bin/composer \
        > /usr/local/share/mediawiki-image-fingerprint

# Copy custom entrypoint script
COPY scripts/custom-entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# Set custom entrypoint
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["apache2-foreground"]
