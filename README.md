Note: This is my first attempt at a 'vibe coding' project. Most of this code was guided by me, but written by Claude. Therefore I can't verify it all works as intended or does what it states. I have tested this on my own NuVo system and it seems to work well. 

Take a look at NOTES.md for a more detailed look at how each layer works, and some notes on the Nuvo system itself.

# Nuvo Player (recreation)

A replacement controller for Nuvo Player Portfolio systems

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
- Turning a zone on and off
- Grouping zones together
- Browsing & Playing music/channels from Pandora and Sirius XM. Album art + song metadata works too.

## Status

NuvoPlayer application does work. I used this own my own system with four zones. Creating a group and playing music with Pandora & Sirius both work.
Volume control, play/pause, skip functions all work too. 

## Safety

`NuvoSafety` blocks the actions that re-home or wipe a player
(`SystemCreate`, `SystemJoin`, `SystemConfigureGWs`, `RestoreFactoryDefaults`,
`SelectPreset`, `StartWpsPbc`). The check sits in `ZoneClient.call`, the only
path to the network, so no caller can bypass it.

## Not built yet

- An iOS target (NuvoKit is ready; discovery on iOS needs the multicast
  entitlement or a Bonjour-based path)
