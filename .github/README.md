# Protium

Steam Play for Apple Silicon Macs, built natively. Protium is Valve's Proton 11 with its Wine
compiled as an arm64 macOS program, FEX inside Wine for the game's x86 code, and Direct3D drawn on
Metal. Nothing runs under Rosetta and there is no virtual machine: Mac Steam installs the Windows
build of a game and starts it through Protium, the way Steam on Linux starts Proton.

Protium is early. It is built and tested on one Mac (an M4 Pro on macOS 27.2), and there is no
installer for other Macs yet.

Protium is not affiliated with or endorsed by Valve or Apple. Steam and Proton are trademarks of
Valve Corporation, and Mac and Metal are trademarks of Apple Inc.

## Status

| Game | Graphics | How far it gets |
|---|---|---|
| IRON NEST: Heavy Turret Simulator | Direct3D 11 and 12 | Plays from its Steam library entry, with stats and cloud saves |
| Just Die Already | Direct3D 11 | Plays from Steam |
| GTFO | Direct3D 11 | Starts, and its network layer and PlayFab sign-in come up. Matches untested |
| Left 4 Dead | Direct3D 9, 32-bit | Runs. Stats and Steam Cloud work |
| Call of Duty: WWII | Direct3D 11 | Loads a mission, but stutters |
| Red Dead Redemption 2 | Vulkan | Reaches gameplay. Its frame rate is limited by CPU time |

Steam Play itself works on Mac Steam:
- installing the Windows build of a game;
- Play from the game's own library entry;
- a per-game choice between the Mac build and Protium;
- the Steamworks API (sign-in, ownership, stats, achievements);
- Steam Cloud.

Missing so far:
- the Steam overlay;
- OpenGL above 2.1;
- .NET programs (wine-mono) and embedded web views (wine-gecko);
- an installer and signing for other Macs.

Games with kernel-level anti-cheat are not expected to work.

[macos/PARITY.md](../macos/PARITY.md) compares Protium with Steam Play on Linux, point by point, and
names the check or game behind each.

## How it fits together

| Layer | Component | On macOS |
|---|---|---|
| Windows API | Proton 11's Wine (the `wine` submodule, branch `macos-arm64`) | A native arm64 Mach-O program |
| x86 code | [FEX](https://github.com/FEX-Emu/FEX) | Wine's ARM64EC (x86-64) and WoW64 (32-bit x86) emulator, with hardware TSO while x86 code runs |
| Direct3D 9 | [mtld3d](https://github.com/athei/mtld3d) | Direct to Metal |
| Direct3D 10 and 11 | [DXMT](https://github.com/3Shain/dxmt) | Direct to Metal |
| Direct3D 12 | [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) | On Vulkan |
| Vulkan | KosmicKrisp, [Mesa](https://mesa3d.org)'s Vulkan driver on Metal 4 | On Metal |
| Steam | Mac Steam's own Steam Play, and Proton's lsteamclient bridged to Mac Steam's client library | Sign-in, ownership, stats, cloud saves |

Protium builds on athei's macOS work: Mesa, DXMT, vkd3d-proton and FEX come from athei's branches
([mesa](https://github.com/athei/mesa), [dxmt](https://github.com/athei/dxmt),
[vkd3d-proton](https://github.com/athei/vkd3d-proton), [FEX](https://github.com/athei/FEX)) at the
commits each build script names, and Direct3D 9 is athei's mtld3d. Protium's own fixes to those
projects are in [macos/patches](../macos/patches), and each one says at its head what it fixes.

## Requirements

- An Apple Silicon Mac. Only macOS 27 has been tried.
- Xcode with its Metal toolchain, Homebrew, and
  [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) for the Windows side of the build.
- For x86 games, an Apple Developer provisioning profile that grants the cross-architecture
  entitlement. macOS gives a program memory below 4 GB, 4K pages and hardware TSO only when its
  loader is signed with that entitlement. Windows programs under FEX need the first two, and the
  third makes FEX faster.
  `macos/bundle-wine.sh` says how the profile is used.

## Building

Each script documents its inputs, outputs and environment overrides at its head. Builds go to
`~/projects/proton-macos-build` unless `BUILD_ROOT` says otherwise.

```sh
macos/build-vulkan.sh          # the Vulkan loader
macos/build-gstreamer.sh       # GStreamer, for Media Foundation audio and video
macos/build-wine.sh            # Wine, native arm64 (needs the two above)
macos/build-mesa.sh            # KosmicKrisp
macos/build-fex.sh             # FEX, as Wine's ARM64EC and WoW64 emulator
macos/build-llvm15.sh          # static LLVM 15, for DXMT's shader compiler
macos/build-dxmt.sh            # Direct3D 10 and 11
macos/build-vkd3d-proton.sh    # Direct3D 12
macos/build-steam-bridge.sh    # lsteamclient and the rest of Proton's Steam bridge
macos/bundle-wine.sh           # install everything into one bundle, with mtld3d, and sign the loader
macos/make-steamplay-app.sh    # "Steam Play.app"
```

Then, with Steam quit, `macos/steamplay setup` installs the two compatibility tools and sets up
Steam Play. `macos/steamplay status` shows the result, and `macos/steamplay` with no arguments
lists its other commands.

`macos/tests/check-wave*.sh` are the checks each stage of the port was accepted with.

## Licenses

Protium's own files (`macos/` and `.github/`) are under the BSD 3-Clause license in
[LICENSE.protium](../LICENSE.protium), the same license as Proton's own files
([LICENSE.proton](../LICENSE.proton)). Protium's patches in `macos/patches/<project>/` are under the
license of the project they change, and the `wine` submodule is under Wine's license. Every other
component keeps its own license. [LICENSE](../LICENSE) has the overview.
