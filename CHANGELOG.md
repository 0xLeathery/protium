# Changelog

All notable changes to Protium are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Protium
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). It is written for players:
what they will notice. `macos/make-release.sh` puts a release's section into the app and
`macos/publish-release.sh` onto its page on GitHub, so this file is where release notes are
written. "Known problems" is a heading of our own, next to Keep a Changelog's.

## [Unreleased]

### Changed

- A Vulkan game's log now says every half minute how long its frames took, as a Direct3D 10
  or 11 game's already did. The record of a run keeps the game's own frame times, not those
  of a launcher drawing beside it, as Red Dead Redemption 2's does. These lines now also say
  which program they are about and the time of day.
- A game's folder now keeps the logs of its last five runs, not only of the one before
  (`steamplay-run.prev.log` is still the newest of them).
- A game's log now also says every half minute what each of its processes did: how much
  processor time it used and how long it waited for a free core, its memory, its calls to Wine's
  server and its waits, and, when the game's sound ran dry, for how long. This is what tells
  why a game stuttered.

### Fixed

- Vulkan games are no longer told that a screen can show HDR when macOS says it can't. On
  such a screen Red Dead Redemption 2 switched its HDR picture on, which macOS has to squeeze
  into normal range.
- Red Dead Redemption 2's log no longer fills with one line about keyboard layouts, written
  110 times a second, which made up nearly all of it.

## [0.4.2] - 2026-11-25

A test version for game controllers. Protium does not offer it as an update: download it from
its page if you want to try a controller.

### Changed

- Game controllers now come through SDL, as they do with Proton on Linux. A PlayStation or
  Switch controller should now work in games that expect an Xbox controller, and rumble
  should work. Until now only an Xbox controller was known to work.

### Known problems

- The new controller support has not been tried with a controller yet. Please report how yours
  does: which controller, USB or Bluetooth, which game, and whether the buttons and rumble are
  right.
- If a controller worked before and does not now, add the line `PROTON_NO_SDL=1` to the game's
  settings file, `~/Library/Application Support/SteamPlay/env.<app id>`, to go back to how
  it was, and tell us.

## [0.4.1] - 2026-11-25

### Fixed

- macOS said that "sh" wanted to run in the background after you set up Steam, and listed it
  under that name in Login Items. It is Protium's helper, which keeps Steam set up for Windows
  games and stops Steam from deleting them if that setup is lost. It is now listed as Protium's.
- Protium could change a Steam setting that had a line break or a tab in it when it wrote Steam's
  settings file. Such settings now stay as Steam wrote them.
- Building Protium from source failed because its Wine source could not be downloaded. That
  source is now public.

### Changed

