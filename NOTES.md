# Nuvo Player Portfolio: protocol notes

Status: 2026-11-16. Everything below is from public reverse-engineering
write-ups (mostly a P4300 on firmware 2025.1, plus a P3100). Nothing has been
confirmed against our own amp at 10.0.0.48 yet. Run `probe.py` to do that.

## Summary

Control is UPnP: SSDP for discovery, SOAP over HTTP for commands, GENA
(HTTP callbacks) for push state updates. The UPnP stack on the amp is GUPnP on
Linux. On top of the standard media services Nuvo added one custom service
(Zone) and a set of `X_NUVO_*` actions. There is also a JSON HTTP API on
port 80 behind the amp's web UI, and an unexplored TCP port 4747.

## Discovery

- SSDP search target: `urn:schemas-nuvotechnologies-com:device:Zone:1`
- Each zone is its own UPnP device, even on a multi-zone amp.
- Zone identity: `memberId-<mac, lowercase, no colons>`;
  UDN `uuid:00000000-0000-0000-0000-<mac>`.
- Description URL: `http://<ip>:<port>/<udn>.xml`. The port is ephemeral and
  changes when the amp reboots, so always rediscover; never hardcode it.
- mDNS: `_nuvoplayer._tcp` on port 4747 per zone (TXT `httpPort=80`),
  `_nuvomaster._tcp` on the zone currently acting as system master.

## Services (control URL)

| Service | Control URL | Purpose |
|---|---|---|
| Nuvo `Zone:1` | /ZoneService/control | zone info, grouping, power-ish |
| AVTransport:1 | /AVTransport/control | play/pause/next, source selection |
| RenderingControl:1 | /RenderingControl/control | volume, mute, loudness |
| ContentDirectory:1 | /ContentDirectory/control | browsing sources/services |
| ConnectionManager:1 (x2) | /ConnectionManager-MR, -MS | mostly unimplemented |

Event URLs are the same paths ending in `/event`.

## Key actions

Zone
- `Get` -> Title (real zone name), Model, FirmwareVersion, SystemID, MemberID,
  MasterGroup, MemberGroup, AudioInput, PowerState.
- `GroupCreate(memberIDs as JSON array)` -> groupID
- `GroupDisband(groupID)`
- `GroupMemberSetGroup(memberIDs, groupID)`; empty groupID means leave.
- DANGEROUS, never send: `SystemCreate`, `SystemJoin`, `SystemConfigureGWs`,
  `RestoreFactoryDefaults`.

RenderingControl
- `GetVolume` / `SetVolume` (0-100, Channel=Master), `GetMute` / `SetMute`
- `X_NUVO_AdjustVolume` (signed delta)

AVTransport
- Standard transport actions, plus `X_NUVO_PlayURI`,
  `X_NUVO_PlayContainerURI`, `X_NUVO_TogglePause`, `X_NUVO_PauseOrStop`,
  `X_NUVO_Like`, `X_NUVO_Dislike`.

ContentDirectory
- Standard `Browse` works for some object IDs (`tunein:`,
  `lineIn:systemLineIns`).
- `X_NUVO_Browse` / `X_NUVO_Browse2` are what the app really uses.
  Nobody has documented these. This is the biggest gap for a full app clone.

## Behaviour model

- There is no real "power off". A zone is "on" when it is in a group that is
  playing something. Off = `GroupDisband`. On = `GroupCreate`, then
  `X_NUVO_PlayContainerURI` to pick a source.
- Each zone has a MasterGroup (group it hosts) and a MemberGroup (group it is
  listening to). Joining zones = `GroupMemberSetGroup` with the master's group.
- State pushes arrive via GENA subscriptions (timeout 300 s, renew earlier).
  AVTransport and RenderingControl deliver a `LastChange` XML blob.
- `Zone.Get` can lag 1-2 s behind a grouping change; trust events over polls.

## Port 80 JSON API ("nSDK")

- Login: `POST /api/authenticate` with the base64 of the device serial number.
  The serial is therefore a secret. `probe.py` redacts it.
- Read: `/api/getData?path=...&roles=value`, `/api/getRows?path=...`
- Write: `/api/setData?...` (settings; treat as risky)
- Holds settings such as turn-on volume, volume step, inactivity timeout.

