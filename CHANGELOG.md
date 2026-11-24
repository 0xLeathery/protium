# Protium changelog

What changed for players in each release, newest first. `macos/make-release.sh` puts a release's
section into the app and `macos/publish-release.sh` into its page on GitHub, so this file is
where release notes are written.

## 0.2.0 - 2026-11-24

- Mouse look is even in games that turn the camera by moving the pointer back to the middle of
  the window every frame, such as Call of Duty: World at War and Modern Warfare Remastered. The
  camera used to turn on every second frame, most visibly at a low mouse DPI. While a game hides
  the pointer, the mouse now moves it a pixel per count, without macOS's acceleration, so you may
  want to set the game's sensitivity again.
- Protium's window says when a newer version is out, with a button to its page, and shows its
  own version in the title. For this it asks GitHub for the newest release when it opens; the
  request says nothing about your Mac or your games.
- `steamplay result` keeps the list of games people have tried, and the README's table is written
  from it. Call of Duty: World at War and Modern Warfare Remastered are on it.

Known problems: the first load of a level can take several minutes while shaders are compiled,
and a game can hitch the first time it draws something new. Later loads are faster.

## 0.1.0 - 2026-11-24

The first release: Steam Play for Apple Silicon Macs, with Windows games from your Steam library
run natively on arm64 with Metal, without Rosetta and without a virtual machine.

- Protium.app sets up Steam Play in Mac Steam, repairs it, shows its status and takes it out
  again.
- Direct3D 9, 10 and 11 on Metal, Direct3D 12 and Vulkan on KosmicKrisp, 32-bit and 64-bit games.
- Steam sign-in, ownership, stats, achievements and Steam Cloud work through the running Mac
  Steam.
- `steamplay discover` ranks the games in your library by how likely they are to work, and says
  why.
