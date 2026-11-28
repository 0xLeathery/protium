# Privacy

Protium sends nothing about you, your Mac or your games anywhere. It has no analytics, no crash
reporting service and no account. This page lists everything it does on the network, everything
it keeps on your Mac, and exactly what the **Diagnostics** button puts in its file.

## What Protium sends over the network

- **The update check.** Once a day at most, Protium asks GitHub for the list of Protium releases
  (`api.github.com/repos/0xLeathery/protium/releases`). The request says nothing about your Mac
  or your games. "Tell me about new versions" in Protium's window, or `steamplay updates off`,
  turns it off, and then no request is ever made.
- **An update**, when you press Update: the new version's disk image, downloaded from GitHub.
- **Valve's Windows Steam client files**, when you press Set up Steam: `steamclient.dll` and its
  companions, downloaded from Valve's own servers (`client-update.steamstatic.com`), as Steam
  downloads them itself. Windows games need them, and Mac Steam does not include them.
- **Two public game lists**, only when you run `steamplay data update` yourself (for
  `steamplay discover`): the anti-cheat list from AreWeAntiCheatYet and ProtonDB's monthly export.

That is all. Steam and your games go on the network as they always do; Protium does not see or
change what they send.

## What Protium keeps on your Mac

Nothing of this leaves your Mac unless you attach it to a report yourself.

- **Each game's log**, `steamplay-run.log`, in the game's `steamapps/compatdata/<app id>/` folder,
  with the logs of its last five runs before (`steamplay-run.prev.log` to `.prev5.log`). It holds
  what Protium did to start the game and what Wine and the game printed while it ran.
- **A record of each run** in `~/Library/Application Support/SteamPlay/results.jsonl` (when and how
  long a game ran, how it ended, how fast it drew, how busy it kept the Mac), with the details in
  `SteamPlay/runs/<app id>/`, the newest 100 runs of each game.
- **Protium's own logs** in `~/Library/Logs/SteamPlay` and `~/Library/Logs/Protium`, and the backups
  of Steam settings files it changed, in `SteamPlay/backups`.

## What the Diagnostics button puts in its file

Diagnostics writes one text file to your Desktop, named `Protium-diagnostics-<date>.txt`. It sends
nothing. Open it and read it before you attach it to a report.

**What is in it**

- Protium's version, and whether it is the newest release (from the last update check).
- Your Mac's model, chip and memory, and the macOS version.
- Your screens' resolutions, and whether games get their full resolution.
- How Steam is set up for Protium, and every installed game with the version Steam runs for it:
  its Windows version through Protium, or its own Mac version.
- The last games Steam started: when, which version, with which launch options, how each ended,
  and Protium's record of the run.
- The names of crash reports macOS kept in the last week for Wine, Steam or a game (names only,
  not their contents).
- The end of Protium's and Steam's own logs about their setup.
- The start and the end of the logs of the last three games you ran through Protium, and the log
  of the Direct3D 9 layer when a game used it.

**What is taken out**

- Your home folder is written as `~`, so your user name does not appear. This also covers the
  form Windows programs use (`Z:\Users\<name>`).
- Steam account numbers are written as `<id>`.

**What it can still show**

- **The names of your installed games**, and of games you started.
- **The names of your disks**, when a game is on one: Steam libraries on another disk appear
  as `/Volumes/<disk name>/...`.
- **Whatever a game printed in its log.** Most games print only technical lines. A game could
  print, for example, your in-game name; that is why the file says to read it first.

It never includes your Steam account name, your e-mail address, your Mac's name, passwords,
tokens or the contents of your saved games.
