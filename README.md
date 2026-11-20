Note: This is my first attempt at a 'vibe coding' project. Most of this code was guided by me, but written by Claude. Therefore I can't verify it all works as intended or does what it states. I have tested this on my own NuVo system and it seems to work well. 


# Nuvo Player (recreation)

A replacement controller for Nuvo Player Portfolio systems (P100, P200, P500,
P3100, P3500, P4300...). Protocol notes are in `NOTES.md`.

## Layout

| Path | What |
|---|---|
| `Sources/NuvoKit/UPnP` | Generic UPnP: SSDP discovery, SOAP control, GENA events, XML |
| `Sources/NuvoKit/Nuvo` | Nuvo specifics: `ZoneClient` (stateless calls), `Zone` and `NuvoSystem` (observable state) |
| `Sources/nuvoctl` | Command-line tool for testing against hardware |
| `Sources/NuvoPlayerApp` | SwiftUI macOS app |
| `Tests/NuvoKitTests` | Parsing tests using responses captured from a real P500 |
| `tools/` | The Python probe scripts used during reverse engineering |
| `captures/` | Raw device responses |

NuvoKit has no third-party dependencies and builds for macOS 14+ and iOS 17+.

## Build and run

```
swift test                     # parsing tests, no hardware needed
swift run nuvoctl discover     # find zones
swift run nuvoctl status       # read everything, change nothing
swift run nuvoctl watch 60     # print live events for 60 s
swift run NuvoPlayer           # the app
```

Or open `Package.swift` in Xcode and run the `NuvoPlayer` scheme.

`nuvoctl` commands that change the system: `volume`, `mute`, `linein`, `off`.

## What works (as written; see Status)

- Discovery, zone list, model/firmware/power state
- Volume and mute, with live updates pushed from the player
- Transport: play/pause, next, previous, now-playing text
- Line-in source selection, turning a zone on and off
- Grouping zones together

## Status

Written without a Swift toolchain available, so the first build may need
fixes. Verified so far: nothing at runtime. Grouping and line-in playback
are implemented from public reverse-engineering notes and have not been run
against hardware yet.

## Safety

`NuvoSafety` blocks the actions that re-home or wipe a player
(`SystemCreate`, `SystemJoin`, `SystemConfigureGWs`, `RestoreFactoryDefaults`,
`SelectPreset`, `StartWpsPbc`). The check sits in `ZoneClient.call`, the only
path to the network, so no caller can bypass it.

## Not built yet

- Browsing music services, queue, favorites, search (needs the undocumented
  `X_NUVO_Browse` actions reverse engineered)
- Album art
- An iOS target (NuvoKit is ready; discovery on iOS needs the multicast
  entitlement or a Bonjour-based path)
