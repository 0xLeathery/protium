# Contributing to Protium

Fixes and game reports are welcome. If you change Protium for your own builds, please send the
change back as a pull request so everyone gets it. If you distribute a changed Protium, the
license requires you to publish your changes anyway.

## Reporting a game

Update Protium to its newest release first (its window offers the update), then open an issue
with the *Game report* template: the game, how far it gets, your Mac and macOS
version, the Protium version, the file Protium's Diagnostics button saves on your Desktop, and the
`steamplay-run.log` from the game's `steamapps/compatdata/<app id>/` folder (for a game in Steam's
own library, `~/Library/Application Support/Steam/steamapps/compatdata/<app id>/`).

## Sending a change

- Base it on the `macos-port` branch here, or on `macos-arm64` in
  [protium-wine](https://github.com/0xLeathery/protium-wine) for changes to Wine.
- One logical change per commit, with a message that says what it changes and why.
- A change to DXMT, vkd3d-proton, FEX or Mesa goes in as a patch in `macos/patches/<project>/`,
  applied by that project's build script. Its head says what it fixes.
- Say how you tested it: which game or `macos/tests/check-wave*.sh` item, on which Mac.
- A change to `macos/steamplay` keeps `python3 -B -m unittest macos/tests/test_steamplay.py`
  passing, and adds a test there when it changes how Steam's files are read or written.
- Send your own work. Do not copy code from other projects into a pull request.

## The status documents

The games table and the "Missing so far" list in the README, and the tables in `macos/PARITY.md`,
are written from `macos/compat/games.json` and `macos/compat/parity.json`. Do not edit them in
the documents. A change that makes something work, or breaks it, changes its row in
`parity.json` in the same commit; then `macos/steamplay docs` writes the documents again.
The unit tests fail while a document and its data differ. They run on every push, and before
each commit once you have turned the hook on in your clone:

```sh
git config core.hooksPath .githooks
```

## License of contributions

By sending a pull request you agree that your change is published under the license of the
files it touches:
- the GNU GPL version 3 or later for Protium's own files (`macos/`, `.github/`);
- the changed project's license for a patch in `macos/patches/<project>/`;
- Wine's license (LGPL 2.1 or later) in protium-wine.


## The changelog

A change a player will notice gets a line under `## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md),
in the same pull request, under the heading that fits: Added, Changed, Deprecated, Removed, Fixed
or Security ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)). Write it for someone who
plays games, not for someone who reads the code. A release moves those lines into its own section.
