#!/usr/bin/env python3
"""Unit tests for the parts of macos/steamplay that work on text and numbers alone: Steam's VDF
files as it reads and writes them, version numbers, what a game's runs say, the judgement of
"discover", and the guard's limit. Nothing here touches Steam, its folder or the network.

    /usr/bin/python3 -B -m unittest macos/tests/test_steamplay.py

Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
TEMP = tempfile.mkdtemp(prefix="steamplay-test-")
# the script reads these once, as it is loaded
os.environ.update({"STEAMPLAY_HOME": os.path.join(TEMP, "home"), "STEAM_ROOT": os.path.join(TEMP, "steam"),
                   "STEAMPLAY_GUARD_LOG": os.path.join(TEMP, "logs", "guard.log"),
                   "STEAMPLAY_TOOLS_DIR": os.path.join(TEMP, "tools"), "STEAMPLAY_FAKE_STEAM": "1",
                   "STEAMPLAY_NO_SYSTEM_LOG": "1"})
_loader = importlib.machinery.SourceFileLoader("steamplay", os.path.join(HERE, "..", "steamplay"))
_spec = importlib.util.spec_from_loader("steamplay", _loader)
sp = importlib.util.module_from_spec(_spec)
_loader.exec_module(sp)


def quiet(test):
    """Keeps what the script prints for the player out of the test's output."""
    patch = mock.patch("builtins.print")
    patch.start()
    test.addCleanup(patch.stop)


def tearDownModule():
    shutil.rmtree(TEMP, ignore_errors=True)


# as Steam writes localconfig.vdf: a key or a brace a line, tabs, two tabs before a value
LOCALCONFIG = "\n".join([
    '"UserLocalConfigStore"',
    '{',
    '\t"Software"',
    '\t{',
    '\t\t"Valve"',
    '\t\t{',
    '\t\t\t"Steam"',
    '\t\t\t{',
    '\t\t\t\t"apps"',
    '\t\t\t\t{',
    '\t\t\t\t\t"500"',
    '\t\t\t\t\t{',
    '\t\t\t\t\t\t"LastPlayed"\t\t"1763000000"',
    '\t\t\t\t\t\t"LaunchOptions"\t\t"-novid"',
    '\t\t\t\t\t}',
    '\t\t\t\t\t"620"',
    '\t\t\t\t\t{',
    '\t\t\t\t\t\t"LastPlayed"\t\t"1763000001"',
    '\t\t\t\t\t}',
    '\t\t\t\t}',
    '\t\t\t}',
    '\t\t}',
    '\t}',
    '}',
    ''])
APPS = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps"]


class TextVdf(unittest.TestCase):
    def test_parse_gives_pairs_in_order(self):
        apps = sp.vdf_block(sp.vdf_parse(LOCALCONFIG), APPS)
        self.assertEqual([k for k, _ in apps], ["500", "620"])
        self.assertEqual(apps[0][1], [["LastPlayed", "1763000000"], ["LaunchOptions", "-novid"]])

    def test_dump_writes_back_what_was_read(self):
        self.assertEqual("\n".join(sp.vdf_dump(sp.vdf_parse(LOCALCONFIG))) + "\n", LOCALCONFIG)

    def test_quotes_and_backslashes_come_back(self):
        text = '"a"\n{\n\t"path"\t\t"C:\\\\Games\\\\x"\n\t"say"\t\t"a \\"word\\""\n}\n'
        tree = sp.vdf_parse(text)
        self.assertEqual(tree[0][1], [["path", "C:\\Games\\x"], ["say", 'a "word"']])
        self.assertEqual("\n".join(sp.vdf_dump(tree)) + "\n", text)

    def test_newline_and_tab_escapes_come_back(self):
        text = '"a"\n{\n\t"note"\t\t"one\\ntwo\\tthree"\n}\n'
        tree = sp.vdf_parse(text)
        self.assertEqual(tree[0][1], [["note", "one\ntwo\tthree"]])
        self.assertEqual("\n".join(sp.vdf_dump(tree)) + "\n", text)

    def test_comments_and_braces_in_values(self):
        tree = sp.vdf_parse('// a note\n"a"\n{\n\t"k"\t\t"{ not a block } // nor a comment"\n}\n')
        self.assertEqual(tree, [["a", [["k", "{ not a block } // nor a comment"]]]])

    def test_block_is_found_without_case_and_made_when_missing(self):
        tree = sp.vdf_parse(LOCALCONFIG)
        self.assertIs(sp.vdf_block(tree, [k.upper() for k in APPS]), sp.vdf_block(tree, APPS))
        made = sp.vdf_block(tree, APPS[:4] + ["CompatToolMapping"])
        self.assertEqual(made, [])
        made.append(["0", [["name", "proton-macos"]]])
        self.assertIn('"CompatToolMapping"', "\n".join(sp.vdf_dump(tree)))


class AppSetting(unittest.TestCase):
    def test_changes_a_setting_and_nothing_else(self):
        text, old, new = sp.app_setting(LOCALCONFIG, 500, "LaunchOptions", lambda v: v + " -console")
        self.assertEqual((old, new), ("-novid", "-novid -console"))
        self.assertEqual(text, LOCALCONFIG.replace('"-novid"', '"-novid -console"'))

    def test_removes_a_setting(self):
        text, old, new = sp.app_setting(LOCALCONFIG, 500, "LaunchOptions", lambda v: None)
        self.assertEqual((old, new), ("-novid", None))
        self.assertNotIn("LaunchOptions", text)
        self.assertEqual(sp.vdf_block(sp.vdf_parse(text), APPS)[0][1], [["LastPlayed", "1763000000"]])

    def test_adds_a_setting_to_an_app_without_it(self):
        text, old, new = sp.app_setting(LOCALCONFIG, 620, "LaunchOptions", lambda v: 'say "hi"')
        self.assertIsNone(old)
        apps = dict((k, dict(v)) for k, v in sp.vdf_block(sp.vdf_parse(text), APPS))
        self.assertEqual(apps["620"], {"LastPlayed": "1763000001", "LaunchOptions": 'say "hi"'})
        self.assertEqual(apps["500"]["LaunchOptions"], "-novid")

    def test_adds_an_app_that_is_not_there(self):
        text, old, new = sp.app_setting(LOCALCONFIG, 730, "LaunchOptions", lambda v: "-x")
        apps = dict((k, dict(v)) for k, v in sp.vdf_block(sp.vdf_parse(text), APPS))
        self.assertEqual(apps["730"], {"LaunchOptions": "-x"})
        self.assertEqual(len(apps), 3)

    def test_leaves_the_text_alone_when_nothing_is_wanted(self):
        text, old, new = sp.app_setting(LOCALCONFIG, 730, "LaunchOptions", lambda v: None)
        self.assertEqual(text, LOCALCONFIG)