## Known hazards

- `SetAVTransportURI` + `Play` with a WAV URL crashed a zone's UPnP process.
- Bass/treble/balance can be written but reportedly do nothing audible.
- Idle zones drop out of their group after the inactivity timeout.

## Open questions

1. What model/firmware is our amp, and does it match the above?
2. `X_NUVO_Browse` / `X_NUVO_Browse2` argument format (needs the app or a
   packet capture).
3. What speaks on TCP 4747?
4. Which music services still work at all, given the backend is abandoned?
5. Is the official "Wireless Audio System API" document obtainable?

## Sources

- https://github.com/mattmoo/ha-nuvo-player-portfolio (docs/protocol.md)
- https://github.com/mpdrago/nuvo-zone-keepalive
- https://www.legrand.us/c/discontinued-p3100-professional-series-player/p/nvp3100na

---

# Confirmed on our hardware (probe run 2026-11-16)

Raw files are in `captures/`.

## Devices found

| IP | What | Notes |
|---|---|---|
| 10.0.0.48 | NV-GW100 wireless gateway | Not a player. libupnp 1.3.1, port 49152. One service, `GatewayConfig:1`, with only `StartWpsPbc` and `GetSystemId`. Nothing to control here. |
| 10.0.0.91 | Zone "Sound Bar", model `p500` | The actual player. GUPnP 0.20.8, description port 44242 (ephemeral). Firmware 2025.0. MemberID `memberId-0025ed1e2a55`. |

Only one zone answered SSDP. If the house has more players, they were asleep,
on another network segment, or missed (SSDP is lossy; rerun the probe).

## State at probe time

PowerState `standby`, AudioInput `toslink`, not in any group (MasterGroup and
MemberGroup ids empty), transport `NO_MEDIA_PRESENT`, volume 28, not muted.
So `standby` is a real observable state (the public notes had never seen it).

## Matches the public notes

Service list, control/event URLs, Zone actions, RenderingControl actions and
the AVTransport `X_NUVO_*` actions all match. The P500 speaks the same
protocol as the P3100/P4300, so those notes are a usable reference.

## New: ContentDirectory is much bigger than documented

Besides `X_NUVO_Browse` / `X_NUVO_Browse2`, the SCPD exposes:

- `X_NUVO_Action(ObjectID)` and `X_NUVO_Action2(ObjectID, GroupID, MetaData,
  ParentMetaData, Index, Context...)` -> Result, Events. Looks like "invoke
  this menu item" (the app's tap handler).
- `X_NUVO_AddChild`, `X_NUVO_MoveChild`, `X_NUVO_RemoveChild`,
  `X_NUVO_ClearChildren`: list editing, presumably the play queue/favorites.
- `X_NUVO_GetQueryID(ObjectID, Query)`: search.
- `X_NUVO_CreateSubscribeQueue`, `X_NUVO_Subscribe(QueueID, ObjectID, Type)`,
  `X_NUVO_Unsubscribe`, `X_NUVO_ReadSubscribeQueue(QueueID)`: a second,
  polled event channel separate from GENA. Type is `rows` or `item`.
- `X_NUVO_Browse2` returns a `ResultEncrypted` flag. Unknown what triggers it.

Reading: the app UI is server-driven. The device hands out a tree of
menu rows; the app browses it, invokes rows with Action2, and watches rows
for changes through a subscribe queue. A faithful clone is mostly a generic
renderer for that tree.

## Other details

- AVTransport state vars not in the public notes: `X_NUVO_Rating`,
  `X_NUVO_Context`, `X_NUVO_Info`, `X_NUVO_MatchingAVTransportURIs`.
- Zone evented vars: APIVersion, HttpPort, UpdateState, UpdateURL, Language,
  CompatibleDevices, WirelessSupported.
- Web UI for the player: http://10.0.0.91/home.fcgi
- Port 4747 and port 80 checks in the first probe hit the gateway by mistake;
  still untested on the player.

## Full-network sweep (discover.py, 2026-11-16 18:01)

- 4 multicast rounds + unicast sweep of 10.0.0.1-254 + mDNS: still exactly
  one Player Portfolio zone (Sound Bar, 10.0.0.91) plus the GW100 gateway.
