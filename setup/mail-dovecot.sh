#!/bin/bash
#
# Dovecot (IMAP/POP and LDA)
# ----------------------
#
# Dovecot is *both* the IMAP/POP server (the protocol that email applications
# use to query a mailbox) as well as the local delivery agent (LDA),
# meaning it is responsible for writing emails to mailbox storage on disk.
# You could imagine why these things would be bundled together.
#
# As part of local mail delivery, Dovecot executes actions on incoming
# mail as defined in a "sieve" script.
#
# Dovecot's LDA role comes after spam filtering. Postfix hands mail off
# to Spamassassin which in turn hands it off to Dovecot. This all happens
# using the LMTP protocol.

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars


# Install packages for dovecot. These are the core plugins shipped in Debian 13.
# Upstream also installed dovecot-lucene from its own PPA for full-text search.
# Debian 13 has no dovecot-lucene package, so this port does not enable FTS.

echo "Installing Dovecot (IMAP server)..."
apt_install \
	dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sqlite sqlite3 \
	dovecot-sieve dovecot-managesieved

# The `dovecot-imapd`, `dovecot-pop3d`, and `dovecot-lmtpd` packages automatically
# enable IMAP, POP and LMTP protocols.

# Set basic daemon options.

# The `default_process_limit` is 100, which constrains the total number
# of active IMAP connections (at, say, 5 open connections per user that
# would be 20 users). Set it to 250 times the number of cores this
# machine has, so on a two-core machine that's 500 processes/100 users).
# The `default_vsz_limit` is the maximum amount of virtual memory that
# can be allocated. It should be set *reasonably high* to avoid allocation
# issues with larger mailboxes. We're setting it to 1/3 of the total
# available memory (physical mem + swap) to be sure.
# See here for discussion:
# - https://www.dovecot.org/list/dovecot/2012-August/137569.html
# - https://www.dovecot.org/list/dovecot/2011-December/132455.html
tools/editconf.py /etc/dovecot/conf.d/10-master.conf \
	default_process_limit="$(($(nproc) * 250))" \
	default_vsz_limit="$(($(free -tm  | tail -1 | awk '{print $2}') / 3))M" \
	log_path=/var/log/mail.log

# The inotify `max_user_instances` default is 128, which constrains
# the total number of watched (IMAP IDLE push) folders by open connections.
# See http://www.dovecot.org/pipermail/dovecot/2013-March/088834.html.
#
# Use a /etc/sysctl.d/ drop-in rather than /etc/sysctl.conf: Debian 13
# (trixie) no longer ships or honors /etc/sysctl.conf. Drop-ins work on
# Ubuntu as well. editconf.py requires the target file to exist.
# A reboot is required for this to take effect (which we don't do as
# as a part of setup). Test with `cat /proc/sys/fs/inotify/max_user_instances`.
mkdir -p /etc/sysctl.d
touch /etc/sysctl.d/99-mailinabox.conf
tools/editconf.py /etc/sysctl.d/99-mailinabox.conf \
	fs.inotify.max_user_instances=1024

# Set the location where we'll store user mailboxes. '%{user|domain}' is the domain name and
# '%{user|username}' is the username part of the user's email address (Dovecot 2.4 variable
# syntax; these replace the Dovecot 2.3 '%d'/'%n'). We'll ensure that no bad domains or email
# addresses are created within the management daemon.
#
# Dovecot 2.4 replaced the single `mail_location` setting with separate
# `mail_driver`/`mail_path`/`mail_inbox_path` settings. With the maildir driver the
# INBOX is the maildir root itself, so `mail_inbox_path` points there too (the Debian
# package default of /var/mail/%{user} is for mbox layouts and must be overridden).
tools/editconf.py /etc/dovecot/conf.d/10-mail.conf \
	mail_driver=maildir \
	mail_path="$STORAGE_ROOT/mail/mailboxes/%{user|domain}/%{user|username}" \
	mail_inbox_path="$STORAGE_ROOT/mail/mailboxes/%{user|domain}/%{user|username}" \
	mail_privileged_group=mail \
	mail_uid=mail \
	mail_gid=mail \
	first_valid_uid=0

# Create, subscribe, and mark as special folders: INBOX, Drafts, Sent, Trash, Spam and Archive.
cp conf/dovecot-mailboxes.conf /etc/dovecot/conf.d/15-mailboxes.conf

# configure stuff for quota support
#
# Dovecot 2.4 configures quota roots as named `quota ... { }` sections with a
# `quota_driver` (the old `quota = maildir` plugin setting is gone), and quota
# limits can be overridden per-user from userdb. The quota-status policy service
# still speaks the Postfix policy protocol; its `quota_status_*` settings are now
# top-level settings. See https://doc.dovecot.org/2.4.1/core/plugins/quota.html
if ! grep -q "quota_status_success = DUNNO" /etc/dovecot/conf.d/90-quota.conf; then
    cat > /etc/dovecot/conf.d/90-quota.conf << EOF;
