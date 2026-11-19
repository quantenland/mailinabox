#!/usr/bin/env python3
"""Greylisting is off by default and can be turned on without dropping other filters."""

import io
import os
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "management"))

import greylisting

SENDER_RESTRICTIONS = (
	"reject_non_fqdn_sender,reject_unknown_sender_domain,"
	"reject_authenticated_sender_login_mismatch,"
	"reject_rhsbl_sender dbl.spamhaus.org=127.0.1.[2..99]"
)

ON_LINE = (
	"permit_sasl_authenticated,permit_mynetworks,"
	"reject_rbl_client zen.spamhaus.org=127.0.0.[2..11],"
	"reject_unlisted_recipient,"
	"check_policy_service inet:127.0.0.1:10023,"
	"check_policy_service inet:127.0.0.1:12340"
)
OFF_LINE = ON_LINE.replace(",check_policy_service inet:127.0.0.1:10023", "")


class RestrictionTests(unittest.TestCase):
	def test_default_line_does_not_consult_postgrey(self):
		line = greylisting.canonical_restrictions(False)
		self.assertEqual(line, OFF_LINE)
		self.assertNotIn("10023", line)
		self.assertIn("check_policy_service inet:127.0.0.1:12340", line)
		for check in (
			"permit_sasl_authenticated",
			"permit_mynetworks",
			"reject_rbl_client zen.spamhaus.org=127.0.0.[2..11]",
			"reject_unlisted_recipient",
		):
			self.assertIn(check, line)

	def test_enabled_line_puts_postgrey_before_quota(self):
		line = greylisting.canonical_restrictions(True)
		self.assertEqual(line, ON_LINE)
		self.assertIn(
			"check_policy_service inet:127.0.0.1:10023,check_policy_service inet:127.0.0.1:12340",
			line,
		)
		self.assertLess(line.index("10023"), line.index("12340"))

	def test_toggle_removes_and_restores_only_postgrey(self):
		custom = ON_LINE + ",check_policy_service unix:private/extra"
		off = greylisting.restrictions_with_greylisting(custom, False)
		self.assertNotIn("10023", off)
		self.assertIn("check_policy_service inet:127.0.0.1:12340", off)
		self.assertIn("unix:private/extra", off)
		self.assertIn("zen.spamhaus.org", off)
		self.assertIn("permit_sasl_authenticated", off)
		on = greylisting.restrictions_with_greylisting(off, True)
		self.assertEqual(on, custom)
		self.assertEqual(greylisting.restrictions_with_greylisting(on, True), on)
		self.assertEqual(greylisting.restrictions_with_greylisting(off, False), off)

	def test_postgrey_is_inserted_before_quota_not_appended_after_it(self):
		current = (
			"permit_mynetworks,reject_unlisted_recipient,"
			"check_policy_service inet:127.0.0.1:12340,permit_sasl_authenticated"
		)
		updated = greylisting.restrictions_with_greylisting(current, True)
		self.assertEqual(
			updated,
			"permit_mynetworks,reject_unlisted_recipient,"
			"check_policy_service inet:127.0.0.1:10023,"
			"check_policy_service inet:127.0.0.1:12340,permit_sasl_authenticated",
		)


class SettingsTests(unittest.TestCase):
	def test_missing_file_is_off(self):
		with tempfile.TemporaryDirectory() as storage:
			self.assertFalse(greylisting.get_greylisting({"STORAGE_ROOT": storage}))

	def test_parser_matches_saved_choice(self):
		self.assertFalse(greylisting.parse_greylisting_flag("privacy: true\n"))
		self.assertFalse(greylisting.parse_greylisting_flag("greylisting: false\nprivacy: true\n"))
		self.assertTrue(greylisting.parse_greylisting_flag("privacy: true\ngreylisting: true\n"))
		self.assertFalse(greylisting.parse_greylisting_flag("greylisting: true\ngreylisting: false\n"))
		self.assertFalse(greylisting.parse_greylisting_flag("greylisting: maybe\n"))

	def test_rtyaml_round_trip_preserves_privacy_and_both_states(self):
		import utils
		with tempfile.TemporaryDirectory() as storage:
			env = {"STORAGE_ROOT": storage}
			with open(os.path.join(storage, "settings.yaml"), "w", encoding="utf-8") as fh:
				fh.write("privacy: true\n")
			main_cf = os.path.join(storage, "main.cf")
			with open(main_cf, "w", encoding="utf-8") as fh:
				fh.write(
					"smtpd_sender_restrictions=" + SENDER_RESTRICTIONS + "\n"
					"smtpd_recipient_restrictions=" + OFF_LINE + "\n"
				)

			self.assertEqual(
				greylisting.set_greylisting(True, env, main_cf=main_cf, reload_postfix=False),
				"OK",
			)
			self.assertTrue(greylisting.get_greylisting(env))
			self.assertTrue(utils.load_settings(env)["privacy"])
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions"),
				ON_LINE,
			)
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_sender_restrictions"),
				SENDER_RESTRICTIONS,
			)

			greylisting.set_greylisting(False, env, main_cf=main_cf, reload_postfix=False)
			self.assertFalse(greylisting.get_greylisting(env))
			self.assertTrue(utils.load_settings(env)["privacy"])
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions"),
				OFF_LINE,
			)
			self.assertNotIn("10023", greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions"))
			# Turning it off again does not rewrite the saved false into a missing key.
			greylisting.set_greylisting(False, env, main_cf=main_cf, reload_postfix=False)
			self.assertIn("greylisting", utils.load_settings(env))
			self.assertFalse(utils.load_settings(env)["greylisting"])

	def test_successful_toggle_reloads_postfix_for_both_states(self):
		with tempfile.TemporaryDirectory() as storage:
			env = {"STORAGE_ROOT": storage}
			main_cf = os.path.join(storage, "main.cf")
			with open(main_cf, "w", encoding="utf-8") as fh:
				fh.write("smtpd_recipient_restrictions=" + ON_LINE + "\n")
			marker = os.path.join(storage, "reloads")

			def reload_command(word):
				# python -c puts the following arguments in sys.argv.
				return [
					sys.executable, "-c",
					"import sys; open(sys.argv[1], 'a', encoding='utf-8').write(sys.argv[2] + '\\n')",
					marker, word,
				]

			# The box was previously greylisting. Saving "off" must drop only
			# port 10023 and reload Postfix.
			greylisting.set_greylisting(
				False, env, main_cf=main_cf, reload_command=reload_command("off"))
			self.assertFalse(greylisting.get_greylisting(env))
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions"),
				OFF_LINE,
			)

			greylisting.set_greylisting(
				True, env, main_cf=main_cf, reload_command=reload_command("on"))
			self.assertTrue(greylisting.get_greylisting(env))
			active = greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions")
			self.assertEqual(active, ON_LINE)
			self.assertLess(active.index("10023"), active.index("12340"))
			with open(marker, encoding="utf-8") as fh:
				self.assertEqual(fh.read().splitlines(), ["off", "on"])

	def test_failed_reload_keeps_the_saved_choice_and_main_cf(self):
		with tempfile.TemporaryDirectory() as storage:
			env = {"STORAGE_ROOT": storage}
			main_cf = os.path.join(storage, "main.cf")
			original = "smtpd_recipient_restrictions=" + OFF_LINE + "\n"
			with open(main_cf, "w", encoding="utf-8") as fh:
				fh.write(original)
			with self.assertRaises(ValueError):
				greylisting.set_greylisting(
					True,
					env,
					main_cf=main_cf,
					reload_postfix=True,
					reload_command=["/bin/false"],
				)
			self.assertFalse(greylisting.get_greylisting(env))
			self.assertFalse(os.path.exists(os.path.join(storage, "settings.yaml")))
			with open(main_cf, encoding="utf-8") as fh:
				self.assertEqual(fh.read(), original)


