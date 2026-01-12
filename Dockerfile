# syntax=docker/dockerfile:1

ARG BASE_IMAGE=registry1.dso.mil/ironbank/redhat/ubi/ubi9:9.7-arm64
FROM ${BASE_IMAGE}

ARG APP_UID=1001
ARG APP_GID=1001

ENV TR_WEBROOT=/var/www/testrail \
    TR_PORT=8080 \
    TR_APP_USER=testrail \
    TR_APP_UID=${APP_UID} \
    TR_APP_GID=${APP_GID} \
    TR_CHROME_PATH=/usr/bin/chrome-headless-shell-linux64/chrome-headless-shell

# -----------------------------------------------------------------------------
# Enable PHP 8.1 (TestRail requirement)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y update; \
    dnf -y module reset php; \
    dnf -y module enable php:8.1; \
    dnf -y install \
      httpd \
      php php-cli php-fpm \
      php-mysqlnd php-gd php-mbstring php-xml php-zip php-json php-ldap php-opcache \
      unzip tar gzip \
      ca-certificates \
      shadow-utils findutils which; \
    dnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

# -----------------------------------------------------------------------------
# Create non-root application user (container still runs as root)
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd -g "${APP_GID}" "${TR_APP_USER}" 2>/dev/null || true; \
    useradd  -r -u "${APP_UID}" -g "${APP_GID}" -M -s /sbin/nologin "${TR_APP_USER}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Install TestRail from build context (NO internet)
# -----------------------------------------------------------------------------
COPY testrail-9.8.1.1506-ion81.zip /tmp/testrail.zip

RUN set -eux; \
    mkdir -p /var/www; \
    unzip -q /tmp/testrail.zip -d /var/www; \
    rm -f /tmp/testrail.zip; \
    if [ ! -d /var/www/testrail ] && ls -d /var/www/testrail-* >/dev/null 2>&1; then \
      mv /var/www/testrail-* /var/www/testrail; \
    fi; \
    test -d /var/www/testrail

# -----------------------------------------------------------------------------
# Install ionCube (MANDATORY) from build context
# -----------------------------------------------------------------------------
COPY ioncube_loaders_lin_aarch64.tar.gz /tmp/ioncube.tar.gz

RUN set -eux; \
    mkdir -p /opt/ioncube; \
    tar -xzf /tmp/ioncube.tar.gz -C /opt/ioncube; \
    rm -f /tmp/ioncube.tar.gz; \
    PHPV="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"; \
    LOADER="/opt/ioncube/ioncube/ioncube_loader_lin_${PHPV}.so"; \
    test -f "${LOADER}"; \
    echo "zend_extension=${LOADER}" > /etc/php.d/00-ioncube.ini

# -----------------------------------------------------------------------------
# Chrome Headless Shell (offline, amd64) + runtime deps
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y update; \
    dnf -y install \
      unzip \
      # Runtime deps for chrome-headless-shell on UBI 9
      alsa-lib \
      atk \
      at-spi2-atk \
      cairo \
      cups-libs \
      dbus-libs \
      expat \
      fontconfig \
      freetype \
      glib2 \
      gtk3 \
      libX11 \
      libXcomposite \
      libXdamage \
      libXrandr \
      libXfixes \
      libXext \
      libXcursor \
      libXi \
      libXrender \
      libXtst \
      libxcb \
      libxkbcommon \
      mesa-libgbm \
      nss \
      nspr \
      pango \
      dejavu-sans-fonts \
      dejavu-serif-fonts \
      xorg-x11-fonts-Type1; \
    dnf clean all; \
    rm -rf /var/cache/dnf

# Bring the zip from build context (NO internet)
COPY chrome-headless-shell-linux64.zip /tmp/chrome-headless-shell-linux64.zip

RUN set -eux; \
    mkdir -p /usr/bin; \
    unzip -q /tmp/chrome-headless-shell-linux64.zip -d /tmp; \
    rm -f /tmp/chrome-headless-shell-linux64.zip; \
    test -x /tmp/chrome-headless-shell-linux64/chrome-headless-shell; \
    mv /tmp/chrome-headless-shell-linux64 /usr/bin/; \
    ln -sf "${TR_CHROME_PATH}" /usr/local/bin/chrome-headless-shell


# -----------------------------------------------------------------------------
# Apache + PHP-FPM configuration
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/httpd/conf.d/welcome.conf || true; \
    echo "Listen ${TR_PORT}" > /etc/httpd/conf.d/00-listen.conf; \
    echo "ServerName localhost" > /etc/httpd/conf.d/00-servername.conf; \
    { \
      echo 'ServerTokens Prod'; \
      echo 'ServerSignature Off'; \
      echo 'TraceEnable Off'; \
    } > /etc/httpd/conf.d/00-hardening.conf


COPY apache_testrail.conf /etc/httpd/conf.d/000-default.conf

# PHP-FPM must NOT run as root
RUN set -eux; \
    sed -i "s/^user = .*/user = ${TR_APP_USER}/" /etc/php-fpm.d/www.conf; \
    sed -i "s/^group = .*/group = ${TR_APP_USER}/" /etc/php-fpm.d/www.conf; \
    sed -i "s|^listen = .*|listen = /run/php-fpm/www.sock|" /etc/php-fpm.d/www.conf; \
    sed -i "s/^;listen.owner = .*/listen.owner = ${TR_APP_USER}/" /etc/php-fpm.d/www.conf; \
    sed -i "s/^;listen.group = .*/listen.group = ${TR_APP_USER}/" /etc/php-fpm.d/www.conf; \
    sed -i "s/^;listen.mode = .*/listen.mode = 0660/" /etc/php-fpm.d/www.conf

RUN set -eux; \
  cat > /etc/httpd/conf.d/zz-php-fpm.conf <<'EOF'
DirectoryIndex index.php index.html
<FilesMatch \.php$>
  SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
</FilesMatch>
EOF

COPY php.ini /etc/php.ini

# -----------------------------------------------------------------------------
# Runtime directories
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /run/php-fpm /run/httpd /tmp; \
    chmod 1777 /tmp; \
    chown -R "${APP_UID}:${APP_GID}" /run/php-fpm

# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------
COPY custom-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE ${TR_PORT}

USER 0
ENTRYPOINT ["/entrypoint.sh"]