quota "User quota" {
  driver = count
}

quota_status_success = DUNNO
quota_status_nouser = DUNNO
quota_status_overquota = "522 5.2.2 Mailbox is full"

service quota-status {
    executable = quota-status -p postfix
    inet_listener quota-status {
        port = 12340
    }
}
EOF
fi

# ### IMAP/POP

# Require that passwords are sent over SSL only, and allow the usual IMAP authentication mechanisms.
# The LOGIN mechanism is supposedly for Microsoft products like Outlook to do SMTP login (I guess
# since we're using Dovecot to handle SMTP authentication?).
#
# Dovecot 2.4 renamed `disable_plaintext_auth` to the inverted `auth_allow_cleartext`
# (and made `no` its default): plaintext authentication is only allowed over TLS.
tools/editconf.py /etc/dovecot/conf.d/10-auth.conf \
	auth_allow_cleartext=no \
	"auth_mechanisms=plain login"

# Enable SSL, specify the location of the SSL certificate and private key files.
# Use Mozilla's "Intermediate" recommendations at https://ssl-config.mozilla.org/#server=dovecot&server-version=2.2.33&config=intermediate&openssl-version=1.1.1,
# except that the current version of Dovecot does not have a TLSv1.3 setting, so we only use TLSv1.2.
#
# Dovecot 2.4 renamed the server-side certificate/key settings to
# `ssl_server_cert_file`/`ssl_server_key_file` (and they now take a path rather than
# a "<path" redirect), replaced `ssl_prefer_server_ciphers` with `ssl_server_prefer_ciphers`,
# and dropped `ssl_dh_parameters_length` (`ssl_server_dh_file` is optional now, but we
# keep ours since our cipher list includes DHE ciphers and setup/ssl.sh generates it).
tools/editconf.py /etc/dovecot/conf.d/10-ssl.conf \
	ssl=required \
	"ssl_server_cert_file=$STORAGE_ROOT/ssl/ssl_certificate.pem" \
	"ssl_server_key_file=$STORAGE_ROOT/ssl/ssl_private_key.pem" \
	"ssl_min_protocol=TLSv1.2" \
	"ssl_cipher_list=ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384" \
	"ssl_server_prefer_ciphers=client" \
	"ssl_server_dh_file=$STORAGE_ROOT/ssl/dh2048.pem"

# Disable in-the-clear IMAP/POP because there is no reason for a user to transmit
# login credentials outside of an encrypted connection. Only the over-TLS versions
# are made available (IMAPS on port 993; POP3S on port 995).
sed -i "s/#port = 143/port = 0/" /etc/dovecot/conf.d/10-master.conf
sed -i "s/#port = 110/port = 0/" /etc/dovecot/conf.d/10-master.conf

# Make IMAP IDLE slightly more efficient. By default, Dovecot says "still here"
# every two minutes. With K-9 mail, the bandwidth and battery usage due to
# this are minimal. But for good measure, let's go to 4 minutes to halve the
# bandwidth and number of times the device's networking might be woken up.
# The risk is that if the connection is silent for too long it might be reset
# by a peer. See [#129](https://github.com/mail-in-a-box/mailinabox/issues/129)
# and [How bad is IMAP IDLE](http://razor.occams.info/blog/2014/08/09/how-bad-is-imap-idle/).
tools/editconf.py /etc/dovecot/conf.d/20-imap.conf \
	imap_idle_notify_interval="4 mins"

# Set POP3 UIDL.
# UIDLs are used by POP3 clients to keep track of what messages they've downloaded.
# For new POP3 servers, the easiest way to set up UIDLs is to use IMAP's UIDVALIDITY
# and UID values, the default in Dovecot.
# (Dovecot 2.4 rewrote variable expansion: the old "%08Xu%08Xv" form became
# "%{uid | hex(8)}%{uidvalidity | hex(8)}", which yields identical UIDLs.)
tools/editconf.py /etc/dovecot/conf.d/20-pop3.conf \
	pop3_uidl_format="%{uid | hex(8)}%{uidvalidity | hex(8)}"

# ### LDA (LMTP)

# Enable Dovecot's LDA service with the LMTP protocol. It will listen
# on port 10026, and Spamassassin will be configured to pass mail there.
#
# The disabled unix socket listener is normally how Postfix and Dovecot
# would communicate (see the Postfix setup script for the corresponding
# setting also commented out).
#
# Also increase the number of allowed IMAP connections per mailbox because
# we all have so many devices lately.
cat > /etc/dovecot/conf.d/99-local.conf << EOF;
service lmtp {
  #unix_listener /var/spool/postfix/private/dovecot-lmtp {
  #  user = postfix
  #  group = postfix
  #}
  inet_listener lmtp {
    listen = 127.0.0.1
    port = 10026
  }
}

