#!/bin/bash
# Spam filtering with spamassassin via spampd
# -------------------------------------------
#
# spampd sits between postfix and dovecot. It takes mail from postfix
# over the LMTP protocol, runs spamassassin on it, and then passes the
# message over LMTP to dovecot for local delivery.
#
# In order to move spam automatically into the Spam folder we use the dovecot sieve
# plugin. Users train the Bayes classifier by moving mail into or out of the Spam
# folder: Dovecot's imapsieve plugin (Dovecot 2.4's replacement for the removed
# dovecot-antispam package) runs sa-learn on those moves.

source /etc/mailinabox.conf # get global vars
source setup/functions.sh # load our functions

# Install packages and basic configuration
# ----------------------------------------

# Install packages.
# libmail-dkim-perl is needed to make the spamassassin DKIM module work.
# For more information see Debian Bug #689414:
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=689414
# (dovecot-antispam no longer exists in Debian 13; Bayes retraining is
# wired up with dovecot's imapsieve plugin below instead.)
echo "Installing SpamAssassin..."
apt_install spampd razor pyzor libmail-dkim-perl

# Allow spamassassin to download new rules.
tools/editconf.py /etc/default/spamassassin \
	CRON=1

# Configure pyzor, which is a client to a live database of hashes of
# spam emails. Set the pyzor configuration directory to something sane.
# The default is ~/.pyzor. We used to use that, so we'll kill that old
# directory. Then write the public pyzor server to its servers file.
# That will prevent an automatic download on first use, and also means
# we can skip 'pyzor discover', both of which are currently broken by
# something happening on Sourceforge (#496).
rm -rf ~/.pyzor
tools/editconf.py /etc/spamassassin/local.cf -s \
	pyzor_options="--homedir /etc/spamassassin/pyzor"
mkdir -p /etc/spamassassin/pyzor
echo "public.pyzor.org:24441" > /etc/spamassassin/pyzor/servers
# check with: pyzor --homedir /etc/mail/spamassassin/pyzor ping

# Configure spampd.
# Debian 13's spampd 2.62 dropped /etc/default/spampd. systemd starts
# `spampd --config /etc/spampd.cfg`, and the packaged cfg turns network tests
# off (local-only 1) and leaves maxsize at the program default of 64KB.
# * relayport 10026 is already the packaged default (Dovecot's LMTP).
# * Scan messages up to 2000KB, SpamAssassin's own default, instead of 64KB.
# * local-only 0 enables Pyzor, DKIM and DNS checks.
tools/editconf.py /etc/spampd.cfg -s \
	local-only=0 \
	maxsize=2000 \
	relayport=10026

# Spamassassin normally wraps spam as an attachment inside a fresh
# email with a report about the message. This also protects the user
# from accidentally opening a message with embedded malware.
#
# It's nice to see what rules caused the message to be marked as spam,
# but it's also annoying to get to the original message when it is an
# attachment, modern mail clients are safer now and don't load remote
# content or execute scripts, and it is probably confusing to most users.
#
# Tell Spamassassin not to modify the original message except for adding
# the X-Spam-Status & X-Spam-Score mail headers and related headers.
tools/editconf.py /etc/spamassassin/local.cf -s \
	report_safe=0 \
	"add_header all Report"=_REPORT_ \
	"add_header all Score"=_SCORE_


# Authentication-Results SPF/Dmarc checks
# ---------------------------------------
# OpenDKIM and OpenDMARC are configured to validate and add "Authentication-Results: ..."
# headers by checking the sender's SPF & DMARC policies. Instead of blocking mail that fails
# these checks, we can use these headers to evaluate the mail as spam.
#
# Our custom rules are added to their own file so that an update to the deb package config
# does not remove our changes.
#
# We need to escape period's in $PRIMARY_HOSTNAME since spamassassin config uses regex.

escapedprimaryhostname="${PRIMARY_HOSTNAME//./\\.}"