class SetupHelperTests(unittest.TestCase):
	def test_restrictions_command_follows_the_saved_choice(self):
		with tempfile.TemporaryDirectory() as storage:
			env = {"STORAGE_ROOT": storage}
			buf = io.StringIO()
			with redirect_stdout(buf):
				code = greylisting.main(["greylisting.py", "restrictions"], env=env)
			self.assertEqual(code, 0)
			self.assertEqual(buf.getvalue().strip(), OFF_LINE)

			with open(os.path.join(storage, "settings.yaml"), "w", encoding="utf-8") as fh:
				fh.write("greylisting: true\n")
			buf = io.StringIO()
			with redirect_stdout(buf):
				greylisting.main(["greylisting.py", "restrictions"], env=env)
			self.assertEqual(buf.getvalue().strip(), ON_LINE)

	def test_setup_does_not_ask_and_does_not_hardcode_postgrey_in_the_restriction_line(self):
		with open(os.path.join(ROOT, "setup", "questions.sh"), encoding="utf-8") as fh:
			questions = fh.read()
		self.assertNotIn("greylist", questions.lower())
		with open(os.path.join(ROOT, "setup", "mail-postfix.sh"), encoding="utf-8") as fh:
			postfix = fh.read()
		self.assertIn("management/greylisting.py restrictions", postfix)
		self.assertIn('smtpd_recipient_restrictions="$RECIPIENT_RESTRICTIONS"', postfix)
		self.assertNotIn("smtpd_recipient_restrictions=\"permit_", postfix)
		self.assertIn("postgrey", postfix)
		self.assertIn("--inet=127.0.0.1:10023", postfix)
		with open(os.path.join(ROOT, "management", "templates", "mail-guide.html"), encoding="utf-8") as fh:
			guide = fh.read()
		self.assertNotIn("Your box uses a technique called greylisting", guide)
		self.assertIn("off by default", guide)
		self.assertIn("/mail/greylisting", guide)


class MainCfEditTests(unittest.TestCase):
	def test_edit_keeps_sender_restrictions_and_commented_history(self):
		with tempfile.TemporaryDirectory() as storage:
			main_cf = os.path.join(storage, "main.cf")
			with open(main_cf, "w", encoding="utf-8") as fh:
				fh.write(textwrap.dedent(f"""\
					# Mail-in-a-Box
					smtpd_sender_restrictions={SENDER_RESTRICTIONS}
					smtpd_recipient_restrictions={ON_LINE}
					virtual_transport=lmtp:[127.0.0.1]:10025
				"""))
			greylisting.apply_greylisting(False, main_cf=main_cf, reload_postfix=False)
			active = greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions")
			self.assertEqual(active, OFF_LINE)
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_sender_restrictions"),
				SENDER_RESTRICTIONS,
			)
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "virtual_transport"),
				"lmtp:[127.0.0.1]:10025",
			)
			with open(main_cf, encoding="utf-8") as fh:
				body = fh.read()
			self.assertIn("#smtpd_recipient_restrictions=" + ON_LINE, body.replace("# ", "#"))

			greylisting.apply_greylisting(True, main_cf=main_cf, reload_postfix=False)
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_recipient_restrictions"),
				ON_LINE,
			)
			# The commented previous line must not be treated as the active one.
			self.assertEqual(
				greylisting.read_postfix_setting(main_cf, "smtpd_sender_restrictions"),
				SENDER_RESTRICTIONS,
			)


if __name__ == "__main__":
	unittest.main()