- mDNS: the Sound Bar advertises `_nuvoplayer._tcp` (port 4747),
  `_nuvomaster._tcp` (port 80, so it is the system master) and Spotify
  Connect. Hostname `nu-0025ed1e2a55.local`.
- tcp/80 and tcp/4747 are both open on the player.
- `Browse("lineIn:systemLineIns")` returns one input ("Optical", owned by
  Sound Bar) and a footer row. So the system, as the Sound Bar sees it, has
  one member.
- Each DIDL item carries an `x:x_nuvo_nsdk` element holding a JSON object
  (title, path, icon, type, sortKey, disabled, mediaData...). Rows have types
  such as `audio` and `footer`. This supports the server-driven-UI reading:
  the JSON is the row model the app renders.

Open: where are the central controller and the standalone speakers? Not on
10.0.0.x as Player Portfolio zones. Either a legacy Nuvo system (Grand
Concerto / Essentia: RS-232, different protocol), powered down, or on a
different network.

## Line-in play request (from nuvo-zone-keepalive's template)

`X_NUVO_PlayContainerURI` on AVTransport, arguments in order: InstanceID 0,
CurrentURI empty, CurrentURIMetaData = DIDL for container
`lineIn:systemLineIns`, TrackURI = the item's `res`, TrackURIMetaData = DIDL
for the item, StartingIndex 1, UpdateID -1. NuvoKit sends the item's DIDL
exactly as the player returned it from Browse, rather than rebuilding it.

## Zone ID vs network MAC

The Sound Bar's ARP entry is 00:25:ed:9e:2a:55 but its zone ID is
memberId-0025ed1e2a55 (one bit apart: Wi-Fi vs Ethernet MAC). Never derive a
zone ID from a network address; read it from the device.

## P4300

Model NV-P4300 is in the rack (zones Gym, one unread, Family Room) but has no
presence on 10.0.0.x: no SSDP, no ARP entry, not in the Nuvo Player app.
Physical/network issue to chase at the rack.

## Line-in list is dynamic (observed 2026-11-16 19:34)

`Browse("lineIn:systemLineIns")` on the Sound Bar returned the "Optical" item
(flagged disabled) at 18:01, and at 19:34 returned only a "No devices"
placeholder row (`upnp:class` object.item, no `res`) plus the footer. So
inputs are listed only while the player detects something on the jack, and
placeholder rows must be filtered out by the absence of a `res` element.

## Full system online (2026-11-16 19:53, captures/p4300-first-look.txt)

| Zone | Model | IP | Zone ID | Desc. port |
|---|---|---|---|---|
| Bar | p4300 | 10.0.0.109 | memberId-0025ed1e013e | 42431 |
| Family Room | p4300 | 10.0.0.197 | memberId-0025ed1dfe08 | 43676 |
| Gym | p4300 | 10.0.0.207 | memberId-0025ed1dfe12 | 37725 |
| Sound Bar | p500 | 10.0.0.91 | memberId-0025ed1e2a55 | 44242 |

- One P4300 chassis = three zones, each with its own IP, MAC and UPnP
  server. Nothing on the wire ties them to one box except the model name.
- All four share SystemID nuvoCSRJnoZYu81NO7dz; the P4300 rejoined by itself.
- All firmware 2025.0.
- PowerState is not "on/off": idle P4300 zones report `active`, the idle
  P500 reports `standby`. Use MemberGroup to decide whether a zone is on.
- AudioInput on the Sound Bar read `toslink` at 18:01 and `player` at 19:53,
  matching the line-in list going empty. It tracks what the jack currently
  detects, not a setting.

## First live playback capture (captures/watch-playback.txt, 2026-11-16 19:56)

Official app played SiriusXM "90s on 9" on Family Room.

- GENA works on all four zones, all three services (12 subscriptions).
  Each subscription delivers a full initial state dump, then deltas.
- SiriusXM is alive on this system. Source URI:
  `nuvo:siriusxm2:ui/carousel?primary=Api:tune:liveAudio:8206&assetType=channel&channelId=8206&...`