class Unhook(unittest.TestCase):
    def setUp(self):
        self.config = os.path.join(sp.STEAM_ROOT, "userdata", "1234", "config")
        os.makedirs(self.config)
        self.path = os.path.join(self.config, "localconfig.vdf")
        quiet(self)

    def tearDown(self):
        shutil.rmtree(sp.STEAM_ROOT)

    def options(self):
        with open(self.path) as f:
            apps = sp.vdf_block(sp.vdf_parse(f.read()), APPS)
        return {k: dict(v).get("LaunchOptions") for k, v in apps}

    def test_takes_out_the_old_option_and_keeps_the_players_own(self):
        hooked = LOCALCONFIG.replace('"-novid"', '"\\"/x/macos/steamplay-launch\\" %command% -novid"')
        hooked = hooked.replace('\t\t\t\t\t\t"LastPlayed"\t\t"1763000001"',
                                '\t\t\t\t\t\t"LastPlayed"\t\t"1763000001"\n'
                                '\t\t\t\t\t\t"LaunchOptions"\t\t"\\"/x/macos/steamplay-launch\\" %command%"')
        with open(self.path, "w") as f:
            f.write(hooked)
        self.assertEqual(sorted(sp.hooked_apps()), [500, 620])
        sp.unhook([500, 620])
        self.assertEqual(self.options(), {"500": "-novid", "620": None})
        self.assertEqual(sp.hooked_apps(), [])
        self.assertEqual(len(os.listdir(sp.BACKUPS)), 1)

    def test_leaves_another_wrapper_alone(self):
        other = LOCALCONFIG.replace('"-novid"', '"mangohud %command%"')
        with open(self.path, "w") as f:
            f.write(other)
        sp.unhook([500])
        with open(self.path) as f:
            self.assertEqual(f.read(), other)


class Versions(unittest.TestCase):
    def test_numbers_compare_as_numbers(self):
        self.assertLess(sp.version_key("0.3.1"), sp.version_key("0.10.0"))
        self.assertEqual(sp.version_key("v0.3.1"), (0, 3, 1))
        self.assertEqual(sp.version_key("0.3.1-rc2"), (0, 3, 1))

    def test_newer_releases_are_the_ones_above_this_version(self):
        known, version = sp.known_releases, sp.protium_version
        sp.known_releases = lambda now=False: [{"version": v} for v in ("0.4.0", "0.3.1", "0.3.0", "0.10.0")]
        try:
            sp.protium_version = lambda: "0.3.1"
            self.assertEqual([r["version"] for r in sp.newer_releases()], ["0.4.0", "0.10.0"])
            sp.protium_version = lambda: ""          # a checkout without a VERSION file
            self.assertEqual(sp.newer_releases(), [])
        finally:
            sp.known_releases, sp.protium_version = known, version


def ran(end, seconds):
    return {"by": "run", "end": end, "seconds": seconds}


class Outcome(unittest.TestCase):
    def test_nothing_known(self):
        self.assertEqual(sp.outcome([]), (None, ""))

    def test_what_the_player_said_counts_before_any_run(self):
        runs = [ran("crash", 5), {"by": "user", "verdict": "works", "note": "fine"}, ran("crash", 5)]
        self.assertEqual(sp.outcome(runs), (True, "you said: works (fine)"))
        self.assertIs(sp.outcome([{"by": "user", "verdict": "plays-with-problems"}])[0], True)
        self.assertIs(sp.outcome([{"by": "user", "verdict": "menu-only"}])[0], False)
        self.assertIs(sp.outcome([ran("ended", 3000), {"by": "user", "verdict": "broken"}])[0], False)

    def test_the_newest_verdict_of_the_player_wins(self):
        runs = [{"by": "user", "verdict": "broken"}, {"by": "user", "verdict": "works"}]
        self.assertIs(sp.outcome(runs)[0], True)

    def test_a_crash_after_a_short_run_is_bad(self):
        self.assertIs(sp.outcome([ran("crash", 40)])[0], False)
        self.assertIs(sp.outcome([ran("abort", 40)])[0], False)

    def test_a_long_run_is_good_whatever_ended_a_later_one(self):
        self.assertIs(sp.outcome([ran("ended", sp.GOOD_RUN_SECONDS)])[0], True)
        self.assertIs(sp.outcome([ran("ended", 1200), ran("crash", 30)])[0], True)

    def test_a_lock_wait_says_nothing(self):
        self.assertIsNone(sp.outcome([ran("hang", 200)])[0])

    def test_a_session_over_within_ninety_seconds_is_bad(self):
        self.assertIs(sp.outcome([ran("ended", 89)])[0], False)
        self.assertIsNone(sp.outcome([ran("ended", 90)])[0])


with open(os.path.join(HERE, "..", "compat", "capabilities.json")) as _f:
    CAPS = json.load(_f)


def game(**kw):
    app = {"name": "A Game", "type": "game", "oslist": ["windows"], "osextended": [], "deck": 0, "deck_tests": []}
    app.update(kw)
    return app


def judge(app, scan=None, anticheat=None, protondb=None, runs=(), peers=(0, 0, "")):
    return sp.judge(10, app, scan, CAPS, anticheat or {}, protondb or {}, list(runs), peers)


