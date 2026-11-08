Mail in a Box on Debian 13 Trixie
====================================

This is a fork of [Mail-in-a-Box](https://github.com/mail-in-a-box/mailinabox) by [@JoshData](https://github.com/JoshData) and [contributors](https://github.com/mail-in-a-box/mailinabox/graphs/contributors). It is being ported to Debian 13 (Trixie), and the software it installs is updated to current releases. It is still a one-click mail server: SMTP, IMAP, webmail, contacts, calendar, and DNS on one machine.

**The original project website and setup guide are at [https://mailinabox.email](https://mailinabox.email).**

Compared with the original
--------------------------

The original column is what [mail-in-a-box/mailinabox](https://github.com/mail-in-a-box/mailinabox) `master` installs today. The fork column is what this repository installs on Debian 13.

| Software | Original Mail-in-a-Box | This fork |
| --- | --- | --- |
| Operating system | Ubuntu 22.04 LTS | Debian 13 (Trixie). Ubuntu 22.04 is also accepted |
| PHP | 8.0 | 8.4 |
| Nextcloud | 27.1.11 | 35.0.2 |
| Contacts | 5.5.4 | 8.9.5 |
| Calendar | 4.7.20 | 6.6.5 |
| user_external | 3.4.0 | 4.0.0 |
| Roundcube | 1.6.20 | 1.6.20 |
| Roundcube CardDAV | 4.4.3 | 4.4.3 |
| Z-Push | 2.7.7 | 2.7.7 |
| cryptography | 37.0.2 | 50.0.2 |
| Admin UI jQuery | 2.2.4 | 2.2.4 |
| Admin UI Bootstrap | 3.4.1 | 3.4.1 |
| Dovecot | 2.3, from Ubuntu | 2.4, from Debian |
| Postfix, Nginx, SpamAssassin, NSD, BIND, Certbot, fail2ban | Ubuntu 22.04 packages | Debian 13 packages |
| Spam training when mail is moved to Spam | dovecot-antispam | Not installed. Debian 13 has no Dovecot 2.4 build of that plugin |

Roundcube, Z-Push, jQuery, and Bootstrap are the same pins as the original. Nextcloud, its apps, PHP, and the cryptography library are the ones this fork moves forward. On Ubuntu 22.04 this fork still installs those newer application versions, and Dovecot stays Ubuntu's 2.3.

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

Mail-in-a-Box turns a fresh Debian 13 (Trixie) or Ubuntu 22.04 LTS 64-bit machine into a working mail server by installing and configuring various components.

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


Installation
------------

Use a fresh machine that will only run mail. Debian 13 (Trixie) and Ubuntu 22.04 LTS, 64-bit, are supported. Give it at least 1 GB of RAM (the installer refuses to run below 512 MB) and a public IP address that can make outbound connections on port 25.

On the machine:

```
sudo apt update
sudo apt install -y git
git clone https://github.com/quantenland/mailinabox
cd mailinabox
sudo setup/start.sh
```

`main` is the branch to install. This port sets up a new box. It does not upgrade an older Mail-in-a-Box data directory.

Setup asks for a few things:

* The time zone, through Debian's `tzdata` prompt. Pick the zone you live in.
* The email address that will administer the box. The domain after the `@` must be one you control.
* The hostname. Keep the suggestion, `box.` plus that domain.
* The public IP, when the machine cannot detect it. Leave IPv6 empty if the machine has none.
* A password for that first mail account. The prompt does not echo it.

The installer then installs and configures the mail stack and registers with Let's Encrypt. When it finishes it prints `Your Mail-in-a-Box is running.` and the control panel address:

	https://box.example.com/admin

Log in with the email address and the password you just chose. If the hostname does not resolve yet, open the `https://<ip>/admin` address printed at the end and check the certificate fingerprint shown there. The control panel lists the nameserver records to set at the domain registrar.

To change an answer later, run `sudo mailinabox` from this directory.

The [upstream setup guide](https://mailinabox.email/guide.html) describes the same kind of appliance. Install from this repository, not from that guide's one-line installer, which tracks the upstream Ubuntu release.

For help, DO NOT contact Josh directly --- I don't do tech support by email or tweet (no exceptions).

Post your question on the [discussion forum](https://discourse.mailinabox.email/) instead, where maintainers and Mail-in-a-Box users may be able to help you.

Note that while we want everything to "just work," we can't control the rest of the Internet. Other mail services might block or spam-filter email sent from your Mail-in-a-Box.
This is a challenge faced by everyone who runs their own mail server, with or without Mail-in-a-Box. See our discussion forum for tips about that.


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