- Live radio: CurrentTransportActions = `Play,Stop` (no Pause, Next,
  Previous). State sequence on start: TRANSITIONING -> PLAYING; on stop:
  STOPPED.
- Track metadata IS pushed in AVTransport LastChange: `CurrentTrackMetaData`,
  `X_NUVO_Info` and `X_NUVO_Context` all carry DIDL. (Contents were cut off
  at 160 chars by nuvoctl in this capture; truncation since removed.)
- RenderingControl sends Volume and VolumeDB on every step of a drag.
  Mute and Loudness arrive as `TRUE`/`FALSE`, not 1/0.
- Zone service initial state includes APIVersion (JSON, api 15),
  CompatibleDevices (p100...p5200, au7001, au7002), UpdateURL, Icon
  (`skin:iconZoneBar`, `skin:iconSoundbarPlayer`...).
- The capture window closed before the Sound Bar was grouped in; no group
  join events recorded yet.

## Grouped playback, observed (captures/status-playing.txt, watch-grouping.txt)

Family Room playing SiriusXM with Sound Bar joined:

- Master (Family Room): MasterGroup == MemberGroup == gidO1p1DFsnw9h8p9YL,
  transport PLAYING, actions Play,Stop.
- Member (Sound Bar): MemberGroup = the master's group ID, MasterGroup empty.
  Its OWN transport reads NO_MEDIA_PRESENT with no actions. A member never
  mirrors playback state; read it from the master.
- The Sound Bar's PowerState went standby -> active on joining.
- Bar and Gym showed a non-empty MasterGroup with an empty MemberGroup while
  idle. So a zone can host a group it is not in; only MemberGroup means "on".
- `sortKey` in the group JSON is an epoch timestamp in milliseconds.
- The join/leave itself was not captured (it happened before the listener
  finished subscribing). Still need those events.

### SiriusXM metadata mapping

| DIDL field | Content | Example |
|---|---|---|
| dc:title | station | Ch 9 - 90s on 9 |
| dc:description | song (year) | Slide (98) |
| upnp:longDescription | artist - album | Goo Goo Dolls - Dizzy Up the Girl |
| dc:creator | service ID, NOT artist | siriusxm2 |
| upnp:icon | art URL, plain http | http://albumart.siriusxm.com/... |

Song changes arrive as a new CurrentTrackMetaData event; the URI is constant.
The station logo is sent first, then replaced by album art once known.
Every item also carries `x_nuvo_context` (a context-menu path) and
`x_nuvo_nsdk` JSON with `mediaData.metaData.playLogicPath`
(`siriusxm2:playback/playLogic`).

## Source probe on the full system (captures/sources.txt, 2026-11-16 20:10)

Asked Bar (idle P4300) with standard `Browse`:

| ObjectID | Result |
|---|---|
| `tunein:` | 8 folders (My Favorites, Local Radio, Music, Talk, Sports, By Location, By Language, Podcasts). IDs are `tunein:browse/uri/Browse.ashx?...` |
| `pandora:` | 52 rows: folder "New Genre Station" + 51 playable stations (`pandora:StationList/station_<n>`, uri `nuvo:pandora:...`). Account is linked. |
| `lineIn:systemLineIns`, `/stable/lineIn/` | same listing (placeholder + footer when nothing connected) |
| `spotify:` | 4 informational rows (Spotify Connect) |
| `sirius:`, `napster:`, `deezer:` | "not configured" + a "Fix it!" row of type `action` |
| `alexa:` | 1 informational row |
| `0` | empty |
| `siriusxm2:`, `top10:`, `bluetooth:`, `/`, `/stable/` | 501 "Node at path '...' does not exist" |
| `iheart:`, `rhapsody:`, `amazon:`, `favorites:`, `presets:`, `playHistory:`, `usb:`, `library:`, `airplay2:`, `testStreams:`, `ui:`, `nuvo:`, `sxZone:` | timed out (5 s) |

- 501 "does not exist" vs timeout looks meaningful: a timeout suggests the
  provider exists but the bare root is not a browsable node.
- SiriusXM plays, yet `siriusxm2:` is not a node. The playing URI was
  `siriusxm2:ui/carousel?primary=Api:tune:liveAudio:8206&...`, so its menu
  root is somewhere under `siriusxm2:ui/`. Not found yet.