class Judge(unittest.TestCase):
    def test_a_game_with_a_mac_build_for_this_mac_is_native(self):
        verdict, _, reasons = judge(game(oslist=["windows", "macos"], osextended=["macosapplesilicon"]))
        self.assertEqual(verdict, "Native")

    def test_kernel_anti_cheat_blocks(self):
        self.assertEqual(judge(game(), anticheat={10: ["Vanguard"]})[0], "Blocked")
        self.assertEqual(judge(game(deck_tests=[(1, "UnsupportedAntiCheat_Other")]))[0], "Blocked")

    def test_a_player_who_says_it_works_is_believed_over_the_anti_cheat_list(self):
        runs = [{"by": "user", "verdict": "works"}]
        self.assertEqual(judge(game(), anticheat={10: ["Vanguard"]}, runs=runs)[0], "Works")

    def test_vr_blocks(self):
        self.assertEqual(judge(game(deck_tests=[(1, "SteamOSDoesNotSupport_VR")]))[0], "Blocked")

    def test_the_players_verdict_ends_the_judgement(self):
        scan = {"apis": ["opengl"], "dotnet": True}
        self.assertEqual(judge(game(), scan, runs=[{"by": "user", "verdict": "works"}])[0], "Works")
        self.assertEqual(judge(game(), runs=[{"by": "user", "verdict": "broken"}])[0], "Broken")

    def test_a_run_that_went_well_beats_a_low_score(self):
        self.assertEqual(judge(game(), {"apis": ["opengl"]}, runs=[ran("ended", 3000)])[0], "Works")

    def test_a_run_that_went_badly_beats_a_high_score(self):
        verdict, score, _ = judge(game(deck=3), {"apis": ["d3d11"]}, runs=[ran("crash", 20)])
        self.assertEqual((verdict, score), ("Unlikely", 3))

    def test_the_score_sets_likely_maybe_and_unlikely(self):
        self.assertEqual(judge(game(deck=3), {"apis": ["d3d11"]})[:2], ("Likely", 3))
        self.assertEqual(judge(game(), {"apis": ["d3d11"]})[:2], ("Maybe", 1))
        self.assertEqual(judge(game(), {"apis": ["d3d12"]})[:2], ("Unlikely", 0))
        self.assertEqual(judge(game(), {"apis": ["opengl"]})[0], "Unlikely")

    def test_what_a_game_needs_and_lacks_lowers_its_score(self):
        plain = judge(game(), {"apis": ["d3d11"]})[1]
        self.assertEqual(judge(game(), {"apis": ["d3d11"], "dotnet": True})[1],
                         plain + CAPS["features"]["dotnet"]["score"])
        self.assertEqual(judge(game(), {"apis": ["d3d11"], "anticheat": ["EasyAntiCheat"]})[1],
                         plain + CAPS["features"]["anticheat_files"]["score"])

    def test_protondb_counts_from_five_reports_on(self):
        plain = judge(game(), {"apis": ["d3d11"]})[1]
        self.assertEqual(judge(game(), {"apis": ["d3d11"]}, protondb={"10": [4, 4, 0, 0]})[1], plain)
        self.assertEqual(judge(game(), {"apis": ["d3d11"]}, protondb={"10": [10, 9, 0, 0]})[1], plain + 1)
        self.assertEqual(judge(game(), {"apis": ["d3d11"]}, protondb={"10": [10, 3, 0, 0]})[1], plain - 2)

    def test_games_built_alike_count_twice_at_most(self):
        plain = judge(game(), {"apis": ["d3d11"]})[1]
        self.assertEqual(judge(game(), {"apis": ["d3d11"]}, peers=(5, 0, "unity/d3d11"))[1], plain + 2)
        self.assertEqual(judge(game(), {"apis": ["d3d11"]}, peers=(1, 5, "unity/d3d11"))[1], plain - 1)

    def test_every_feature_the_judgement_names_is_in_the_table(self):
        for name in ("d3d9", "d3d10", "d3d11", "d3d12", "vulkan", "opengl", "dotnet", "unreal5", "x86_32",
                     "launcher", "embedded_browser", "anticheat_files", "anticheat_kernel", "vr", "heavy"):
            self.assertIn("note", CAPS["features"][name], name)


class GuardLimit(unittest.TestCase):
    def setUp(self):
        if os.path.exists(sp.GUARD_STOPS):
            os.remove(sp.GUARD_STOPS)
        quiet(self)

    def test_stops_three_times_then_leaves_steam_running(self):
        session = ["[2026-11-25 10:00:00] Startup - updater built"]
        self.assertEqual([sp.guard_may_stop(session) for _ in range(sp.GUARD_TRIES)], [True] * sp.GUARD_TRIES)
        self.assertIsNone(sp.guard_gave_up())
        self.assertFalse(sp.guard_may_stop(session))
        self.assertEqual(sp.guard_gave_up(), session[0])
        self.assertFalse(sp.guard_may_stop(session))      # and says so once: the session is remembered

    def test_stops_older_than_the_window_do_not_count(self):
        import time
        os.makedirs(sp.HOME_DIR, exist_ok=True)
        with open(sp.GUARD_STOPS, "w") as f:
            json.dump({"stops": [time.time() - sp.GUARD_WINDOW - 1] * 5}, f)
        self.assertTrue(sp.guard_may_stop(["[2026-11-25 11:00:00] Startup"]))


def parity(**row):
    full = {"feature": "A feature", "linux": "as Linux does it", "status": "works", "here": "a game", "takes": ""}
    full.update(row)
    return {"reviewed": "2026-11-25", "sections": [{"title": "A section", "rows": [full],
            "columns": ["Feature", "How Linux does it", "Here", "What bringing it in takes"]}]}


