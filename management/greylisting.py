# Greylisting is optional and off by default.
#
# Postgrey stays installed and keeps listening on 127.0.0.1:10023. Postfix
# consults it only when an administrator turns greylisting on after install.
# The choice is stored in STORAGE_ROOT/settings.yaml (the same file as the
# privacy setting) under the key "greylisting". A missing key means off.
# Setup reads that key and does not ask a question about it, so re-running
# setup keeps the saved choice.

import os
import sys

POSTGREY_CHECK = "check_policy_service inet:127.0.0.1:10023"
QUOTA_CHECK = "check_policy_service inet:127.0.0.1:12340"
MAIN_CF = "/etc/postfix/main.cf"

# smtpd_recipient_restrictions without the postgrey policy. The quota
# policy on port 12340 stays last so greylisting can be inserted in front
# of it. Spamhaus and the other checks are unchanged.
BASE_RECIPIENT_CHECKS = (
	"permit_sasl_authenticated",
	"permit_mynetworks",
	"reject_rbl_client zen.spamhaus.org=127.0.0.[2..11]",
	"reject_unlisted_recipient",
	QUOTA_CHECK,
)

_TRUE = {"true", "yes", "on", "y"}
_FALSE = {"false", "no", "off", "n", "~", "null"}


def canonical_restrictions(enabled):
	"""Recipient restrictions Mail-in-a-Box writes during setup."""
	checks = list(BASE_RECIPIENT_CHECKS)
	if enabled:
		checks.insert(checks.index(QUOTA_CHECK), POSTGREY_CHECK)
	return ",".join(checks)


def _norm(check):
	return " ".join(check.split())


def restrictions_with_greylisting(current, enabled):
	"""Add or remove only the postgrey (port 10023) policy check.

	The check is placed immediately before the Dovecot quota policy on
	port 12340. Every other check in the current list is left as it is.
	An empty current value falls back to the setup line.
	"""
	if current is None or current.strip() == "":
		return canonical_restrictions(enabled)
	checks = [part.strip() for part in current.split(",")]
	checks = [part for part in checks if part and _norm(part) != POSTGREY_CHECK]
	if enabled:
		for index, part in enumerate(checks):
			if _norm(part) == QUOTA_CHECK:
				checks.insert(index, POSTGREY_CHECK)
				break
		else:
			checks.append(POSTGREY_CHECK)
	return ",".join(checks)


def parse_greylisting_flag(text):
	"""True only when settings.yaml explicitly turns greylisting on.

	rtyaml writes `greylisting: true` or `greylisting: false`. Anything
	missing or unrecognized stays off so a fresh install does not greylist.
	"""
	enabled = False
	for raw in text.splitlines():
		line = raw.strip()
		if not line or line.startswith("#") or ":" not in line:
			continue
		key, value = line.split(":", 1)
		if key.strip() != "greylisting":
			continue
		value = value.strip()
		if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
			value = value[1:-1].strip()
		token = value.split()[0].lower() if value else ""
		enabled = token in _TRUE
		if token not in _TRUE and token not in _FALSE:
			enabled = False
	return enabled


def get_greylisting(env):
	path = os.path.join(env["STORAGE_ROOT"], "settings.yaml")
	try:
		with open(path, encoding="utf-8") as fh:
			text = fh.read()
	except FileNotFoundError:
		return False
	return parse_greylisting_flag(text)


def read_postfix_setting(path, name):
	"""Return the last active (uncommented) value of a main.cf setting."""
	try:
		with open(path, encoding="utf-8") as fh:
			lines = fh.readlines()
	except FileNotFoundError:
		return None
	value = None
	index = 0
	prefix = name
	while index < len(lines):
		stripped = lines[index].strip()
		index += 1
		if not stripped or stripped.startswith("#"):
			continue
		matched = False
		for delimiter in ("=", " "):
			head, sep, tail = stripped.partition(delimiter)
			if sep and head.strip() == prefix:
				val = tail
				matched = True
				break
		if not matched:
			continue
		while index < len(lines) and lines[index][:1] in (" ", "\t"):
			val += " " + lines[index].strip()
			index += 1
		value = val.strip()
	return value


def _editconf_path():
	root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
	return os.path.join(root, "tools", "editconf.py")


def _run(cmd):
	import utils
	code, output = utils.shell("check_output", cmd, capture_stderr=True, trap=True)
	if code != 0:
		detail = (output or "").strip()
		if not detail:
			detail = f"exit status {code}"
		raise ValueError(detail)
	return output


def _reload_postfix(reload_command):
	_run(reload_command or ["/usr/sbin/service", "postfix", "reload"])


def apply_greylisting(enabled, main_cf=MAIN_CF, reload_postfix=True, reload_command=None):
	"""Rewrite smtpd_recipient_restrictions and, when asked, reload Postfix.

	Only the port-10023 policy check is added or removed. On a reload
	failure the previous main.cf contents are put back.
	"""
	current = read_postfix_setting(main_cf, "smtpd_recipient_restrictions")
	updated = restrictions_with_greylisting(current, enabled)
	if current != updated:
		original = None
		existed = os.path.exists(main_cf)
		if existed:
			with open(main_cf, encoding="utf-8") as fh:
				original = fh.read()
		_run([sys.executable, _editconf_path(), main_cf, "smtpd_recipient_restrictions=" + updated])
		if reload_postfix:
			try:
				_reload_postfix(reload_command)
			except Exception:
				if original is None:
					if os.path.exists(main_cf):
						os.remove(main_cf)
				else:
					with open(main_cf, "w", encoding="utf-8") as fh:
						fh.write(original)
				raise
	elif reload_postfix:
		_reload_postfix(reload_command)
	return updated


def set_greylisting(enabled, env, main_cf=MAIN_CF, reload_postfix=True, reload_command=None):
	"""Save the administrator's choice and make Postfix match it.

	Postfix is updated first. settings.yaml is written only after that
	succeeds, so a failed reload does not record a choice Postfix is not
	using. Other keys in settings.yaml (such as privacy) are preserved.
	"""
	import utils
	enabled = bool(enabled)
	previous = get_greylisting(env)
	apply_greylisting(
		enabled,
		main_cf=main_cf,
		reload_postfix=reload_postfix,
		reload_command=reload_command,
	)
	if enabled == previous:
		return "OK"
	config = utils.load_settings(env)
	config["greylisting"] = enabled
	try:
		utils.write_settings(config, env)
	except Exception:
		apply_greylisting(
			previous,
			main_cf=main_cf,
			reload_postfix=reload_postfix,
			reload_command=reload_command,
		)
		raise
	return "OK"


def main(argv=None, env=None):
	if argv is None:
		argv = sys.argv
	if len(argv) != 2 or argv[1] != "restrictions":
		print("usage: greylisting.py restrictions", file=sys.stderr)
		return 2
	if env is None:
		import utils
		env = utils.load_environment()
	# Setup writes this whole line. Off unless settings.yaml says otherwise.
	print(canonical_restrictions(get_greylisting(env)))
	return 0


if __name__ == "__main__":
	sys.exit(main())
