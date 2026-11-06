# Dovecot 2.4 configuration.
# Sourced from mail-dovecot.sh when the installed Dovecot is 2.4 or newer
# (Debian 13). The 2.3 settings in mail-dovecot.sh are not valid here:
# unknown settings make `doveconf` fail and the service will not start.

# Process limits, same sizing as the 2.3 setup.
tools/editconf.py /etc/dovecot/conf.d/10-master.conf \
	default_process_limit="$(($(nproc) * 250))" \
	default_vsz_limit="$(($(free -tm  | tail -1 | awk '{print $2}') / 3))M" \
	log_path=/var/log/mail.log

# Mailbox location. mail_location was split into mail_driver + mail_path.
# Debian's default is mbox with an inbox under /var/mail, which we clear.
tools/editconf.py /etc/dovecot/conf.d/10-mail.conf \
	mail_driver=maildir \
	"mail_path=$STORAGE_ROOT/mail/mailboxes/%{user|domain}/%{user|username}" \
	"mail_home=$STORAGE_ROOT/mail/mailboxes/%{user|domain}/%{user|username}" \
	mail_privileged_group=mail \
	first_valid_uid=0
tools/editconf.py /etc/dovecot/conf.d/10-mail.conf -e \
	mail_inbox_path=

cp conf/dovecot-mailboxes.conf /etc/dovecot/conf.d/15-mailboxes.conf

# TLS. ssl_cert/ssl_key became ssl_server_cert_file/ssl_server_key_file and
# no longer use a leading "<" to mean "read this file".
tools/editconf.py /etc/dovecot/conf.d/10-ssl.conf \
	ssl=required \
	"ssl_server_cert_file=$STORAGE_ROOT/ssl/ssl_certificate.pem" \
	"ssl_server_key_file=$STORAGE_ROOT/ssl/ssl_private_key.pem" \
	"ssl_min_protocol=TLSv1.2" \
	"ssl_cipher_list=ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384" \
	"ssl_server_dh_file=$STORAGE_ROOT/ssl/dh2048.pem"

# disable_plaintext_auth was replaced by auth_allow_cleartext.
tools/editconf.py /etc/dovecot/conf.d/10-auth.conf \
	auth_allow_cleartext=no \
	"auth_mechanisms=plain login"

# Disable the public cleartext listeners. The localhost IMAP listener for
# Nextcloud is added below; it replaces the port (later files win on merge).
sed -i "s/#port = 143/port = 0/" /etc/dovecot/conf.d/10-master.conf
sed -i "s/#port = 110/port = 0/" /etc/dovecot/conf.d/10-master.conf

tools/editconf.py /etc/dovecot/conf.d/20-imap.conf \
	imap_idle_notify_interval="4 mins"

# %08Xu%08Xv became the filter form below.
tools/editconf.py /etc/dovecot/conf.d/20-pop3.conf \
	"pop3_uidl_format=%{uid|hex(8)}%{uidvalidity|hex(8)}"

tools/editconf.py /etc/dovecot/conf.d/15-lda.conf \
	"postmaster_address=postmaster@$PRIMARY_HOSTNAME"

# Debian's LMTP config strips the domain from the username. Mailboxes are
# keyed by the full address, so delivery must look users up as user@domain.
# client_limit has to cover every login service or Dovecot warns at startup
# after default_process_limit is raised.
cat > /etc/dovecot/conf.d/99-mailinabox.conf << EOF;
mail_plugins {
  quota = yes
}

service auth {
  client_limit = $(($(nproc) * 250 * 6))
}
service anvil {
  client_limit = $(($(nproc) * 250 * 6))
}

protocol lmtp {
  auth_username_format = %{user}
  mail_plugins {
    sieve = yes
  }
}

protocol imap {
  mail_max_userip_connections = 40
  mail_plugins {
    imap_quota = yes
  }
}

service lmtp {
  inet_listener lmtp {
    listen = 127.0.0.1
    port = 10026
  }
}

service imap-login {
  inet_listener imap {
    listen = 127.0.0.1
    port = 143
  }
}

quota "User quota" {
  driver = count
}
quota_status_success = DUNNO
quota_status_nouser = DUNNO
quota_status_overquota = "522 5.2.2 Mailbox is full"

service quota-status {
  executable = quota-status -p postfix
  inet_listener quota {
    listen = 127.0.0.1
    port = 12340
  }
}

sieve_redirect_envelope_from = recipient
sieve_script before-spam {
  type = before
  driver = file
  path = /etc/dovecot/sieve-spam.sieve
}
sieve_script before-global {
  type = before
  driver = file
  path = $STORAGE_ROOT/mail/sieve/global_before
}
sieve_script after-global {
  type = after
  driver = file
  path = $STORAGE_ROOT/mail/sieve/global_after
}
sieve_script personal {
  type = personal
  driver = file
  path = $STORAGE_ROOT/mail/sieve/%{user|domain}/%{user|username}
  active_path = $STORAGE_ROOT/mail/sieve/%{user|domain}/%{user|username}.sieve
}
EOF

cp conf/sieve-spam.txt /etc/dovecot/sieve-spam.sieve
sievec /etc/dovecot/sieve-spam.sieve

chown -R mail:dovecot /etc/dovecot
chmod -R o-rwx /etc/dovecot

mkdir -p "$STORAGE_ROOT/mail/mailboxes"
chown -R mail:mail "$STORAGE_ROOT/mail/mailboxes"

mkdir -p "$STORAGE_ROOT/mail/sieve"
mkdir -p "$STORAGE_ROOT/mail/sieve/global_before"
mkdir -p "$STORAGE_ROOT/mail/sieve/global_after"
chown -R mail:mail "$STORAGE_ROOT/mail/sieve"

ufw_allow imaps
ufw_allow pop3s
ufw_allow sieve

restart_service dovecot