- `X_NUVO_Browse("0")` returns no rows, with ContainerProperties describing an
  empty container. The home menu is not at "0". Still unknown.
- Row types seen in the nsdk JSON: container, audio, footer, spacer, action, www.

## X_NUVO_Browse works on services (2026-11-16 20:25, Gym, `pandora:`)

Same 52 rows as standard Browse, plus `ContainerProperties`: a DIDL document
describing the folder itself.

- Canonical ID is `pandora:StationList` (`pandora:` is an alias), title
  "Pandora", icon `skin:iconPandora` (art is built into the official app).
- `x:x_nuvo_search id="pandora:searches"` titled "Artist, Track", class
  `object.container.x_nuvo_searchContainer`, nsdk containerType `search`.
  This is how a folder advertises that it is searchable.
- `x:x_nuvo_activity` 1 / nsdk `"activity": true` (meaning unknown).
- ContainerProperties is the folder description to send as
  CurrentURIMetaData when playing a row from that folder.

## First playback started by NuvoKit (2026-11-16 20:30, captures/play-pandora.txt)

`nuvoctl play "Family Room" "pandora:" "90s Pop"` switched the Family Room
group from SiriusXM to Pandora "90s Pop Radio".

- X_NUVO_PlayContainerURI works for Pandora with: CurrentURI empty,
  CurrentURIMetaData = the folder's ContainerProperties verbatim, TrackURI =
  the row's `res`, TrackURIMetaData = the row's DIDL verbatim, StartingIndex
  = the row's 1-based position (11), UpdateID -1. Same shape as line-in and
  TuneIn, so one play path covers all three.
- Pandora transport actions: Next, Pause, Play, Stop, X_NUVO_Like,
  X_NUVO_Dislike. (No Previous.) Compare SiriusXM live: Play, Stop only.
- Pandora metadata: dc:title is the song ("Doin' Time"); dc:description
  carries album and artist ("Sublime (...) - Sublime").
- Sent to the group master, it changed every zone in the group.

## Leave verified; stale transport on followers (captures/leave-test.txt, 20:45)

- `GroupMemberSetGroup(memberIDs=[self], groupID="")` sent to the follower
  (Sound Bar) removed only that zone. Leader (Family Room, Pandora) kept
  playing. Sound Bar's MemberGroup went empty and PowerState active -> standby.
- A zone's own AVTransport is NOT cleared when it follows another zone or
  goes idle. Sound Bar reported `PLAYING`, actions `Play,Stop`, and a TuneIn
  station (its own last source) both while following Family Room's Pandora
  group and after leaving, in standby. Earlier it had reported
  NO_MEDIA_PRESENT in the same role. So for any zone that is not a group
  leader, its own transport state and metadata are leftovers and must be
  ignored: playback truth = MemberGroup + the leader's transport.
- TuneIn metadata: dc:creator is `tuneIn`; title is the station.

## SiriusXM menu root found (captures/sxm-try.txt, 2026-11-16 21:22)

`siriusxm2:ui/root` (reports its own ID as `siriusxm2:ui/browse`, empty title):

| Row | ID |
|---|---|
| All Channels | `siriusxm2:ui/carousel?primary=App:carousel:channels_all` |
| Favorites | `siriusxm2:ui/carousel?primary=App:carousel:favorites_everest` |
| Recents | `siriusxm2:ui/carousel?primary=App:carousel:recents` |
| For You | `siriusxm2:ui/root/forYou` |

- `siriusxm2:playerMenu` is the now-playing context menu: "Sleep Timer"
  (`nuvoUIMenu:sleepTimer`) and "Save to Top 10" (`top10:saveTo`).
- `siriusxm2:ui/carousel` with no or unknown query answers 501 "Service is
  currently unavailable. Try again later." (a third failure mode: the node
  exists but the upstream SiriusXM request failed).
- When the official app plays a channel, AVTransportURIMetaData holds the
  channel item itself, not its parent folder.
- The official app's bundle name is "Tesla". Its home tabs (from the App
  Store screenshot): SiriusXM, Library, This iPad, Top 10, Napster.
