#!/bin/bash
#
# Z-Push: The Microsoft Exchange protocol server
# ----------------------------------------------
#
# Mostly for use on iOS which doesn't support IMAP IDLE.
#
# Although Ubuntu ships Z-Push (as d-push) it has a dependency on Apache
# so we won't install it that way.
#
# Thanks to http://frontender.ch/publikationen/push-mail-server-using-nginx-and-z-push.html.

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars

# Prereqs.

# The PHP imap extension is a hard runtime requirement of z-push's IMAP
# backend. It was a regular apt package for PHP <= 8.3; PHP 8.4 moved the
# extension to PECL and Debian 13 does not ship php8.4-imap. Prefer the apt
# package when present, otherwise build it from PECL against the bookworm
# libc-client shared library (uw-imap was removed from trixie).
echo "Installing Z-Push (Exchange/ActiveSync server)..."
apt_install \
	php"${PHP_VER}"-soap libawl-php php"$PHP_VER"-xml php"${PHP_VER}"-intl

ensure_php_imap() {
	# Already loaded?
	if php"$PHP_VER" -m 2>/dev/null | grep -qx imap; then
		return 0
	fi

	if apt-cache show "php${PHP_VER}-imap" >/dev/null 2>&1; then
		apt_install "php${PHP_VER}-imap"
		phpenmod -v "$PHP_VER" imap
		return 0
	fi

	echo "php${PHP_VER}-imap is not in the archive; building from PECL..."
	apt_install php"$PHP_VER"-dev php-pear build-essential pkg-config \
		libssl-dev libkrb5-dev sgml-base

	# libc-client / mlock were dropped from Debian 13 with uw-imap. Pull the
	# last bookworm amd64 builds (8:2007f~dfsg-7+b2), pinned by SHA-1.
	local tmp
	tmp=$(mktemp -d)
	wget_verify \
		http://deb.debian.org/debian/pool/main/u/uw-imap/mlock_2007f~dfsg-7+b2_amd64.deb \
		00c0097879f115fa56d3b77a7a2b84b6f2f0f0db \
		"$tmp/mlock.deb"
	wget_verify \
		http://deb.debian.org/debian/pool/main/u/uw-imap/libc-client2007e_2007f~dfsg-7+b2_amd64.deb \
		8b02e92f19678a3e6bd2835c509ef74d9bc2d797 \
		"$tmp/libc-client.deb"
	wget_verify \
		http://deb.debian.org/debian/pool/main/u/uw-imap/libc-client2007e-dev_2007f~dfsg-7+b2_amd64.deb \
		a7a8bdec35e7b5dbd48dfe4e1f329264f70ed57a \
		"$tmp/libc-client-dev.deb"
	hide_output dpkg -i "$tmp/mlock.deb" "$tmp/libc-client.deb" "$tmp/libc-client-dev.deb"
	rm -rf "$tmp"
	ldconfig

	# Non-interactive pecl install of the PHP 8.4 imap extension.
	printf '\n' | hide_output pecl install -f imap
	echo "extension=imap.so" > /etc/php/"$PHP_VER"/mods-available/imap.ini
	phpenmod -v "$PHP_VER" imap

	if ! php"$PHP_VER" -m 2>/dev/null | grep -qx imap; then
		echo "FAILED: could not enable the PHP imap extension required by Z-Push."
		exit 1
	fi
}

ensure_php_imap

# Copy Z-Push into place.
VERSION=2.7.7
TARGETHASH=b8ba5fdf5594a642c98f92c30683d19b5c6aae77
needs_update=0 #NODOC
if [ ! -f /usr/local/lib/z-push/version ]; then
	needs_update=1 #NODOC
elif [[ $VERSION != $(cat /usr/local/lib/z-push/version) ]]; then
	# checks if the version
	needs_update=1 #NODOC
