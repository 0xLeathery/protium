# Parity with Steam Play on Linux

What a player gets from Steam Play (Proton) on Linux, and where this macOS build stands on each
point. "Evidence" names the check or the game that showed it; anything without evidence is marked
untested rather than assumed. Last reviewed 2026-11-17.

Status: **works** · **partial** · **missing** · **untested** · **blocked** (needs something we cannot
change: Mac Steam itself, a vendor, or code we do not write).

## Steam client integration

| Feature | How Linux does it | Here | What bringing it in takes |
|---|---|---|---|
| Install the Windows build | Steam Play enables it per game | **partial**: console switch `@sSteamCmdForcePlatformType windows` + `app_install`; forgotten on restart, and Steam then swaps or deletes Windows files | Persisting the switch: `steam_dev.cfg` (experiment: `tests/steam-platform-persist-test.sh`), or the per-game platform override Steam Play uses (`CCompatManager` is in the Mac client) |
| Play from the game's own library entry | Steam starts the compatibility tool | **partial**: `steamplay-launch` as a launch option (run by hand: works; from Steam's Play button: untested). Today: non-Steam shortcuts (`steamplay sync`), a second entry per game | Confirm from Steam; have the tool write the launch option per game; then drop the shortcuts |
| Compatibility tool list, per-game tool choice | Steam Play settings | **blocked**: Mac Steam hides Steam Play and answers "Invalid platform" to tool mappings | Not needed with one runtime |
| Steamworks API (login, ownership, Steam DRM, stats, achievements) | lsteamclient to the Linux client | **works**: lsteamclient to Mac Steam's client library (check-wave5 item 10; IRON NEST, Left 4 Dead stats, GTFO login) | — |
| Playtime and "running" status | Steam tracks the tool's processes | **works** (Steam's log: game process added/removed) | — |
| Online play, Steam networking | through the client | **partial**: GTFO's network layer and its PlayFab login came up; lobbies and matches untested | Play a match |
| Steam Cloud, by API | through the client | **works** in one case (Left 4 Dead saved its config to the cloud) | Test more games |
| Steam Cloud, files Steam syncs itself (Auto-Cloud) | Steam maps Windows save paths into the prefix | **untested**; likely missing, since that mapping is Steam Play's | Test with a game that uses it; if missing, sync the paths ourselves around a launch |
| Overlay (Shift+Tab), screenshots, Remote Play, broadcast | Steam injects its overlay library into the Wine process | **missing**: shortcuts are not started by Steam, and our signed loader ignores injected libraries | Launch from Steam (above), a compiled launcher that passes the injection on, the entitlement that allows it, then see whether Valve's overlay can draw over our Metal output |
| Steam Input (controller layouts, remapping) | virtual controllers Proton reads | **untested**; controllers work directly instead (below) | After the overlay |
| Install scripts (first-run redistributables) | Steam runs them in the prefix | **missing** | Run `installscript.vdf` ourselves at first launch, or rely on Wine's built-in runtimes |
| Shader pre-caching | Steam downloads compiled shaders | **blocked** (Steam-side, Vulkan pipelines); DXMT and Metal keep their own caches | — |
| Updates, DLC, Workshop downloads | Steam | **partial**: Steam does them while the switch is on; Workshop untested | Follows the persistent switch |
| Uninstall removes the prefix | Steam | **missing**: the `compatdata` folder stays | Small tool step |

## Running the game

