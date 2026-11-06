Mail-in-a-Box for Debian 13
============================

This is the [quantenland](https://github.com/quantenland/mailinabox) port of [Mail-in-a-Box](https://mailinabox.email) to **Debian 13 (trixie)**. Upstream Mail-in-a-Box, by [@JoshData](https://github.com/JoshData) and [contributors](https://github.com/mail-in-a-box/mailinabox/graphs/contributors), targets Ubuntu 22.04. This branch (`debian13`) is based on upstream v78 and installs onto a fresh Debian 13 amd64 machine.

Mail-in-a-Box helps individuals take back control of their email by defining a one-click, easy-to-deploy SMTP+everything else server: a mail server in a box.

The upstream project website is [https://mailinabox.email](https://mailinabox.email). Use this README for installing **this** port. The upstream setup guide still describes Ubuntu 22.04.

* * *

Our goals are to:

* Make deploying a good mail server easy.
* Promote [decentralization](http://redecentralize.org/), innovation, and privacy on the web.
* Have automated, auditable, and [idempotent](https://web.archive.org/web/20190518072631/https://sharknet.us/2014/02/01/automated-configuration-management-challenges-with-idempotency/) configuration.
* **Not** make a totally unhackable, NSA-proof server.
* **Not** make something customizable by power users.

Additionally, this project has a [Code of Conduct](CODE_OF_CONDUCT.md), which supersedes the goals above. Please review it when joining our community.


In The Box
----------

Mail-in-a-Box turns a fresh Debian 13 (trixie) 64-bit machine into a working mail server by installing and configuring various components.

It is a one-click email appliance. There are no user-configurable setup options. It "just works."

The components installed are:

* SMTP ([postfix](http://www.postfix.org/)), IMAP ([Dovecot](http://dovecot.org/)), CardDAV/CalDAV ([Nextcloud](https://nextcloud.com/)), and Exchange ActiveSync ([z-push](http://z-push.org/)) servers
* Webmail ([Roundcube](http://roundcube.net/)), mail filter rules (thanks to Roundcube and Dovecot), and email client autoconfig settings (served by [nginx](http://nginx.org/))
* Spam filtering ([spamassassin](https://spamassassin.apache.org/)) and greylisting ([postgrey](http://postgrey.schweikert.ch/))
* DNS ([nsd4](https://www.nlnetlabs.nl/projects/nsd/)) with [SPF](https://en.wikipedia.org/wiki/Sender_Policy_Framework), DKIM ([OpenDKIM](http://www.opendkim.org/)), [DMARC](https://en.wikipedia.org/wiki/DMARC), [DNSSEC](https://en.wikipedia.org/wiki/DNSSEC), [DANE TLSA](https://en.wikipedia.org/wiki/DNS-based_Authentication_of_Named_Entities), [MTA-STS](https://tools.ietf.org/html/rfc8461), and [SSHFP](https://tools.ietf.org/html/rfc4255) policy records automatically set
* TLS certificates are automatically provisioned using [Let's Encrypt](https://letsencrypt.org/) for protecting https and all of the other services on the box
* Backups ([duplicity](http://duplicity.nongnu.org/)), firewall ([ufw](https://launchpad.net/ufw)), intrusion protection ([fail2ban](http://www.fail2ban.org/wiki/index.php/Main_Page)), and basic system monitoring ([munin](http://munin-monitoring.org/))

It also includes system management tools:

* Comprehensive health monitoring that checks each day that services are running, ports are open, TLS certificates are valid, and DNS records are correct
* A control panel for adding/removing mail users, aliases, custom DNS records, configuring backups, etc.
* An API for all of the actions on the control panel

Internationalized domain names are supported and configured easily (but SMTPUTF8 is not supported, unfortunately).

It also supports static website hosting since the box is serving HTTPS anyway. (To serve a website for your domains elsewhere, just add a custom DNS "A" record in you Mail-in-a-Box's control panel to point domains to another server.)

For more information on how Mail-in-a-Box handles your privacy, see the [security details page](security.md).


What changed for Debian 13
--------------------------

Debian 13 does not have the Ubuntu package set Mail-in-a-Box v78 was written for. This port follows the versions in the Debian 13 archive:

* PHP 8.4, Nextcloud 34.0.5 (with the one-major-version upgrade ladder from 27), Roundcube 1.7.5, Z-Push 2.7.7
* Postfix 3.10 and Dovecot 2.4, including the Dovecot 2.4 configuration syntax
* Spam learning via Dovecot imapsieve and `sa-learn` (`dovecot-antispam` is not in Debian 13)
* SpamPD settings in `/etc/spampd.cfg`
* The management daemon on Python 3.13, in a virtualenv created with `python3 -m venv`
* `ntpsec` for clock sync. No Ubuntu PPAs
* Z-Push's PHP `imap` extension is installed from PECL (Debian 13 has no `php8.4-imap` package), using the last bookworm `libc-client` libraries

Full-text search of mailboxes is not enabled. Upstream installed `dovecot-lucene` from its own PPA, and Debian 13 does not ship that plugin.

The machine must be Debian 13 amd64, with nothing else already installed on it. A cloud image or a VPS installed from the Debian 13 netinst is the expected starting point. The scripts take over the web server, the DNS resolver, and the firewall.


Installation
------------

You need a fresh Debian 13 amd64 machine with a public IPv4 address, at least 1 GB of RAM (2 GB is comfortable), and a hostname you can put in DNS. SSH in as root, or as a user that can `sudo`.

### One-step install

This downloads `setup/bootstrap.sh` from the `debian13` branch, clones this repository to `/root/mailinabox`, and runs setup:

	curl -fsSL https://raw.githubusercontent.com/quantenland/mailinabox/debian13/setup/bootstrap.sh | sudo bash

If you are already root and `sudo` is not installed yet, drop the `sudo`.

Setup asks for the box hostname and an initial mail user. To run it without prompts, export these before the curl command (or before `setup/start.sh`):

	export NONINTERACTIVE=1
	export PRIMARY_HOSTNAME=box.example.com
	export PUBLIC_IP=auto
	export PUBLIC_IPV6=auto
	export SKIP_NETWORK_CHECKS=1   # only if the machine cannot yet see itself in public DNS

`PUBLIC_IP=auto` asks a public HTTP service for this machine's address.

### Install from a checkout

Use this when you want to read the scripts first, or when you are working on the port:

	sudo apt-get update
	sudo apt-get install -y git ca-certificates
	git clone -b debian13 https://github.com/quantenland/mailinabox
	cd mailinabox
	sudo setup/start.sh

### Local virtual machine

Contributors can boot a Debian 13 VM with Vagrant and VirtualBox. From a checkout of this branch:

	vagrant up --provider=virtualbox --provision

The Vagrantfile uses the `bento/debian-13` box because the official `debian/trixie64` box is published for libvirt only.

The guest gets 2 GB of RAM and the address `192.168.56.4`. See [CONTRIBUTING.md](CONTRIBUTING.md). The first provision downloads Debian packages and the Nextcloud/Roundcube tarballs, so it takes a while and needs a working network.

### Updating

Setup is idempotent. On a machine installed with the one-step command, run that command again. It fast-forwards `/root/mailinabox` to the latest `debian13` commit and runs setup again.

From a checkout you maintain yourself:

	cd mailinabox
	git pull --ff-only
	sudo mailinabox

`mailinabox` is installed on the box the first time setup succeeds. It re-runs setup from the directory setup was last started in.

### After setup

The control panel is at `https://<your-hostname>/admin`. If DNS is not pointed at the box yet, use `https://<public-ip>/admin` and compare the certificate fingerprint that setup prints.

This port is not the upstream project. Please don't file issues about it on the upstream tracker or ask the upstream maintainers for support. Questions about this port belong on https://github.com/quantenland/mailinabox.

Other mail services might still block or spam-filter email sent from a new server. That is true of any mail host you run yourself. The upstream [discussion forum](https://discourse.mailinabox.email/) has a lot of operational experience on that problem.


Contributing and Development
----------------------------

Mail-in-a-Box is an open source project. Your contributions and pull requests are welcome. See [CONTRIBUTING](CONTRIBUTING.md) to get started. 


The Acknowledgements
--------------------

This project was inspired in part by the ["NSA-proof your email in 2 hours"](http://sealedabstract.com/code/nsa-proof-your-e-mail-in-2-hours/) blog post by Drew Crawford, [Sovereign](https://github.com/sovereign/sovereign) by Alex Payne, and conversations with <a href="https://twitter.com/shevski" target="_blank">@shevski</a>, <a href="https://github.com/konklone" target="_blank">@konklone</a>, and <a href="https://github.com/gregelin" target="_blank">@GregElin</a>.

Mail-in-a-Box is similar to [iRedMail](http://www.iredmail.org/) and [Modoboa](https://github.com/tonioo/modoboa).


The History
-----------

* In 2007 I wrote a relatively popular Mozilla Thunderbird extension that added client-side SPF and DKIM checks to mail to warn users about possible phishing: [add-on page](https://addons.mozilla.org/en-us/thunderbird/addon/sender-verification-anti-phish/), [source](https://github.com/JoshData/thunderbird-spf).
* In August 2013 I began Mail-in-a-Box by combining my own mail server configuration with the setup in ["NSA-proof your email in 2 hours"](http://sealedabstract.com/code/nsa-proof-your-e-mail-in-2-hours/) and making the setup steps reproducible with bash scripts.
* Mail-in-a-Box was a semifinalist in the 2014 [Knight News Challenge](https://www.newschallenge.org/challenge/2014/submissions/mail-in-a-box), but it was not selected as a winner.
* Mail-in-a-Box hit the front page of Hacker News in [April](https://news.ycombinator.com/item?id=7634514) 2014, [September](https://news.ycombinator.com/item?id=8276171) 2014, [May](https://news.ycombinator.com/item?id=9624267) 2015, and [November](https://news.ycombinator.com/item?id=13050500) 2016.
* FastCompany mentioned Mail-in-a-Box a [roundup of privacy projects](http://www.fastcompany.com/3047645/your-own-private-cloud) on June 26, 2015.