class Docs(unittest.TestCase):
    """The README and PARITY.md are written from compat/games.json and compat/parity.json. This
    is the test that fails when a document was edited by hand, or a data file was changed and
    "macos/steamplay docs" was not run."""

    def test_the_documents_are_what_the_data_files_say(self):
        texts, problems = sp.docs()
        self.assertEqual(problems, [])
        self.assertEqual(sorted(os.path.basename(p) for p in texts), ["PARITY.md", "README.md"])
        for path, (text, new) in texts.items():
            self.assertEqual(text, new, "%s differs from its data: run macos/steamplay docs" % path)

    def test_a_row_is_written_with_its_status_and_a_dash_for_nothing(self):
        lines = sp.parity_tables(parity()).split("\n")
        self.assertEqual(lines[0], "Last reviewed 2026-11-25.")
        self.assertEqual(lines[-1], "| A feature | as Linux does it | **works**: a game | — |")
        self.assertEqual(sp.parity_tables(parity(status="untested", here="")).split("\n")[-1],
                         "| A feature | as Linux does it | **untested** | — |")

    def test_what_is_wrong_in_the_data_is_said(self):
        self.assertEqual(sp.parity_problems(parity(), CAPS), [])
        for row in ({"status": "done"}, {"status": "works", "here": ""},
                    {"status": "works", "readme_missing": "the feature"},
                    {"status": "works", "capability": "opengl"}, {"capability": "no-such-feature"}):
            self.assertEqual(len(sp.parity_problems(parity(**row), CAPS)), 1, row)
        self.assertEqual(sp.parity_problems(parity(status="missing", capability="opengl", readme_missing="it"), CAPS), [])

    def test_the_missing_list_ends_with_a_full_stop(self):
        data = parity(status="missing", readme_missing="one thing")
        data["sections"][0]["rows"].append(dict(data["sections"][0]["rows"][0], readme_missing="another"))
        self.assertEqual(sp.missing_list(data), "- one thing;\n- another.")

    def test_a_document_without_its_marker_lines_is_left_alone(self):
        self.assertIsNone(sp.between("no markers here", sp.PARITY_START, sp.PARITY_END, "x"))
        self.assertEqual(sp.between("a\n<s>\nold\n<e>\nb", "<s>", "<e>", "new"), "a\n<s>\nnew\n<e>\nb")


class GuardJob(unittest.TestCase):
    """macOS names a background job by its program, and the guard's is /bin/sh: the job has to
    say that it is Protium's."""

    def app(self):
        contents = os.path.join(TEMP, "Protium.app", "Contents")
        os.makedirs(contents, exist_ok=True)
        import plistlib
        with open(os.path.join(contents, "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.example.protium"}, f)
        patch = mock.patch.object(sp, "app_contents", lambda: contents)
        patch.start()
        self.addCleanup(patch.stop)

    def test_from_the_app_the_job_names_the_app(self):
        self.app()
        job = sp.guard_job_plist()
        self.assertEqual(job["AssociatedBundleIdentifiers"], ["com.example.protium"])
        self.assertEqual(job["ProgramArguments"][0], "/bin/sh")

    def test_from_a_checkout_it_names_none(self):
        self.assertNotIn("AssociatedBundleIdentifiers", sp.guard_job_plist())

    def test_a_job_that_does_not_name_the_app_is_written_again(self):
        import plistlib
        old = dict(sp.guard_job_plist())
        patch = mock.patch.object(sp, "GUARD_PLIST", os.path.join(TEMP, "guard.plist"))
        patch.start()
        self.addCleanup(patch.stop)
        with open(sp.GUARD_PLIST, "wb") as f:
            plistlib.dump(old, f)
        self.assertFalse(sp.guard_job_is_old())
        self.app()
        self.assertTrue(sp.guard_job_is_old())
        with open(sp.GUARD_PLIST, "wb") as f:
            plistlib.dump(sp.guard_job_plist(), f)
        self.assertFalse(sp.guard_job_is_old())


class FrameTimes(unittest.TestCase):
    LINE = "info:  DXGI: frame times: %d frames in %d s, median 16.5 ms, 95%% 17.0 ms, 99%% 33.5 ms, worst 412.0 ms, %d over 50 ms\n"

    def test_the_last_line_of_the_log_is_the_runs(self):
        log = "0024:trace:loaddll x\n" + self.LINE % (1800, 30, 2) + "other\n" + self.LINE % (3600, 60, 7)
        self.assertEqual(sp.frame_times(log), {"count": 3600, "seconds": 60, "median": 16.5, "p95": 17.0,
                                               "p99": 33.5, "worst": 412.0, "slow": 7, "api": "dxgi"})

    def test_a_swap_chain_made_at_the_end_does_not_stand_for_the_run(self):
        # Red Dead Redemption 2's last DXGI line was a new swap chain's 137 frames in 2 s
        log = self.LINE % (215000, 3400, 70) + self.LINE % (137, 2, 0)
        self.assertEqual(sp.frame_times(log)["count"], 215000)

    def test_a_log_without_the_line_has_none(self):
        self.assertIsNone(sp.frame_times("0024:trace:loaddll x\n"))

    VULKAN = ("Vulkan: frame times (%s): %d frames in %d s, median 25.0 ms, 95%% 36.5 ms, 99%% 60.0 ms, "
              "worst 900.0 ms, %d over 50 ms\n")

    def test_a_vulkan_programs_frames_come_before_a_launchers_dxgi_ones(self):
        # Red Dead Redemption 2: its launcher draws with Direct3D 11 at up to 90 fps, the game with Vulkan
        log = (self.LINE % (2700, 30, 40) + self.VULKAN % ("RDR2.exe", 750, 30, 3) + "other\n"
               + self.LINE % (5400, 60, 80) + self.VULKAN % ("RDR2.exe", 1500, 60, 5))
        self.assertEqual(sp.frame_times(log), {"count": 1500, "seconds": 60, "median": 25.0, "p95": 36.5,
                                               "p99": 60.0, "worst": 900.0, "slow": 5,
                                               "api": "vulkan", "program": "RDR2.exe"})

    def test_of_two_vulkan_programs_the_one_that_drew_most_frames_is_the_game(self):
        log = (self.VULKAN % ("Game.exe", 1500, 60, 5) + self.VULKAN % ("Helper.exe", 40, 60, 0)
               + self.VULKAN % ("Helper.exe", 45, 70, 0))
        frames = sp.frame_times(log)
        self.assertEqual((frames["program"], frames["count"]), ("Game.exe", 1500))