| Feature | How Linux does it | Here | What bringing it in takes |
|---|---|---|---|
| x86-64 and 32-bit x86 code | native CPU | **works** through FEX (Just Die Already, GTFO; Left 4 Dead 32-bit). One known hang: the Godot editor (check-wave4 item 11, parked) | FEX is not ours to change: report upstream |
| Direct3D 10/11 | DXVK | **works**: DXMT (IRON NEST, Just Die Already, GTFO) | — |
| Direct3D 9 | DXVK | **works**: mtld3d (check-wave5 item 6, Left 4 Dead) | — |
| Direct3D 12 | vkd3d-proton | **works**: vkd3d-proton on KosmicKrisp (IRON NEST); ray tracing untested | Test a heavy title (The Last of Us Part II is installed) |
| Direct3D 8 and older, DirectDraw | DXVK (d3d8), WineD3D | **untested** | Test an old game |
| Vulkan games | winevulkan | **partial**: the arm64 Godot editor renders on Vulkan; no x86 Vulkan game tried | Test one |
| OpenGL | native driver | **partial**: up to 2.1 (check-wave5 item 7) | Zink (OpenGL on Vulkan, from Mesa) over KosmicKrisp |
| Fullscreen scaling (Proton's fullscreen hack, FSR) | in Wine's drivers | **missing**: needs OpenGL 3.3; plain fullscreen and resize work (items 5, 9) | After OpenGL |
| HDR, ray tracing, DLSS-style upscalers | DXVK/vkd3d + drivers | **untested** / not expected | — |
| Video: H.264, HEVC, VP8/9, WMV, MPEG-4; AAC, MP3, Opus, WMA | GStreamer + FFmpeg | **works** for H.264/AAC and VP9/Opus, with and without a Direct3D 11 device (item 3); the other decoders are built but untested | Test files per codec |
| Video: AV1 | dav1d | **missing** (its wrapper did not build) | Build dav1d into the GStreamer set |
| Audio output | PulseAudio/ALSA | **works**: CoreAudio | — |
| Microphone, voice chat | same | **untested** | Needs macOS's microphone prompt to reach the loader |
| Keyboard, mouse, cursor capture | X11/Wayland driver | **works** (item 4); one unreproduced stuck cursor in IRON NEST | — |
| Game controllers | SDL/hidraw | **works** for an Xbox controller, XInput and DirectInput (item 8, IOHID); rumble, PlayStation and Switch controllers untested | Test; add rumble if absent |
| TLS, HTTP, crypto | GnuTLS, libgcrypt | **works** (items 1, 2); Kerberos/NTLM sign-in missing | Rarely needed by games |
| .NET Framework programs (wine-mono) | bundled | **missing**: not in the bundle, and disabled at launch | Add Proton's wine-mono to the bundle |
| Embedded web views in launchers (wine-gecko) | bundled | **missing**, same | Add it; test one publisher launcher |
| Proton's fonts (Arial, Times, Courier stand-ins, CJK) | bundled | **missing**: only Wine's basic fonts | Build Proton's `fonts/` into the bundle |
| Per-game fixes and options (`proton` script: quirk lists, `PROTON_*` options, prefix template and upgrades, logs) | the `proton` launcher | **missing**: `steamplay-run.sh` is a minimal stand-in; each new prefix is made from scratch | Port Valve's `proton` script to macOS and launch through it: the largest single step towards parity |
| Fast synchronisation (ntsync/fsync) | kernel support | **missing**: all waits go through wineserver | A macOS equivalent in Wine (performance, not correctness) |
| Kernel anti-cheat (Easy Anti-Cheat, BattlEye) | vendors' Proton runtimes, where a developer opts in | **blocked**: no macOS runtimes for Windows games | Vendor decision |
| VR | OpenVR bridge | **missing**, not planned | — |

## Install and updates (for testers)

| Need | Here | What it takes |
|---|---|---|
| One install | **missing**: built from source on one Mac | An installer app with the bundle |
| Loader signed for other Macs | **missing**: the profile covers this Mac only | Register testers' Macs in the profile, or a notarised Developer ID build |
| Valve's Windows client DLLs | **partial**: taken from a Windows Steam folder on this Mac | Fetch them from Valve on the tester's Mac |
| Updates of the runtime | **missing** | An update check in the installer app |

## Order of investigation
1. Persisting the Windows switch (`tests/steam-platform-persist-test.sh`), since restarts destroy installs.
2. Play from the real entry (`steamplay-launch` from Steam), then remove the shortcuts.
3. The overlay: launcher as a program, the loader's entitlement, whether Valve's overlay draws.
4. Port the `proton` launcher script; add wine-mono, wine-gecko and Proton's fonts to the bundle.
5. Auto-Cloud, install scripts, a match in an online game.
6. OpenGL through Zink; AV1; the untested rows above, one game each.
