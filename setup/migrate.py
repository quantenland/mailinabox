#!/usr/bin/python3

# Schema changes for later releases of this Debian 13 port.
#
# The setup scripts create the current storage layout themselves. Migrations
# numbered 15 and below belonged to older Mail-in-a-Box releases and are not
# part of this port. Add migration_16, migration_17, and so on when a later
# release of this port changes data that is already stored.

import os
import sys

sys.path.insert(0, 'management')
from utils import load_environment

# Highest migration number of the old Mail-in-a-Box series. Fresh installs
# record this number. Later releases of this port start at 16.
BASELINE = 15


def get_current_migration():
	ver = BASELINE
	while globals().get("migration_%d" % (ver + 1)):
		ver += 1
	return ver


def run_migrations():
	if not os.access("/etc/mailinabox.conf", os.W_OK, effective_ids=True):
		print("This script must be run as root.", file=sys.stderr)
		sys.exit(1)

	env = load_environment()

	migration_id_file = os.path.join(env['STORAGE_ROOT'], 'mailinabox.version')
	migration_id = None
	if os.path.exists(migration_id_file):
		with open(migration_id_file, encoding='utf-8') as f:
			migration_id = f.read().strip()

	if migration_id is None:
		print()
		print(f"{migration_id_file} file doesn't exists. Skipping migration...")
		return

	ourver = int(migration_id)
	if ourver < BASELINE:
		ourver = BASELINE
		with open(migration_id_file, "w", encoding='utf-8') as f:
			f.write(str(ourver) + "\n")

	while True:
		next_ver = ourver + 1
		migration_func = globals().get("migration_%d" % next_ver)

		if not migration_func:
			break

		print()
		print("Running migration to Mail-in-a-Box #%d..." % next_ver)

		try:
			migration_func(env)
		except Exception as e:
			print()
			print("Error running the migration script:")
			print()
			print(e)
			print()
			print("Your system may be in an inconsistent state now. We're terribly sorry. A re-install from a backup might be the best way to continue.")
			sys.exit(1)

		ourver = next_ver

		with open(migration_id_file, "w", encoding='utf-8') as f:
			f.write(str(ourver) + "\n")


if __name__ == "__main__":
	if sys.argv[-1] == "--current":
		print(str(get_current_migration()))
	elif sys.argv[-1] == "--migrate":
		run_migrations()