class RecorderRows(unittest.TestCase):
    """The frame recorder's lines, in the three forms they have had."""
    OLD_DXGI = ("info:  DXGI: frame times: 54000 frames in 900 s, median 16.5 ms, 95% 17.0 ms, 99% 33.5 ms, "
                "worst 412.0 ms, 31 over 50 ms\n"
                "info:  DXGI: the last 30 s: 1650 frames, 3 over 50 ms: at 3.4 s (52 ms), 13.9 s (61 ms), 24.4 s (55 ms)\n"
                "info:  DXGI: a frame of the last 30 s: 4.6 command buffers, 0.00 waits for the GPU (0.00 ms), "
                "2.00 query flushes, 7.63 ms for an earlier frame, 0.05 ms for a drawable, commit 0.00 ms, encoding 7.85 ms\n")
    VULKAN = ("Vulkan: frame times (%s): 3370 frames in 60 s, median 16.5 ms, 95%% 31.0 ms, 99%% 34.0 ms, "
              "worst 801.7 ms, 15 over 50 ms\n"
              "Vulkan: the last 30 s (%s): 1804 frames, 0 over 50 ms\n"
              "Vulkan: a frame of the last 30 s (%s): 2.0 submits of 2.8 command buffers, 0.11 ms in the driver's "
              "submit, 1.0 acquires 0.13 ms, present 0.15 ms (the driver's 0.13 ms)\n")

    def test_an_old_dxgi_half_minute_is_one_row(self):
        row, = sp.recorder_rows("0024:trace:loaddll x\n" + self.OLD_DXGI)
        self.assertEqual((row["api"], row["program"], row["at"], row["log_line"]), ("dxgi", None, None, 2))
        self.assertEqual(row["run"]["count"], 54000)
        self.assertEqual(row["window"], {"frames": 1650, "slow": 3, "slow_at": [[3.4, 52], [13.9, 61], [24.4, 55]]})
        self.assertEqual(row["waits"]["query_flushes"], 2.0)
        self.assertEqual(row["waits"]["encoding_ms"], 7.85)

    def test_two_programs_lines_are_kept_apart_and_timed(self):
        named = self.VULKAN % (("RDR2.exe, 10:39:12",) * 3)
        launcher = self.OLD_DXGI.replace("DXGI: frame times:", "DXGI: frame times (Launcher.exe, 10:39:10):") \
            .replace("DXGI: the last 30 s:", "DXGI: the last 30 s (Launcher.exe, 10:39:10):") \
            .replace("DXGI: a frame of the last 30 s:", "DXGI: a frame of the last 30 s (Launcher.exe, 10:39:10):")
        # the two programs' lines can come between each other's
        lines = launcher.splitlines(True)
        log = lines[0] + named.splitlines(True)[0] + lines[1] + "".join(named.splitlines(True)[1:]) + lines[2]
        rows = sp.recorder_rows(log)
        self.assertEqual([(r["api"], r["program"], r["at"]) for r in rows],
                         [("dxgi", "Launcher.exe", "10:39:10"), ("vulkan", "RDR2.exe", "10:39:12")])
        self.assertEqual(rows[0]["waits"]["command_buffers"], 4.6)
        self.assertEqual(rows[1]["window"], {"frames": 1804, "slow": 0, "slow_at": []})
        self.assertEqual(rows[1]["calls"]["driver_present_ms"], 0.13)
        self.assertEqual(sp.frame_times(log, rows)["program"], "RDR2.exe")

    def test_the_lines_of_26_november_name_the_program_only(self):
        row, = sp.recorder_rows(self.VULKAN % (("RDR2.exe",) * 3))
        self.assertEqual((row["program"], row["at"], row["calls"]["submits"]), ("RDR2.exe", None, 2.0))

    def test_a_program_name_may_hold_brackets(self):
        row, = sp.recorder_rows(self.VULKAN % (("Game (x64).exe, 09:00:00",) * 3))
        self.assertEqual((row["program"], row["at"]), ("Game (x64).exe", "09:00:00"))

    def test_a_decimal_comma_is_read(self):
        log = self.OLD_DXGI.replace("16.5", "16,5").replace("3.4 s", "3,4 s")
        row, = sp.recorder_rows(log)
        self.assertEqual((row["run"]["median"], row["window"]["slow_at"][0]), (16.5, [3.4, 52]))

    def test_a_half_minute_without_its_frame_times_line_does_not_join_the_row_before(self):
        # a swap chain goes (its closing line), and a new one has counted no frame when its first
        # half minute is said: DXMT then writes the window line alone
        log = ("info:  DXGI: frame times (G.exe, 10:00:05): 1220 frames in 17 s, median 13.5 ms, 95% 21.5 ms, "
               "99% 33.0 ms, worst 52.0 ms, 1 over 50 ms\n"
               "info:  DXGI: the last 30 s (G.exe, 10:00:40): 0 frames, 0 over 50 ms\n")
        rows = sp.recorder_rows(log)
        self.assertEqual([sorted(r) for r in rows], [["api", "at", "log_line", "program", "run"],
                                                     ["api", "at", "log_line", "program", "window"]])

    def test_a_closing_line_is_a_row_of_its_own(self):
        log = self.OLD_DXGI + self.OLD_DXGI.splitlines(True)[0].replace("54000", "54100")
        rows = sp.recorder_rows(log)
        self.assertEqual([sorted(r) for r in rows][1], ["api", "at", "log_line", "program", "run"])

    def test_record_keeps_the_rows_with_the_run(self):
        log = os.path.join(TEMP, "record-rows.log")
        with open(log, "w") as f:
            f.write("0024:trace:loaddll x\n" + self.OLD_DXGI + self.VULKAN % (("Game.exe, 10:00:30",) * 3))
        folder = os.path.join(sp.HOME_DIR, "runs", "424242")
        os.makedirs(folder, exist_ok=True)
        for i in range(sp.RUNS_KEPT):                    # a game that already has a full folder
            open(os.path.join(folder, "20260101-%06d.jsonl" % i), "w").close()
        start = 1795665000
        with mock.patch.dict(os.environ, {"PROTIUM_VERSION": "0.0.0-test"}):
            sp.cmd_record(424242, start, log)
        with open(sp.RESULTS) as f:
            entry = json.loads(f.read().splitlines()[-1])
        name = time.strftime("%Y%m%d-%H%M%S", time.localtime(start)) + ".jsonl"
        self.assertEqual(entry["rows"], os.path.join("runs", "424242", name))
        self.assertEqual((entry["frames"]["api"], entry["frames"]["program"]), ("vulkan", "Game.exe"))
        with open(os.path.join(sp.HOME_DIR, entry["rows"])) as f:
            kept = [json.loads(line) for line in f]
        self.assertEqual([r["api"] for r in kept], ["dxgi", "vulkan"])
        names = sorted(os.listdir(folder))
        self.assertEqual(len(names), sp.RUNS_KEPT)
        self.assertNotIn("20260101-000000.jsonl", names)
        self.assertIn(name, names)

    def test_a_run_reads_its_own_log_after_a_later_start_moved_it_aside(self):
        # the Rockstar launcher was still closing when the game was started again: that start moved
        # this run's log to .prev.log, and the name held the new run's, which had no frames yet
        folder = tempfile.mkdtemp(dir=TEMP)
        log = os.path.join(folder, "steamplay-run.log")
        with open(log, "w") as f:
            f.write(self.OLD_DXGI)
        inode = os.stat(log).st_ino
        os.rename(log, os.path.join(folder, "steamplay-run.prev.log"))
        with open(log, "w") as f:
            f.write("fsync: up and running.\n")
        self.assertEqual(sp.own_log(log, str(inode)), os.path.join(folder, "steamplay-run.prev.log"))
        self.assertEqual(sp.own_log(log, None), log)
        with mock.patch.dict(os.environ, {"PROTIUM_VERSION": "0.0.0-test", "STEAMPLAY_LOG_INODE": str(inode)}):
            sp.cmd_record(434343, 1795665000, log)
        with open(sp.RESULTS) as f:
            entry = json.loads(f.read().splitlines()[-1])
        self.assertEqual(entry["frames"]["count"], 54000)
        os.remove(os.path.join(folder, "steamplay-run.prev.log"))      # gone: no frames, not the new run's
        self.assertIsNone(sp.own_log(log, str(inode)))

    def test_a_run_records_what_it_started_with(self):
        env = {"STEAMPLAY_GAME_ENV": "# 2026-11-24: a note\nFEX_HARDWARE_TSO_OFF=none\n\n  FEX_SMCCHECKS=none  \n",
               "MTL_HUD_ENABLED": "1", "WINEDEBUG": "+loaddll,+msgbox", "WINE_MAC_RETINA": "auto"}
        self.assertEqual(sp.run_settings(env), {"env": ["FEX_HARDWARE_TSO_OFF=none", "FEX_SMCCHECKS=none"],
                                                "hud": True, "winedebug": "+loaddll,+msgbox", "retina": "auto"})
        self.assertEqual(sp.run_settings({}), {"env": [], "hud": False, "winedebug": "", "retina": ""})