fi
if [ $needs_update == 1 ]; then
	# Download
	wget_verify "https://github.com/Z-Hub/Z-Push/archive/refs/tags/$VERSION.zip" $TARGETHASH /tmp/z-push.zip

	# Extract into place.
	rm -rf /usr/local/lib/z-push /tmp/z-push
	unzip -q /tmp/z-push.zip -d /tmp/z-push
	mv /tmp/z-push/*/src /usr/local/lib/z-push
	rm -rf /tmp/z-push.zip /tmp/z-push

	# Create admin and top scripts with PHP_VER  
	rm -f /usr/sbin/z-push-{admin,top}
    echo '#!/bin/bash' > /usr/sbin/z-push-admin
    echo php"$PHP_VER" /usr/local/lib/z-push/z-push-admin.php '"$@"' >> /usr/sbin/z-push-admin
    chmod 755 /usr/sbin/z-push-admin
    echo '#!/bin/bash' > /usr/sbin/z-push-top
    echo php"$PHP_VER" /usr/local/lib/z-push/z-push-top.php '"$@"' >> /usr/sbin/z-push-top
    chmod 755 /usr/sbin/z-push-top
	
	echo $VERSION > /usr/local/lib/z-push/version
fi

# Configure default config.
sed -i "s^define('TIMEZONE', .*^define('TIMEZONE', '$(cat /etc/timezone)');^" /usr/local/lib/z-push/config.php
sed -i "s/define('BACKEND_PROVIDER', .*/define('BACKEND_PROVIDER', 'BackendCombined');/" /usr/local/lib/z-push/config.php
sed -i "s/define('USE_FULLEMAIL_FOR_LOGIN', .*/define('USE_FULLEMAIL_FOR_LOGIN', true);/" /usr/local/lib/z-push/config.php
sed -i "s/define('LOGLEVEL', .*/define('LOGLEVEL', LOGLEVEL_ERROR);/" /usr/local/lib/z-push/config.php

# Configure BACKEND
rm -f /usr/local/lib/z-push/backend/combined/config.php
cp conf/zpush/backend_combined.php /usr/local/lib/z-push/backend/combined/config.php

# Configure IMAP
rm -f /usr/local/lib/z-push/backend/imap/config.php
cp conf/zpush/backend_imap.php /usr/local/lib/z-push/backend/imap/config.php
sed -i "s%STORAGE_ROOT%$STORAGE_ROOT%" /usr/local/lib/z-push/backend/imap/config.php

# Configure CardDav
rm -f /usr/local/lib/z-push/backend/carddav/config.php
cp conf/zpush/backend_carddav.php /usr/local/lib/z-push/backend/carddav/config.php

# Configure CalDav
rm -f /usr/local/lib/z-push/backend/caldav/config.php
cp conf/zpush/backend_caldav.php /usr/local/lib/z-push/backend/caldav/config.php

# Configure Autodiscover
rm -f /usr/local/lib/z-push/autodiscover/config.php
cp conf/zpush/autodiscover_config.php /usr/local/lib/z-push/autodiscover/config.php
sed -i "s/PRIMARY_HOSTNAME/$PRIMARY_HOSTNAME/" /usr/local/lib/z-push/autodiscover/config.php
sed -i "s^define('TIMEZONE', .*^define('TIMEZONE', '$(cat /etc/timezone)');^" /usr/local/lib/z-push/autodiscover/config.php

# Some directories it will use.

mkdir -p /var/log/z-push
mkdir -p /var/lib/z-push
chmod 750 /var/log/z-push
chmod 750 /var/lib/z-push
chown www-data:www-data /var/log/z-push
chown www-data:www-data /var/lib/z-push

# Add log rotation

cat > /etc/logrotate.d/z-push <<EOF;
/var/log/z-push/*.log {
	weekly
	missingok
	rotate 52
	compress
	delaycompress
	notifempty
}
EOF

# Restart service.

restart_service php"$PHP_VER"-fpm

# Fix states after upgrade

if [ $needs_update == 1 ]; then
	hide_output php"$PHP_VER" /usr/local/lib/z-push/z-push-admin.php -a fixstates
fi
