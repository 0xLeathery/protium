# Parity with Steam Play on Linux

What a player gets from Steam Play (Proton) on Linux, and where this macOS build stands on each
point. "Evidence" names the check or the game that showed it; anything without evidence is marked
untested rather than assumed.

Status: **works** · **partial** · **missing** · **untested** · **blocked** (needs something we cannot
change: Mac Steam itself, a vendor, or code we do not write).

The date and the tables below are written from `macos/compat/parity.json` by `macos/steamplay docs`:
change a row there, not here.

<!-- parity: written by "macos/steamplay docs" from macos/compat/parity.json -->
Last reviewed 2026-11-25.

## Steam client integration

| Feature | How Linux does it | Here | What bringing it in takes |
|---|---|---|---|
| Install the Windows build | Steam Play enables it per game | **works**: Steam Play itself. Mac Steam has Linux's Steam Play and runs it while its platform is "linux" (`@sSteamCmdForcePlatformType linux` in the `steam_dev.cfg` next to its executables); it then installs each game's depots by the game's compatibility tool and keeps them across restarts (rollout 2026-11-17: GTFO re-fetched its Windows depot by itself, nothing else changed). `steamplay setup` writes the switch | `steamplay guard` keeps the switch and the tools in place; without them Steam removes Windows installs at its next start |
| Play from the game's own library entry | Steam starts the compatibility tool | **works**: Steam runs `<tool>/run waitforexitandrun <game>` with Proton's environment, as on Linux (IRON NEST, Just Die Already, Kerbal Space Program, 2026-11-17). Runs: 7 games ran well, the newest on 2026-11-24: Call of Duty: Modern Warfare Remastered (2017), Call of Duty: WWII, Call of Duty: World at War, IRON NEST: Heavy Turret Simulator, Just Die Already, Left 4 Dead, Red Dead Redemption 2. | — |
| Compatibility tool list, per-game tool choice; native builds win | Steam Play settings | **works**: two tools in `/usr/local/share/steam/compatibilitytools.d` (the folder Mac Steam scans): `proton-macos` (Windows build through Proton) and `macos-native` (the Mac build, unchanged). `steamplay setup` maps every game in Steam's app cache: a 64-bit or Apple Silicon Mac build wins, everything else gets Proton; `steamplay prefer` overrides one game. Kerbal got its Mac depot, not its Linux one | The guard maps newly bought games while Steam is not running; whether Steam's own Properties shows the choice is unchecked |
| Steamworks API (login, ownership, Steam DRM, stats, achievements) | lsteamclient to the Linux client | **works**: lsteamclient to Mac Steam's client library (check-wave5 item 10; IRON NEST, Left 4 Dead stats, GTFO login) | — |
| Playtime and "running" status | Steam tracks the tool's processes | **works**: Steam's log shows the game's process added and removed | — |
| Online play, Steam networking | through the client | **partial**: GTFO's network layer and its PlayFab login came up; lobbies and matches untested | Play a match |
| Steam Cloud, by API | through the client | **works**: one case so far: Left 4 Dead saved its config to the cloud | Test more games |
| Steam Cloud, files Steam syncs itself (Auto-Cloud) | Steam maps Windows save paths into the prefix | **works**: under Steam Play, Steam watches the save files in `compatdata/<id>/pfx/drive_c/users/steamuser/...` (IRON NEST, cloud log 2026-11-17) | Test a second game |
| Overlay (Shift+Tab), screenshots, Remote Play, broadcast | Steam injects its overlay library into the Wine process | **missing**: Valve's overlay DLLs are put in the prefix, because some games end themselves without them (Modern Warfare Remastered), but nothing is drawn. Steam passes its overlay libraries to the tool (`STEAM_DYLD_INSERT_LIBRARIES`: `steamloader.dylib`, `gameoverlayrenderer.dylib`, both with arm64 code), but the tool does not load them and our signed loader ignores injected libraries | Load them from the tool, add the entitlement that allows it, then see whether Valve's overlay can draw over our Metal output |
| Steam Input (controller layouts, remapping) | virtual controllers Proton reads | **untested**: controllers work directly instead (below) | After the overlay |
| Install scripts (first-run redistributables) | Steam runs them in the prefix | **works**: registry values and installers that run once. Mac Steam does not run the scripts, so `steamplay installscript` does what they ask for before a game's first start (Red Dead Redemption 2's Vulkan runtime, The Last of Us Part II's PlayStation runtime) | Try more games' scripts |
| Shader pre-caching | Steam downloads compiled shaders | **blocked**: Steam-side, Vulkan pipelines; DXMT and Metal keep their own caches | — |
| Updates, DLC, Workshop downloads | Steam | **partial**: Steam does them while the switch is on; Workshop untested | Follows the persistent switch |
| Uninstall removes the prefix | Steam | **missing**: the `compatdata` folder stays | Small tool step |

