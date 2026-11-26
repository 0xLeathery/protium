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
                   "STEAMPLAY_TOOLS_DIR": os.path.join(TEMP, "tools"), "STEAMPLAY_FAKE_STEAM": "1"})
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