# Enable imap-login on localhost to allow the user_external plugin
# for Nextcloud to do imap authentication. (See #1577)
service imap-login {
  inet_listener imap {
    listen = 127.0.0.1
    port = 143
  }
}

# Dovecot 2.4 enables plugins with mail_plugins boolean-list blocks instead of
# space-separated lists referencing \$mail_plugins.
mail_plugins {
  quota = yes
}

protocol imap {
  mail_max_userip_connections = 40
  mail_plugins {
    imap_quota = yes
  }
}

# Mail-in-a-Box looks up users as user@domain, but Debian's stock 20-lmtp.conf
# strips the domain (auth_username_format = %{user|username}) because its default
# passwd userdb has no domains. Override it so LMTP sees the full address, and
# enable the sieve plugin for local delivery.
protocol lmtp {
  mail_plugins {
    sieve = yes
  }
  auth_username_format = %{user}
}
EOF

# Setting a `postmaster_address` is required or LMTP won't start. An alias
# will be created automatically by our management daemon.
tools/editconf.py /etc/dovecot/conf.d/15-lda.conf \
	"postmaster_address=postmaster@$PRIMARY_HOSTNAME"

# ### Sieve

# Enable the Dovecot sieve plugin which let's users run scripts that process
# mail as it comes in. (The plugin is enabled for lmtp in 99-local.conf above;
# Dovecot 2.4's stock 20-lmtp.conf no longer has a `mail_plugins` line to sed.)

# Configure sieve. We'll create a global script that moves mail marked
# as spam by Spamassassin into the user's Spam folder.
#
# Dovecot 2.4's pigeonhole replaced the `sieve`, `sieve_dir`, `sieve_before`,
# `sieve_before2` and `sieve_after` settings with named `sieve_script ... { }`
# blocks (see https://doc.dovecot.org/2.4.1/core/plugins/sieve.html):
#
# * `miab_spam`: A global before-script which handles moving spam to the Spam folder.
#
# * `global_before`: A global before-directory for sieve which can contain .sieve files
# to run globally for every user before their own sieve files run.
#
# * `global_after`: A global after-directory which can contain .sieve files
# to run globally for every user after their own sieve files run.
#
# * `personal`: The user's own scripts, plus the active-script symlink. ManageSieve
# stores the user's scripts in the path directory and manages the symlink at
# active_path. It should not be in the mailbox directory (because then it might
# appear as a folder).
#
# Multiple before-storages run in the order they are defined here.
cat > /etc/dovecot/conf.d/99-local-sieve.conf << EOF;
sieve_script miab_spam {
  type = before
  path = /etc/dovecot/sieve-spam.sieve
}
sieve_script global_before {
  type = before
  path = $STORAGE_ROOT/mail/sieve/global_before
}
sieve_script global_after {
  type = after
  path = $STORAGE_ROOT/mail/sieve/global_after
}
sieve_script personal {
  driver = file
  path = $STORAGE_ROOT/mail/sieve/%{user|domain}/%{user|username}
  active_path = $STORAGE_ROOT/mail/sieve/%{user|domain}/%{user|username}.sieve
}
sieve_redirect_envelope_from = recipient
EOF

# Copy the global sieve script into where we've told Dovecot to look for it. Then
# compile it. Global scripts must be compiled now because Dovecot won't have
# permission later.
cp conf/sieve-spam.txt /etc/dovecot/sieve-spam.sieve
sievec /etc/dovecot/sieve-spam.sieve

# PERMISSIONS

# Ensure configuration files are owned by dovecot and not world readable.
chown -R mail:dovecot /etc/dovecot
chmod -R o-rwx /etc/dovecot

# Ensure mailbox files have a directory that exists and are owned by the mail user.
mkdir -p "$STORAGE_ROOT/mail/mailboxes"
chown -R mail:mail "$STORAGE_ROOT/mail/mailboxes"

# Same for the sieve scripts.
mkdir -p "$STORAGE_ROOT/mail/sieve"
mkdir -p "$STORAGE_ROOT/mail/sieve/global_before"
mkdir -p "$STORAGE_ROOT/mail/sieve/global_after"
chown -R mail:mail "$STORAGE_ROOT/mail/sieve"

# Allow the IMAP/POP ports in the firewall.
ufw_allow imaps
ufw_allow pop3s

# Allow the Sieve port in the firewall.
ufw_allow sieve

# Restart services.
restart_service dovecot
