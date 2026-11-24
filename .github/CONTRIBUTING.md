# Contributing to Protium

Fixes and game reports are welcome. If you change Protium for your own builds, please send the
change back as a pull request so everyone gets it. If you distribute a changed Protium, the
license requires you to publish your changes anyway.

## Reporting a game

Open an issue with the *Game report* template: the game, how far it gets, your Mac and macOS
version, the Protium commit, and the `steamplay-run.log` from the game's
`steamapps/compatdata/<app id>/` folder.

## Sending a change

- Base it on the `macos-port` branch here, or on `macos-arm64` in
  [protium-wine](https://github.com/0xLeathery/protium-wine) for changes to Wine.
- One logical change per commit, with a message that says what it changes and why.
- A change to DXMT, vkd3d-proton, FEX or Mesa goes in as a patch in `macos/patches/<project>/`,
  applied by that project's build script. Its head says what it fixes.
- Say how you tested it: which game or `macos/tests/check-wave*.sh` item, on which Mac.
- Send your own work. Do not copy code from other projects into a pull request.

## License of contributions

By sending a pull request you agree that your change is published under the license of the
files it touches:
- the GNU GPL version 3 or later for Protium's own files (`macos/`, `.github/`);
- the changed project's license for a patch in `macos/patches/<project>/`;
- Wine's license (LGPL 2.1 or later) in protium-wine.
