# Changelog

All notable changes to Protium are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Protium
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). It is written for players:
what they will notice. `macos/make-release.sh` puts a release's section into the app and
`macos/publish-release.sh` onto its page on GitHub, so this file is where release notes are
written. "Known problems" is a heading of our own, next to Keep a Changelog's.

## [Unreleased]

### Added

- Protium updates itself: when a newer version is out, its window shows what that version
  changes and an Update button. The download is only installed if it is signed by Protium's
  developer and notarized by Apple, and the old version comes back if the new one does not
  start. After an update the window says what is new.
- One notification when you start a game and a newer version is out, once per version. macOS
  asks for permission to notify at the end of "Set up Steam".
- Protium asks GitHub for new versions once a day at most. The checkbox "Tell me about new
  versions" in its window, or `steamplay updates off`, turns the asking off.

### Fixed

- Protium's own Python no longer writes files into the app. In 0.1.0 and 0.2.0 it did so the
  first time some of its modules were used, which left the app's signature no longer matching
  its contents.

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

[Unreleased]: https://github.com/0xLeathery/protium/compare/v0.2.0...macos-port
[0.2.0]: https://github.com/0xLeathery/protium/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/0xLeathery/protium/releases/tag/v0.1.0
