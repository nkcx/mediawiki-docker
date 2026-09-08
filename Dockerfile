FROM mediawiki:1.43

# Curated PHP extensions for popular MediaWiki extensions:
#   ldap - LDAPProvider, LDAPAuthentication2, PluggableAuth
# (apcu is already included in the base mediawiki image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libldap2-dev \
    && docker-php-ext-install ldap \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies for extension management and runtime package installation
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (if needed in the future)
# RUN pip3 install --no-cache-dir pyyaml gitpython

# Copy custom entrypoint script
COPY scripts/custom-entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# Set custom entrypoint
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["apache2-foreground"]