class ProcessLines(unittest.TestCase):
    """Wine's process line and winecoreaudio's audio line, as check-wave5 items 22 and 23 saw them."""
    GAME = ("Process: the last 5 s (process_stats_test_x86_64.exe, pid 50348, 16:15:15): cpu 15.81 s, P cores 72%, "
            "waiting for a core 19.39 s, ipc 5.65, threads 27, switches 15218, faults 1722, syscalls 3896, mach calls 844; "
            "memory: 15 MB, compressed 0 MB, graphics 0 MB, page-ins 0, read 0 MB, pressure 1, thermal 0; wineserver: "
            "calls 148 0.269 s (select 24 0.122 s, init_thread 24 0.062 s, new_thread 24 0.046 s), waits 0 0.00 s, its cpu "
            "0.01 s; waits: fsync 100 2.09 s, by address 70 1.12 s, sleeps 25 0.50 s, yields 0 0.000 s; FEX: threads 25, jit "
            "0.00 s, lock 0.00 s, blocks 14, smc 0, l1 misses 54, disk-cache misses 14; recorder 25 us\n")
    HELPER = ("Process: the last 5 s (services.exe, pid 50289, 16:15:15): cpu 0.03 s, P cores 100%, waiting for a core 0.00 s, "
              "ipc 1.87, threads 11, switches 3377, faults 4164, syscalls 18455, mach calls 583; memory: 4 MB, compressed 0 MB, "
              "graphics 0 MB, page-ins 1, read 0 MB, pressure 2, thermal 1; wineserver: calls 3098 0.031 s (get_key_value 894 "
              "0.007 s, select 441 0.004 s, create_file 93 0.004 s), waits 0 0.00 s, its cpu 0.20 s; waits: fsync 100 0.62 s, "
              "by address 72 0.24 s, sleeps 0 0.00 s, yields 0 0.000 s; recorder 62 us\n")
    AUDIO = ("Audio: the last 5 s (audio_underrun_test.exe, pid 51349, 16:18:35): callbacks 469, short 1, empty 76, "
             "silence 813 ms, lock busy 0\n")

    def test_a_process_line_is_read_whole(self):
        game, helper = sp.process_rows("x\n" + self.GAME + self.HELPER)
        self.assertEqual((game["program"], game["pid"], game["at"], game["seconds"], game["log_line"]),
                         ("process_stats_test_x86_64.exe", 50348, "16:15:15", 5, 2))
        self.assertEqual((game["cpu"], game["p_cores"], game["waiting"], game["threads"], game["memory_mb"]), (15.81, 72, 19.39, 27, 15))
        self.assertEqual(game["server_top"][0], ["select", 24, 0.122])
        self.assertEqual((game["server_calls"], game["server_cpu"]), (148, 0.01))
        self.assertEqual(game["waits"], {"fsync": [100, 2.09], "address": [70, 1.12], "sleeps": [25, 0.5], "yields": [0, 0.0]})
        self.assertEqual((game["fex"]["blocks"], game["recorder_us"]), (14, 25))
        self.assertNotIn("fex", helper)
        self.assertEqual((helper["pressure"], helper["thermal"]), (2, 1))

    def test_an_exit_line_is_marked(self):
        row, = sp.process_rows(self.GAME.replace("16:15:15)", "16:15:15, exit)"))
        self.assertTrue(row["exit"])

    def test_the_summary_is_of_the_game_and_its_helpers(self):
        rows = sp.process_rows(self.GAME + self.HELPER)
        s = sp.process_summary(rows, "process_stats_test_x86_64.exe")
        self.assertEqual((s["program"], s["lines"], s["cores"], s["waiting_per_s"], s["p_cores"]),
                         ("process_stats_test_x86_64.exe", 1, 3.162, 3.878, 72))
        self.assertEqual((s["helpers_cores_most"], s["server_cores_most"], s["pressure_most"], s["thermal_most"], s["fex_jit_s"]),
                         (0.006, 0.04, 2, 1, 0.0))
        # without the frames' program, the one that used the most processor time
        self.assertEqual(sp.process_summary(rows)["program"], "process_stats_test_x86_64.exe")
        self.assertIsNone(sp.process_summary([]))

    def test_audio_lines_add_up(self):
        rows = sp.process_rows(self.AUDIO + self.AUDIO.replace("16:18:35", "16:19:05"))
        self.assertEqual(sp.audio_summary(rows), {"lines": 2, "short": 2, "empty": 152, "silence_ms": 1626, "lock_busy": 0})
        self.assertIsNone(sp.audio_summary(sp.process_rows(self.GAME)))

    def test_macos_overloads_are_counted_by_cause_and_half_minute(self):
        events = [{"timestamp": "2026-11-26 09:25:06.%06d+1000" % i, "eventMessage":
                   "        HALS_OverloadMessage.cpp:213   HALS_OverloadMessage: Overload possibly due to client timeout."}
                  for i in range(3)]
        events.append({"timestamp": "2026-11-26 09:25:31.000000+1000", "eventMessage":
                       "HALS_OverloadMessage: Overload possibly due to io cycle budget."})
        events.append({"timestamp": "2026-11-26 09:25:32.000000+1000", "eventMessage": "Audio IO Overload thread: 4a84cb"})
        text = "\n".join(json.dumps(e) for e in events) + "\nnot json\n"
        self.assertEqual(sp.count_overloads(text), {"total": 4, "causes": {"client timeout": 3, "io cycle budget": 1},
                                                    "half_minutes": [["09:25:00", 3], ["09:25:30", 1]]})

    def test_record_keeps_them_with_the_frames(self):
        log = os.path.join(TEMP, "record-process.log")
        with open(log, "w") as f:
            f.write(RecorderRows.OLD_DXGI + self.GAME + self.HELPER + self.AUDIO)
        with mock.patch.dict(os.environ, {"PROTIUM_VERSION": "0.0.0-test"}):
            sp.cmd_record(454545, 1795665000, log)
        with open(sp.RESULTS) as f:
            entry = json.loads(f.read().splitlines()[-1])
        self.assertEqual(entry["process"]["program"], "process_stats_test_x86_64.exe")
        self.assertEqual(entry["audio"]["silence_ms"], 813)
        with open(os.path.join(sp.HOME_DIR, entry["rows"])) as f:
            kept = [json.loads(line) for line in f]
        self.assertEqual([r.get("source", r.get("api")) for r in kept], ["dxgi", "process", "process", "audio"])