## Running the game

| Feature | How Linux does it | Here | What bringing it in takes |
|---|---|---|---|
| x86-64 and 32-bit x86 code | native CPU | **works**: through FEX (Just Die Already, GTFO; Left 4 Dead and Call of Duty: World at War, 32-bit). One known hang: the Godot editor (check-wave4 item 11, parked) Runs: 7 games ran well, the newest on 2026-11-24: Call of Duty: Modern Warfare Remastered (2017), Call of Duty: WWII, Call of Duty: World at War, IRON NEST: Heavy Turret Simulator, Just Die Already, Left 4 Dead, Red Dead Redemption 2. | Our fixes to FEX are in `macos/patches/fex` |
| Direct3D 10/11 | DXVK | **works**: DXMT (IRON NEST, Just Die Already, GTFO) Runs: 4 games ran well, the newest on 2026-11-24: Call of Duty: Modern Warfare Remastered (2017), Call of Duty: WWII, IRON NEST: Heavy Turret Simulator, Just Die Already. | — |
| Direct3D 9 | DXVK | **works**: mtld3d (check-wave5 item 6, Left 4 Dead) Runs: 2 games ran well, the newest on 2026-11-24: Call of Duty: World at War, Left 4 Dead. | — |
| Direct3D 12 | vkd3d-proton | **partial**: vkd3d-proton on KosmicKrisp; IRON NEST runs, heavy titles are untested or slow to load, ray tracing untested Runs: 1 game ran well, the newest on 2026-11-01: IRON NEST: Heavy Turret Simulator. | Test a heavy title (The Last of Us Part II is installed) |
| Direct3D 8 and older, DirectDraw | DXVK (d3d8), WineD3D | **untested** | Test an old game |
| Vulkan games | winevulkan | **partial**: Red Dead Redemption 2 reaches gameplay on its Vulkan renderer, with its frame rate limited by CPU time; no other Vulkan game tried Runs: 1 game ran well, the newest on 2026-11-01: Red Dead Redemption 2. | Test a second game |
| OpenGL | native driver | **partial**: up to 2.1 (check-wave5 item 7) | Zink (OpenGL on Vulkan, from Mesa) over KosmicKrisp |
| Fullscreen scaling (Proton's fullscreen hack, FSR) | in Wine's drivers | **missing**: needs OpenGL 3.3; plain fullscreen and resize work (items 5, 9) | After OpenGL |
| HDR, ray tracing, DLSS-style upscalers | DXVK/vkd3d + drivers | **untested**: not expected to work | — |
| Video: H.264, HEVC, VP8/9, WMV, MPEG-4; AAC, MP3, Opus, WMA | GStreamer + FFmpeg | **works**: H.264/AAC and VP9/Opus, with and without a Direct3D 11 device (item 3); the other decoders are built but untested | Test files per codec |
| Video: AV1 | dav1d | **missing**: its wrapper did not build | Build dav1d into the GStreamer set |
| Audio output | PulseAudio/ALSA | **works**: CoreAudio, and a stream follows a change of the default output; crackle in Call of Duty: WWII is open | Find the crackle |
| Microphone, voice chat | same | **untested** | Needs macOS's microphone prompt to reach the loader |
| Keyboard, mouse, cursor capture | X11/Wayland driver | **works**: item 4; mouse look is even in games that move the pointer back to the middle every frame (check-mouse.sh); one unreproduced stuck cursor in IRON NEST | — |
| Game controllers | SDL/hidraw | **partial**: since 0.4.2 controllers come through SDL as on Linux, with the layout of an Xbox controller for every one, and rumble; it is built in and starts, but no controller has been tried with it yet. An Xbox controller worked through the earlier path, XInput and DirectInput (item 8, IOHID). PlayStation and Switch controllers and rumble are untested | Players' reports for each kind of controller; `PROTON_NO_SDL=1` in a game's settings file goes back to the earlier path |
| TLS, HTTP, crypto | GnuTLS, libgcrypt | **works**: items 1, 2; Kerberos/NTLM sign-in missing | Rarely needed by games |
| .NET Framework programs (wine-mono) | bundled | **missing**: not in the bundle, and disabled at launch | Add Proton's wine-mono to the bundle |
| Embedded web views in launchers (wine-gecko) | bundled | **missing**: not in the bundle, and disabled at launch | Add it; test one publisher launcher |
| Proton's fonts (Arial, Times, Courier stand-ins, CJK) | bundled | **partial**: Wine's fonts are linked into the prefix as Proton links them, and the Mac's Arial, Courier New, Times New Roman, Tahoma, Microsoft Sans Serif and Wingdings stand in for Proton's; the East Asian and Indic ones have no stand-in | Build Proton's `fonts/` into the bundle |
| Per-game fixes and options (`proton` script: quirk lists, `PROTON_*` options, prefix template and upgrades, logs) | the `proton` launcher | **missing**: `steamplay-run.sh` is a minimal stand-in; each new prefix is made from scratch | Port Valve's `proton` script to macOS and launch through it: the largest single step towards parity |
| Fast synchronisation (ntsync/fsync) | kernel support | **works**: fsync on macOS, on unless `PROTON_NO_FSYNC=1`: events, semaphores and mutexes are kept in shared memory (check-wave5 item 15; Call of Duty: WWII loads a mission with it) | — |
| Kernel anti-cheat (Easy Anti-Cheat, BattlEye) | vendors' Proton runtimes, where a developer opts in | **blocked**: no macOS runtimes for Windows games | Vendor decision |
| VR | OpenVR bridge | **missing**: not planned | — |

## Install and updates

| Need | Here | What it takes |
|---|---|---|
| One install | **works**: Protium.app in a disk image, with Set up Steam, Repair, Status, Uninstall and Diagnostics (check-setup.sh) | — |
| Loader signed for other Macs | **works**: signed with a Developer ID and its profile, and notarized by Apple; it has run on one Mac so far | Reports from other Macs |
| Valve's Windows client DLLs | **works**: `steamplay steamclient` fetches them from Valve's servers and checks their SHA-256 | — |
| Updates of the runtime | **works**: the app asks GitHub once a day at most and updates itself, and the old version comes back if the new one does not start (check-update.sh) | — |
<!-- parity end -->

## Open, in order
1. Call of Duty: WWII: the stutter and the audio crackle.
2. Full resolution on a real Retina or 4K screen: so far it was only tried by making a normal screen behave like one.
3. The abort when IRON NEST quits (`UIAutomationCore.UiaDisconnectAllProviders` is unimplemented): not looked at again since 2026-11-17.
4. The overlay: Steam passes its libraries to the tool, which does not load them.
5. Port the `proton` launcher script; add wine-mono, wine-gecko and Proton's fonts to the bundle.
6. A match in an online game.
7. OpenGL through Zink; AV1; the untested rows above, one game each.
