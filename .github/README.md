# Protium

Steam Play for Apple Silicon Macs, built natively. Valve's Proton 11 with its Wine compiled as an
arm64 macOS program, FEX inside Wine for the game's x86 code, and Direct3D drawn on Metal. Nothing
runs under Rosetta and there is no virtual machine: Mac Steam installs the Windows build of a game
and starts it through Protium the way Steam on Linux starts Proton.

Protium is early. It is built and tested on one Mac (macOS 27.2), and there is no installer for
other Macs yet. [macos/PARITY.md](../macos/PARITY.md) records, point by point, what works compared
with Steam Play on Linux and what each point was checked with.

Protium is not affiliated with or endorsed by Valve or Apple.

## How it fits together

| Layer | Component | On macOS |
|---|---|---|
| Windows API | Proton 11's Wine (the `wine` submodule, branch `macos-arm64`) | A native arm64 Mach-O program |
| x86 code | [FEX](https://github.com/FEX-Emu/FEX) | Wine's ARM64EC (x86-64) and WoW64 (32-bit x86) emulator |
| Direct3D 10 and 11 | [DXMT](https://github.com/3Shain/dxmt) | Direct to Metal |
| Direct3D 12 | [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) | On Vulkan |
| Vulkan | KosmicKrisp, [Mesa](https://mesa3d.org)'s Vulkan driver on Metal 4 | On Metal |
| Steam | Mac Steam's own Steam Play, and Proton's lsteamclient bridged to Mac Steam's client library | Sign-in, ownership, stats, cloud saves |

Mesa, DXMT, vkd3d-proton and FEX come from athei's macOS branches
([mesa](https://github.com/athei/mesa), [dxmt](https://github.com/athei/dxmt),
[vkd3d-proton](https://github.com/athei/vkd3d-proton), [FEX](https://github.com/athei/FEX)) at
the commits each build script names, with a few local patches in [macos/patches](../macos/patches).
Each patch says at its head what it fixes.

## Status

Steam Play itself works on Mac Steam: installing Windows builds, Play from the game's own library
entry, a per-game choice between the Mac build and Protium, the Steamworks API (sign-in,
ownership, stats, achievements) and Steam Cloud, checked with IRON NEST, Left 4 Dead, Kerbal Space
Program and GTFO among others. Call of Duty: WWII loads a mission but still stutters. Red Dead
Redemption 2 reaches gameplay, held back by CPU time.

Missing so far: the Steam overlay, an installer and signing for other Macs, and kernel-level
anti-cheat, which is not expected to work.

## Requirements

- An Apple Silicon Mac. Only macOS 27 has been tried.
- Xcode with its Metal toolchain, Homebrew, and
  [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) for the Windows side of the build.
- For x86 games, an Apple Developer provisioning profile that grants the cross-architecture
  entitlement. An x86 program under FEX needs memory below 4 GB and 4K pages, which macOS gives
  only to a loader signed with it. `macos/bundle-wine.sh` says how the profile is used.

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
macos/bundle-wine.sh           # install everything into one bundle and sign the loader
macos/make-steamplay-app.sh    # "Steam Play.app"
```

Then, with Steam quit, `macos/steamplay setup` installs the two compatibility tools and sets up
Steam Play. `macos/steamplay status` shows the result. `macos/steamplay` without arguments lists
its other commands.

`macos/tests/check-wave*.sh` are the checks each stage of the port was accepted with.

## Licenses

Proton's own files are under Valve's license in [LICENSE](../LICENSE). Wine, FEX, DXMT,
vkd3d-proton, Mesa and the other components keep their own licenses. A patch carries the license
of the project it changes.
