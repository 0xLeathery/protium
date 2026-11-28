---
name: Game report
about: How a Windows game runs on Protium, or where it stops.

---

**Please update Protium first.** Open Protium: if it shows an **Update** button, press it (an
older version without one: download the newest from the
[releases page](https://github.com/0xLeathery/protium/releases/latest)), then try the game again.
A report about an older version is often about something fixed since.

- Game and Steam app id:
- How far it gets (does not start, crashes at ..., menu, plays with problems, plays well):
- What goes wrong:
- Launch options, if you set any (the game's Properties in Steam, General):
- Graphics API, if you know it (Direct3D 9, 11, 12, Vulkan, OpenGL):

## Mac
- Model and chip (Apple menu, About This Mac), e.g. MacBook Air, M5:
- macOS version:
- Protium version (in the title of Protium's window):

## Files

Please attach two files, by dragging them into this box:

1. **Diagnostics.** Start the game once more so that it goes wrong, quit it, then open Protium
   and press **Diagnostics**. It saves a text file on your Desktop that says how Steam ran the
   game and how its last runs ended. It names your installed games, so read it first.
2. **The game's log**, `steamplay-run.log`. It is in the folder
   `~/Library/Application Support/Steam/steamapps/compatdata/<app id>/` (in Finder, choose
   Go > Go to Folder and paste that path, with the game's app id), or in
   `steamapps/compatdata/<app id>/` of the Steam library the game is in, if that library is on
   another disk. `steamplay-run.prev.log` there is the run before. If there is no such file,
   say so: that tells us something too.
