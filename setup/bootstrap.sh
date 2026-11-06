#!/bin/bash
#########################################################
# Install this Debian 13 (trixie) port of Mail-in-a-Box.
#
# On a fresh Debian 13 amd64 machine, as root:
#
#   curl -fsSL https://raw.githubusercontent.com/quantenland/mailinabox/debian13/setup/bootstrap.sh | bash
#
# Re-running the same command fast-forwards the checkout to the
# latest debian13 commit and runs setup again. Setup is idempotent.
#
# To review the scripts before they run, clone the branch and start
# setup yourself. See README.md.
#########################################################

set -euo pipefail

REPO="${MIAB_REPO:-https://github.com/quantenland/mailinabox}"
BRANCH="${MIAB_BRANCH:-debian13}"
DEST="${MIAB_DEST:-$HOME/mailinabox}"

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root. Did you leave out sudo?"
	exit 1
fi

if [[ ! -f /etc/os-release ]]; then
	echo "This installer only supports Debian 13 (trixie)."
	exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
	debian:13|debian:13.*) ;;
	*)
		echo "This installer only supports Debian 13 (trixie). You are running:"
		echo
		echo "${ID:-unknown} ${VERSION_ID:-}"
		exit 1
		;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git sudo locales

# locale-gen only emits locales enabled in /etc/locale.gen. setup/start.sh
# needs en_US.UTF-8 before it will talk to Python.
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen en_US.UTF-8

if [[ ! -d "$DEST/.git" ]]; then
	echo "Cloning $REPO ($BRANCH) into $DEST ..."
	git clone --branch "$BRANCH" --single-branch "$REPO" "$DEST"
else
	echo "Updating $DEST to origin/$BRANCH ..."
	git -C "$DEST" fetch --prune origin "$BRANCH"
	git -C "$DEST" checkout -q "$BRANCH"
	git -C "$DEST" merge --ff-only "origin/$BRANCH"
fi

cd "$DEST"
exec setup/start.sh