class RunScriptLog(unittest.TestCase):
    """steamplay-run.sh, as Steam starts it (its output going nowhere): what it says before the
    game starts, and why it stopped, goes into the game's log. Run with a fake Wine, a fake Steam
    folder and a pgrep that finds Steam, so that nothing of Steam's or Wine's runs."""
    SCRIPT = os.path.join(HERE, "..", "steamplay-run.sh")

    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=TEMP)
        d = self.dir
        for sub in ("wine/bin", "nowine", "bin", "steam/Steam.AppBundle/Steam/Contents/MacOS", "steam/steamapps",
                    "lib/steamapps/common/Game", "home", "dlls"):
            os.makedirs(os.path.join(d, sub))
        for path, text in (("wine/bin/wine", "#!/bin/sh\nexit 0\n"), ("bin/pgrep", "#!/bin/sh\nexit 0\n")):
            with open(os.path.join(d, path), "w") as f:
                f.write(text)
            os.chmod(os.path.join(d, path), 0o755)
        open(os.path.join(d, "steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"), "w").close()
        open(os.path.join(d, "lib/steamapps/common/Game/game.exe"), "w").close()
        with open(os.path.join(d, "steam/steamapps/libraryfolders.vdf"), "w") as f:
            f.write('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' % os.path.join(d, "lib"))
        with open(os.path.join(d, "lib/steamapps/appmanifest_123.acf"), "w") as f:
            f.write('"AppState"\n{\n\t"appid"\t\t"123"\n\t"installdir"\t\t"Game"\n}\n')
        self.compat = os.path.join(d, "lib/steamapps/compatdata/123")
        self.log = os.path.join(self.compat, "steamplay-run.log")

    def start(self, wine="wine"):
        import subprocess
        env = dict(os.environ, STEAM_COMPAT_DATA_PATH=self.compat, WINE_INSTALL=os.path.join(self.dir, wine),
                   STEAM_ROOT=os.path.join(self.dir, "steam"), STEAMPLAY_HOME=os.path.join(self.dir, "home"),
                   WIN_STEAM_DLLS=os.path.join(self.dir, "dlls"), PATH=os.path.join(self.dir, "bin") + ":/usr/bin:/bin:/usr/sbin")
        r = subprocess.run(["/bin/bash", self.SCRIPT, "123"], env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(self.log) as f:
            return r.returncode, f.read()

    def test_an_error_before_the_game_goes_into_its_log(self):
        status, log = self.start(wine="nowine")
        self.assertEqual(status, 1)
        self.assertRegex(log.splitlines()[0], r"^:: \d{4}-\d\d-\d\d \d\d:\d\d:\d\d: Protium .*, app 123, on .*, macOS ")
        self.assertIn("steamplay-run.sh: error: no Wine in", log)

    def test_the_run_before_keeps_its_log(self):
        os.makedirs(self.compat)
        with open(self.log, "w") as f:
            f.write("the run before\n")
        self.start(wine="nowine")
        with open(os.path.join(self.compat, "steamplay-run.prev.log")) as f:
            self.assertEqual(f.read(), "the run before\n")

    def test_a_step_that_fails_says_which(self):
        os.makedirs(self.compat)
        open(os.path.join(self.compat, "pfx"), "w").close()     # mkdir -p of the prefix fails
        status, log = self.start()
        self.assertEqual(status, 1)
        self.assertRegex(log, r'the game was not started: a step failed \(status 1, line \d+: mkdir -p "\$prefix"\)')


class RecordAfter(unittest.TestCase):
    """"record --after": a run is recorded once its process has ended, also when its whole process
    group was killed, as Steam does when it quits."""

    def test_a_run_whose_group_was_killed_is_recorded(self):
        import signal
        import subprocess
        import time
        home = tempfile.mkdtemp(dir=TEMP)
        log = os.path.join(home, "steamplay-run.log")
        with open(log, "w") as f:
            f.write("fsync: up and running.\n")
        # as steamplay-run.sh does it: the waiter in the background, then the shell becomes the game
        script = '"$0" "$1" record --after $$ 454546 %d "%s" </dev/null >/dev/null 2>&1 & exec /bin/sleep 30' % (int(time.time()), log)
        env = dict(os.environ, STEAMPLAY_HOME=home, STEAMPLAY_NO_SYSTEM_LOG="1", PROTIUM_VERSION="0.0.0-test")
        game = subprocess.Popen(["/bin/bash", "-c", script, sys.executable, os.path.join(HERE, "..", "steamplay")],
                                env=env, start_new_session=True)
        time.sleep(1.0)
        os.killpg(game.pid, signal.SIGKILL)
        game.wait()
        results = os.path.join(home, "results.jsonl")
        for _ in range(100):
            if os.path.exists(results) and os.path.getsize(results):
                break
            time.sleep(0.1)
        with open(results) as f:
            entry = json.loads(f.read().splitlines()[-1])
        self.assertEqual((entry["app"], entry["by"], entry["end"]), (454546, "run", "ended"))

    def test_the_wait_ends_when_the_process_does(self):
        import subprocess
        import time
        p = subprocess.Popen(["/bin/sleep", "0.3"])
        t0 = time.time()
        sp.wait_for_exit(p.pid)
        self.assertGreater(time.time() - t0, 0.2)
        p.wait()
        t0 = time.time()
        sp.wait_for_exit(p.pid)     # gone already
        self.assertLess(time.time() - t0, 0.1)


import datetime
import time

TODAY = datetime.date(2026, 11, 25)


def listed(app, graphics, verdict="works", tested="2026-11-20"):
    return {"app": app, "name": "Game %d" % app, "graphics": graphics, "verdict": verdict, "tested": tested}


def shown(status, *tags):
    return parity(status=status, shown_by=list(tags))


class Evidence(unittest.TestCase):
    def test_day_reads_the_forms_the_files_have(self):
        self.assertEqual(sp.day("2026-11-24T19:49:44"), datetime.date(2026, 11, 24))
        self.assertEqual(sp.day("2026-11"), datetime.date(2026, 11, 1))
        self.assertIsNone(sp.day("soon"))
        self.assertIsNone(sp.day("2026-13-40"))

    def test_a_listed_game_gets_its_tags_from_its_graphics(self):
        fact, = sp.game_facts([listed(1, "Direct3D 9, 32-bit")], {})
        self.assertEqual(fact["tags"], {"run", "d3d9", "x86_32"})
        self.assertEqual((fact["good"], fact["date"], fact["name"]), (True, datetime.date(2026, 11, 20), "Game 1"))

    def test_a_game_that_is_not_listed_has_no_name_and_one_api_or_none(self):
        one = {"by": "run", "end": "ended", "seconds": 900, "loaded": ["d3d11", "opengl"], "time": "2026-11-24T10:00:00", "protium": "0.4.0"}
        many = dict(one, loaded=["d3d9", "d3d11", "d3d12", "vulkan"])
        facts = {f["app"]: f for f in sp.game_facts([], {5: [one], 6: [many]})}
        self.assertIsNone(facts[5]["name"])
        self.assertEqual(facts[5]["tags"], {"run", "d3d11"})
        self.assertEqual(facts[6]["tags"], {"run"})      # a launcher loads everything: that shows nothing
        self.assertEqual((facts[5]["date"], facts[5]["version"]), (datetime.date(2026, 11, 24), "0.4.0"))

    def test_what_this_mac_recorded_counts_before_the_list(self):
        crash = {"by": "run", "end": "crash", "seconds": 20, "loaded": ["d3d11"], "time": "2026-11-24T10:00:00"}
        fact, = sp.game_facts([listed(1, "Direct3D 11")], {1: [crash]})
        self.assertIs(fact["good"], False)

    def test_a_row_that_says_works_needs_a_game_that_ran_well_lately(self):
        facts = sp.game_facts([listed(1, "Direct3D 11")], {})
        (row, runs, problem, proposal), = sp.evidence(shown("works", "d3d11"), facts, TODAY)
        self.assertEqual((runs, problem, proposal), ("1 game ran well, the newest on 2026-11-20: Game 1", "", ""))
        late = TODAY + datetime.timedelta(days=sp.EVIDENCE_DAYS)
        (_, runs, problem, _), = sp.evidence(shown("works", "d3d11"), facts, late)
        self.assertEqual(runs, "")
        self.assertIn("the newest on 2026-11-20", problem)
        (_, _, problem, _), = sp.evidence(shown("works", "vulkan"), facts, TODAY)
        self.assertIn("none on record", problem)

    def test_a_game_that_does_not_run_shows_nothing(self):
        facts = sp.game_facts([listed(1, "Direct3D 11", verdict="broken")], {})
        (_, runs, problem, _), = sp.evidence(shown("works", "d3d11"), facts, TODAY)
        self.assertEqual(runs, "")
        self.assertTrue(problem)

    def test_two_games_propose_works_and_change_nothing(self):
        facts = sp.game_facts([listed(1, "Vulkan"), listed(2, "Vulkan", verdict="plays-with-problems")], {})
        data = shown("partial", "vulkan")
        (row, runs, problem, proposal), = sp.evidence(data, facts, TODAY)
        self.assertIn("it says partial, and 2 games ran well", proposal)
        self.assertEqual((problem, row["status"]), ("", "partial"))
        (_, _, _, proposal), = sp.evidence(shown("partial", "vulkan"), facts[:1], TODAY)
        self.assertEqual(proposal, "")

    def test_games_that_are_not_listed_are_counted_and_not_named(self):
        run = {"by": "run", "end": "ended", "seconds": 900, "loaded": ["d3d11"], "time": "2026-11-24T10:00:00"}
        facts = sp.game_facts([listed(1, "Direct3D 11")], {7: [run], 8: [run]})
        (_, runs, _, _), = sp.evidence(shown("works", "d3d11"), facts, TODAY)
        self.assertEqual(runs, "3 games ran well, the newest on 2026-11-24: Game 1 and 2 more")

    def test_rows_without_shown_by_are_left_out_and_runs_are_written_into_the_table(self):
        self.assertEqual(sp.evidence(parity(), [], TODAY), [])
        self.assertEqual(sp.parity_tables(parity(runs="1 game ran well")).split("\n")[-1],
                         "| A feature | as Linux does it | **works**: a game Runs: 1 game ran well. | — |")


if __name__ == "__main__":
    unittest.main()