cat > /etc/spamassassin/miab_spf_dmarc.cf << EOF
# Evaluate DMARC Authentication-Results
header DMARC_PASS Authentication-Results =~ /$escapedprimaryhostname; dmarc=pass/
describe DMARC_PASS DMARC check passed
score DMARC_PASS -0.1

header DMARC_NONE Authentication-Results =~ /$escapedprimaryhostname; dmarc=none/
describe DMARC_NONE DMARC record not found
score DMARC_NONE 0.1

header DMARC_FAIL_NONE Authentication-Results =~ /$escapedprimaryhostname; dmarc=fail \(p=none/
describe DMARC_FAIL_NONE DMARC check failed (p=none)
score DMARC_FAIL_NONE 2.0

header DMARC_FAIL_QUARANTINE Authentication-Results =~ /$escapedprimaryhostname; dmarc=fail \(p=quarantine/
describe DMARC_FAIL_QUARANTINE DMARC check failed (p=quarantine)
score DMARC_FAIL_QUARANTINE 5.0

header DMARC_FAIL_REJECT Authentication-Results =~ /$escapedprimaryhostname; dmarc=fail \(p=reject/
describe DMARC_FAIL_REJECT DMARC check failed (p=reject)
score DMARC_FAIL_REJECT 10.0

# Evaluate SPF Authentication-Results
header SPF_PASS Authentication-Results =~ /$escapedprimaryhostname; spf=pass/
describe SPF_PASS SPF check passed
score SPF_PASS -0.1

header SPF_NONE Authentication-Results =~ /$escapedprimaryhostname; spf=none/
describe SPF_NONE SPF record not found
score SPF_NONE 2.0

header SPF_FAIL Authentication-Results =~ /$escapedprimaryhostname; spf=fail/
describe SPF_FAIL SPF check failed
score SPF_FAIL 5.0
EOF

# Bayesean learning
# -----------------
#
# Spamassassin can learn from mail marked as spam or ham, but it needs to be
# configured. We'll store the learning data in our storage area.
#
# These files must be:
#
# * Writable by the sa-learn wrapper scripts below, which run as the 'mail' user, for
#   retraining when mail is moved into or out of the Spam folder.
# * Readable by the spampd process ('spampd' user) during mail filtering.
# * Writable by the debian-spamd user, which runs /etc/cron.daily/spamassassin.
#
# We'll have these files owned by spampd and grant access to the other two processes.
#
# Spamassassin will change the access rights back to the defaults, so we must also configure
# the filemode in the config file.

tools/editconf.py /etc/spamassassin/local.cf -s \
	bayes_path="$STORAGE_ROOT/mail/spamassassin/bayes" \
	bayes_file_mode=0666

mkdir -p "$STORAGE_ROOT/mail/spamassassin"
chown -R spampd:spampd "$STORAGE_ROOT/mail/spamassassin"

# To mark mail as spam or ham, just drag it in or out of the Spam folder. The
# Dovecot imapsieve plugin detects the copy/move operation and runs a sieve
# script that pipes the message to sa-learn. (This replaces the dovecot-antispam
# plugin, which no longer exists in Debian 13 / Dovecot 2.4.)
#
# The `imap_sieve` IMAP plugin hooks IMAP events. In Dovecot 2.4 both
# `sieve_plugins` and `sieve_script_cause` are boolean lists (the short name
# inside a sieve_script block is `cause`). See
# https://doc.dovecot.org/2.4.1/core/plugins/imap_sieve.html
# Scripts in a `mailbox Spam { }` block run on mail copied or appended into
# the Spam folder, and scripts in an `imapsieve_from Spam { }` block run on
# mail copied out of it. The mailbox name matches conf/dovecot-mailboxes.conf
# and the global spam-delivery sieve rule, which both use "Spam".
cat > /etc/dovecot/conf.d/99-local-imapsieve.conf << EOF;
sieve_plugins {
  sieve_imapsieve = yes
  sieve_extprograms = yes
}
sieve_pipe_bin_dir = /usr/local/bin
sieve_global_extensions {
  vnd.dovecot.pipe = yes
}

# Mail copied or appended into Spam: learn as spam.
mailbox Spam {
  sieve_script learn_spam {
    type = before
    cause {
      copy = yes
      append = yes
    }
    path = /etc/dovecot/sieve/learn-spam.sieve
  }
}

# Mail copied out of Spam: relearn as ham.
imapsieve_from Spam {
  sieve_script learn_ham {
    type = before
    cause {
      copy = yes
    }
    path = /etc/dovecot/sieve/learn-ham.sieve
  }
}

protocol imap {
  mail_plugins {
    imap_sieve = yes
  }
}
EOF

# The sieve scripts pipe the message to the wrapper scripts below (resolved via
# sieve_pipe_bin_dir). The message arrives on stdin.
mkdir -p /etc/dovecot/sieve
cat > /etc/dovecot/sieve/learn-spam.sieve << EOF;
require ["vnd.dovecot.pipe", "copy", "imapsieve"];

pipe :copy "sa-learn-spam.sh";
EOF
cat > /etc/dovecot/sieve/learn-ham.sieve << EOF;
require ["vnd.dovecot.pipe", "copy", "imapsieve"];

pipe :copy "sa-learn-ham.sh";
EOF

# Precompile the sieve scripts (global scripts should be compiled ahead of time
# so Dovecot never has to write to /etc/dovecot at runtime) and make them
# readable/writable by the mail processes, like the rest of /etc/dovecot.
sievec /etc/dovecot/sieve/learn-spam.sieve
sievec /etc/dovecot/sieve/learn-ham.sieve
chown -R mail:dovecot /etc/dovecot/sieve
chmod -R o-rwx /etc/dovecot/sieve

# Here are the scripts that the sieve pipe actions execute. They spool the
# message into a temporary file and then run sa-learn on it. Dovecot runs them
# as the mail user, which has access to the Bayes files via mail_access_groups
# (set below) and the file modes configured above.
rm -f /usr/bin/sa-learn-pipe.sh /usr/local/bin/sa-learn-pipe.sh # legacy locations #NODOC
cat > /usr/local/bin/sa-learn-spam.sh << EOF;
#!/bin/bash
# Pipe a message on stdin into the SpamAssassin Bayes database as ham/spam.
# Used by Dovecot's imapsieve hooks; see /etc/dovecot/conf.d/99-local-imapsieve.conf.
temp=\$(mktemp /tmp/miab-sa-learn.XXXXXX) || exit 0
cat >\$temp
/usr/bin/sa-learn --spam \$temp > /dev/null
rm -f \$temp
exit 0
EOF
cat > /usr/local/bin/sa-learn-ham.sh << EOF;
#!/bin/bash
# Pipe a message on stdin into the SpamAssassin Bayes database as ham.
# Used by Dovecot's imapsieve hooks; see /etc/dovecot/conf.d/99-local-imapsieve.conf.
temp=\$(mktemp /tmp/miab-sa-learn.XXXXXX) || exit 0
cat >\$temp
/usr/bin/sa-learn --ham \$temp > /dev/null
rm -f \$temp
exit 0
EOF
chmod a+x /usr/local/bin/sa-learn-spam.sh /usr/local/bin/sa-learn-ham.sh

# Have Dovecot run its mail process with a supplementary group (the spampd group)
# so that it can access the learning files.
tools/editconf.py /etc/dovecot/conf.d/10-mail.conf \
	mail_access_groups=spampd

# Create empty bayes training data (if it doesn't exist). Once the files exist,
# ensure they are group-writable so that the Dovecot process has access.
sudo -u spampd /usr/bin/sa-learn --sync 2>/dev/null
chmod -R 660 "$STORAGE_ROOT/mail/spamassassin"
chmod 770 "$STORAGE_ROOT/mail/spamassassin"

# Initial training?
# sa-learn --ham storage/mail/mailboxes/*/*/cur/
# sa-learn --spam storage/mail/mailboxes/*/*/.Spam/cur/

# Kick services.
restart_service spampd
restart_service dovecot