- The log of a Direct3D 10 or 11 game (`steamplay-run.log` in the game's `compatdata` folder)
  now says every half minute how long its frames took and how many were slow. Attach it when
  you report stutter.
- A game's video memory can be limited with `DXMT_VIDEO_MEMORY_BUDGET_MB` in its settings file
  (`~/Library/Application Support/SteamPlay/env.<app id>`). This did nothing for most older
  games before. It can help a game that slows down after you switch to another app on a Mac
  that is short of memory.

## [0.4.0] - 2026-11-25

### Added

- Games can use the full resolution of a Retina or 4K screen. Until now a game on such a screen
  was offered a quarter of its pixels (1920 × 1080 at most on a 4K monitor) and the picture was
  enlarged. Protium now does this by itself when your main screen is a high-density one, and
  changes nothing on other screens. "Use the screen's full resolution in games" in Protium's
  window, or `steamplay hires off`, turns it off.
- "Show frame rate in games" in Protium's window draws macOS's performance display over every
  game (`steamplay hud on` did this before, from the command line only).

### Changed

- On a Retina or 4K screen a game that picks the screen's own resolution now draws four times
  as many pixels as before and can run slower. Choose a lower resolution in the game's settings,
  or turn full resolution off in Protium.

### Fixed

- A full-screen game at a resolution of another shape than the screen could have its black bars
  in the wrong place, and the bars stayed after the game left full screen.

### Known problems

- With full resolution on, launchers and games in a window are half as large on screen as
  before.
- With screens of different kinds connected, Protium follows the main one.
- With full resolution on, a game that draws its own mouse pointer may show it smaller than
  before.
- This has been tried on one monitor's high-density mode, with test programs. It has not yet
  been tried on a MacBook's own screen, or with a full game.

## [0.3.1] - 2026-11-24

### Added

- A Diagnostics button. It saves one text file to your Desktop that shows how Protium and Steam
  are set up on your Mac and what their logs last said, so you can attach it when you report a
  problem. Nothing is sent anywhere. The file includes the names of your installed games; your
  home folder and Steam account numbers are left out.

### Changed

- The messages in Protium's window are clearer about what happened and what to do next.

### Fixed

- "Set up Steam" on a Steam that had never been opened or signed in to ended in a Python error.
  Protium now tells you to open Steam and sign in first.
- If Steam kept starting without Protium's tools, Protium's background helper restarted it again
  and again, and Steam could not be used. It now stops after three tries and tells you to press
  Repair.
- Deleting Protium.app without pressing Uninstall left Steam changed. Protium now removes itself
  from Steam about ten minutes after the app is deleted.

## [0.3.0] - 2026-11-24

### Added

- Protium updates itself: when a newer version is out, its window shows what that version
  changes and an Update button. The download is only installed if it is signed by Protium's
  developer and notarized by Apple, and the old version comes back if the new one does not
  start. After an update the window says what is new.
- When you start a game and a newer version is out, a small banner at the top of the screen says
  so for a few seconds, once per version. It never takes the keyboard or the mouse from the game.
  If you allow Protium to send notifications ("Allow notifications…" in its window), it is in
  Notification Centre too.
- Protium asks GitHub for new versions once a day at most. The checkbox "Tell me about new
  versions" in its window, or `steamplay updates off`, turns the asking off.

### Fixed

- Protium's own Python no longer writes files into the app. In 0.1.0 and 0.2.0 it did so the
  first time some of its modules were used, which left the app's signature no longer matching
  its contents.

### Known problems

- 0.1.0 and 0.2.0 cannot update themselves: download this version from its page and drag it
  over the older one. From this version on, Protium updates from its own window.
- The first load of a level can take several minutes while shaders are compiled, and a game can
  hitch the first time it draws something new. Later loads are faster.

## [0.2.0] - 2026-11-24

### Added

- Protium's window says when a newer version is out, with a button to its page, and shows its
  own version in the title. For this it asks GitHub for the newest release when it opens; the
  request says nothing about your Mac or your games.
- `steamplay result` keeps the list of games people have tried, and the README's table is written
  from it. Call of Duty: World at War and Modern Warfare Remastered are on it.

### Changed

- While a game hides the pointer, the mouse moves it a pixel per count, without macOS's
  acceleration, so you may want to set the game's sensitivity again.

### Fixed

- Mouse look is even in games that turn the camera by moving the pointer back to the middle of
  the window every frame, such as Call of Duty: World at War and Modern Warfare Remastered. The
  camera used to turn on every second frame, most visibly at a low mouse DPI.

### Known problems

- The first load of a level can take several minutes while shaders are compiled, and a game can
  hitch the first time it draws something new. Later loads are faster.

## [0.1.0] - 2026-11-24

The first release: Steam Play for Apple Silicon Macs, with Windows games from your Steam library
run natively on arm64 with Metal, without Rosetta and without a virtual machine.

### Added

- Protium.app sets up Steam Play in Mac Steam, repairs it, shows its status and takes it out
  again.
- Direct3D 9, 10 and 11 on Metal, Direct3D 12 and Vulkan on KosmicKrisp, 32-bit and 64-bit games.
- Steam sign-in, ownership, stats, achievements and Steam Cloud work through the running Mac
  Steam.
- `steamplay discover` ranks the games in your library by how likely they are to work, and says
  why.

[Unreleased]: https://github.com/0xLeathery/protium/compare/v0.4.2...macos-port
[0.4.2]: https://github.com/0xLeathery/protium/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/0xLeathery/protium/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/0xLeathery/protium/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/0xLeathery/protium/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/0xLeathery/protium/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/0xLeathery/protium/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/0xLeathery/protium/releases/tag/v0.1.0
