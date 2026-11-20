# Nuvo Player Portfolio: how the backend works

A technical breakdown of how a Nuvo Player Portfolio system is controlled over
the network, layer by layer, and how NuvoKit implements each layer.

Last reviewed 2026-11-20 against commit `ab069e1`. The earlier version of this
file was a chronological reverse-engineering log; it is still in git history
(`git show 0a02fb4:NOTES.md`). Every finding from it is folded in below.

Confidence markers used throughout:

- **[seen]** observed on this system (raw evidence is in `captures/`).
- **[public]** taken from public reverse-engineering write-ups (see Sources)
  and not independently checked here.
- **[unknown]** not understood yet.

Unmarked statements about NuvoKit describe the code as written.

---

## 1. Overview

Control is plain UPnP, the same protocol family DLNA media players use. Each
zone runs a GUPnP 0.20.8 server on Linux 2.6.37 (all four zones report this
in their SSDP `Server` header) **[seen]**. Nuvo added one
custom service (`Zone`) and a set of `X_NUVO_*` actions on the standard
services.

There are three channels, and NuvoKit has one component for each:

| Channel | Transport | Direction | Purpose | NuvoKit |
|---|---|---|---|---|
| SSDP | UDP, port 1900 | app -> multicast, zone -> app | find zones | `SSDP.swift` |
| SOAP | HTTP POST | app -> zone | commands and queries | `SOAP.swift` |
| GENA | HTTP SUBSCRIBE / NOTIFY | app -> zone, then zone -> app | pushed state changes | `Eventing.swift` |

```
  SwiftUI app (NuvoPlayerApp)            nuvoctl (CLI)
            |                                 |
  NuvoSystem / Zone / MediaBrowser            |      observable state + policy
            |                                 |
            +----------- ZoneClient ----------+      one method = one SOAP action,
                             |                       safety list enforced here
        +--------------------+------------------+
   SOAPClient          GENA + EventServer      SSDP  generic UPnP, no Nuvo knowledge
        | HTTP POST         | SUBSCRIBE out,     | UDP 1900
        |                   | NOTIFY in          |
        +-------------- zone (GUPnP) ------------+
```

Nothing is authenticated. Any device on the LAN can send any of these
requests, which is why NuvoKit carries a blocklist of destructive actions
(section 13).

### The system as installed [seen]

| Zone | Model | IP | Zone ID | Description port (2026-11-16) |
|---|---|---|---|---|
| Bar | p4300 | 10.0.0.109 | memberId-0025ed1e013e | 42431 |
| Family Room | p4300 | 10.0.0.197 | memberId-0025ed1dfe08 | 43676 |
| Gym | p4300 | 10.0.0.207 | memberId-0025ed1dfe12 | 37725 |
| Sound Bar | p500 | 10.0.0.91 | memberId-0025ed1e2a55 | 44242 |

- All four are on firmware 2025.0 and share SystemID `nuvoCSRJnoZYu81NO7dz`.
  The P4300 had no network presence at all while it was unplugged, and
  rejoined the system by itself once powered.
- One NV-P4300 chassis is three zones. Each has its own IP, MAC and UPnP
  server; nothing on the wire ties them to one box except the model name.
- 10.0.0.48 is an NV-GW100 wireless gateway, not a player (libupnp 1.3.1,
  port 49152, one service `GatewayConfig:1` with only `StartWpsPbc` and
  `GetSystemId`). Nothing to control there.
- IPs and ports above are a snapshot. Ports change on reboot; never hardcode.

---

## 2. Identity and addressing

- Every zone is its own UPnP root device, even on a multi-zone amp.
- Device type: `urn:schemas-nuvotechnologies-com:device:Zone:1`.
- UDN: `uuid:00000000-0000-0000-0000-<mac>`. Stable across reboots and IP
  changes, so NuvoKit uses it as `Zone.id`.
- Zone ID (called MemberID): `memberId-<mac, lowercase, no colons>`. This is
  the identifier grouping actions take.
- **Never derive a zone ID from a network address.** The Sound Bar's ARP
  entry is `00:25:ed:9e:2a:55` but its zone ID is `memberId-0025ed1e2a55`
  (one bit apart: Wi-Fi vs Ethernet MAC). Read it from `Zone.Get`. **[seen]**
- The UPnP HTTP port is ephemeral and changes when the player reboots. The
  description URL is `http://<ip>:<port>/<udn without "uuid:">.xml`.
- Each zone also serves a web UI on port 80 (`http://<ip>/home.fcgi`) and has
  TCP 4747 open (section 12).

---

## 3. Layer 1: discovery (SSDP)

### On the wire

The client sends one UDP datagram to `239.255.255.250:1900`:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 2
ST: urn:schemas-nuvotechnologies-com:device:Zone:1
```

Each zone answers with a unicast datagram **[seen]**:

```
HTTP/1.1 200 OK
Location: http://10.0.0.91:44242/00000000-0000-0000-0000-0025ed1e2a55.xml
USN: uuid:00000000-0000-0000-0000-0025ed1e2a55::urn:schemas-nuvotechnologies-com:device:Zone:1
Server: Linux/2.6.37 UPnP/1.0 GUPnP/0.20.8
Cache-Control: max-age=100
ST: urn:schemas-nuvotechnologies-com:device:Zone:1
```

`Location` is the only field that matters: it points at the device
description.

### The device description

A GET of the `Location` URL returns an XML document listing the device and
its services. The zone device embeds a MediaRenderer and a MediaServer, so
the services are spread over three nested `<device>` elements **[seen]**:

| Service type | Control URL | Lives under |
|---|---|---|
| `urn:schemas-nuvotechnologies-com:service:Zone:1` | `/ZoneService/control` | Zone (root) |
| `urn:schemas-upnp-org:service:AVTransport:1` | `/AVTransport/control` | MediaRenderer |
| `urn:schemas-upnp-org:service:RenderingControl:1` | `/RenderingControl/control` | MediaRenderer |
| `urn:schemas-upnp-org:service:ConnectionManager:1` | `/ConnectionManager-MR/control` | MediaRenderer |
| `urn:schemas-upnp-org:service:ContentDirectory:1` | `/ContentDirectory/control` | MediaServer |
| `urn:schemas-upnp-org:service:ConnectionManager:1` | `/ConnectionManager-MS/control` | MediaServer |

Event URLs are the same paths ending in `/event`. URLs in the document are
relative to the description URL. Each service also has an SCPD document (its
formal list of actions and state variables); copies are in
`captures/scpd_*.xml`.

The description contains the device serial number. That serial is the login
secret for the port-80 API (section 12), so `tools/probe.py` redacts it
before saving. Do not commit an unredacted description.

### In NuvoKit

- `SSDP.search` opens a plain BSD UDP socket (multicast TTL 2, 250 ms receive
  timeout) and runs 2 rounds of 2.5 s by default. Each round sends the
  M-SEARCH to the multicast group and to every address in `unicastHosts`.
  Replies are de-duplicated on `USN + Location`.
- Unicast probing exists because SSDP is lossy, multicast does not cross
  VLANs, and iOS needs a special entitlement for multicast.
- **Nothing populates the unicast list automatically.** It is only ever what
  a caller hands in, and there are two sources:
  - `NuvoSystem.discover()` passes `NuvoSystem.knownHosts` (via
    `NuvoDiscovery.zoneLocations(knownHosts:)`). That is a public property
    that defaults to empty. The app never sets it and has no UI for it, so
    **the app discovers by multicast only**.
  - `nuvoctl discover [host ...]` passes the IPs given on the command line
    straight to `SSDP.search`. Every other `nuvoctl` command passes none.
- Addresses of zones already found are not fed back in, and nothing is
  persisted between launches. A zone that never answers multicast is
  therefore invisible to the app today. Once found, a zone stays in
  `NuvoSystem.zones` even if later searches miss it.
- `NuvoDiscovery.zoneLocations` keeps only replies whose `ST` is the zone
  device type and returns their `Location` URLs.
- `DeviceDescription.fetch` downloads and parses the document, collecting
  every `<service>` at any depth and resolving its URLs against `Location`.
- `ZoneClient.connect(location:)` requires the Zone, AVTransport,
  RenderingControl and ContentDirectory services and throws
  `UPnPError.missingService` if one is absent. ConnectionManager is unused.

### mDNS (not used by NuvoKit) [seen]

Zones also advertise `_nuvoplayer._tcp` on port 4747 (TXT `httpPort=80`), and
the zone acting as system master advertises `_nuvomaster._tcp` on port 80.
The Sound Bar's hostname is `nu-0025ed1e2a55.local`; on 2026-11-16 it was the
one advertising `_nuvomaster._tcp`, along with Spotify Connect. This would be the
entitlement-free discovery path on iOS, but it gives the port-80 address, not
the UPnP port, so an SSDP unicast probe is still needed afterwards.

---

## 4. Layer 2: control (SOAP over HTTP)

### On the wire

Every command or query is one HTTP POST to a service's control URL. The
action is named twice: in the `SOAPACTION` header and as the body element.

```
POST /ZoneService/control HTTP/1.1
Host: 10.0.0.91:44242
Content-Type: text/xml; charset="utf-8"
SOAPACTION: "urn:schemas-nuvotechnologies-com:service:Zone:1#Get"

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:Get xmlns:u="urn:schemas-nuvotechnologies-com:service:Zone:1"></u:Get></s:Body>
</s:Envelope>
```

Input arguments are child elements of the action element, in the order the
SCPD declares them. The reply is HTTP 200 with an `<ActionName>Response`
element whose children are the output arguments **[seen]**:

```xml
<s:Envelope ...><s:Body>
<u:GetResponse xmlns:u="urn:schemas-nuvotechnologies-com:service:Zone:1">
  <FirmwareVersion>2025.0</FirmwareVersion>
  <SystemID>nuvoCSRJnoZYu81NO7dz</SystemID>
  <MemberID>memberId-0025ed1e2a55</MemberID>
  <Title>Sound Bar</Title>
  <Icon>skin:iconSoundbarToslink</Icon>
  <Active>1</Active><Connecting>0</Connecting>
  <MasterGroup>{&quot;id&quot;:&quot;&quot;,&quot;sortKey&quot;:&quot;00000001789611513993&quot;}</MasterGroup>
  <MemberGroup>{&quot;id&quot;:&quot;&quot;,&quot;sortKey&quot;:&quot;00000001789611514033&quot;}</MemberGroup>
  <Model>p500</Model><AudioInput>toslink</AudioInput><PowerState>standby</PowerState>
</u:GetResponse></s:Body></s:Envelope>
```

Errors are HTTP 500 with a SOAP fault carrying a UPnP error code and text.
The shape (the description text varies):

```xml
<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
  <errorCode>501</errorCode><errorDescription>Action Failed</errorDescription>
</UPnPError></detail></s:Fault>
```

Some requests get no answer at all and simply time out (section 9).

### Values are often nested documents

An argument value is always a string, but that string is frequently another
document that has been XML-escaped:

1. SOAP envelope (XML)
2. inside it, a DIDL-Lite document (XML, escaped) for anything describing
   media: browse results, now-playing metadata, play requests
3. inside that, an `x:x_nuvo_nsdk` element holding a JSON object (escaped
   again)

Group fields skip step 2: `MasterGroup` and `MemberGroup` are JSON strings
directly inside the SOAP XML. Section 7 covers the formats.

### In NuvoKit

- `SOAPClient` owns one ephemeral `URLSession` (8 s request timeout, at most
  4 connections per host). The same session is reused for GENA requests.
- `SOAPClient.envelope` builds the body, XML-escaping every argument value.
  That escaping is what turns a DIDL string into the nested form above.
- `SOAPClient.parseResponse` returns the output arguments as
  `[String: String]`. A `<Fault>` anywhere in the reply becomes a thrown
  `SOAPFault(httpStatus, code, detail)`; a reply with no
  `<ActionName>Response` element throws `UPnPError.badResponse`.
- `XMLNode` is a small tree over Foundation's `XMLParser` with namespace
  processing on, so element names are local names (`dc:title` is `title`).
  XML entity decoding happens here, which is how one parse peels one layer.

---

## 5. Layer 3: eventing (GENA)

Polling six actions per zone would be slow and laggy, so UPnP lets a client
register an HTTP callback and have the device push changes.

### On the wire

Subscribe, one request per service, to the service's event URL (the callback
address here is an example):

```
SUBSCRIBE /RenderingControl/event HTTP/1.1
CALLBACK: <http://10.0.0.20:51234/event>
NT: upnp:event
TIMEOUT: Second-300
```

The reply carries `SID: uuid:...` (the subscription ID) and the granted
`TIMEOUT`. Renewal is the same method with `SID` and `TIMEOUT` and no
`CALLBACK`/`NT`. `UNSUBSCRIBE` with the `SID` ends it; otherwise it expires
on its own.

The zone then connects to the callback URL and sends `NOTIFY` requests with
the `SID` header and a property set as the body:

```xml
<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
  <e:property><Title>Sound Bar</Title></e:property>
  <e:property><PowerState>active</PowerState></e:property>
</e:propertyset>
```

Two shapes of payload exist:

- **Zone service:** each state variable is its own property, as above.
- **AVTransport and RenderingControl:** everything is wrapped in a single
  property called `LastChange`, whose value is an escaped XML document with
  values in `val` attributes:

  ```xml
  <Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/"><InstanceID val="0">
    <Volume channel="Master" val="28"/><Mute channel="Master" val="FALSE"/>
  </InstanceID></Event>
  ```

  The raw NOTIFY bytes have not been saved to `captures/` (`nuvoctl watch`
  prints decoded values), so these two examples show the standard shape that
  `GENAParser` decodes successfully, with illustrative values.

Behaviour **[seen]**:

- GENA works on all four zones and all three services (12 subscriptions).
- Each new subscription first delivers a full dump of current state, then
  only deltas.
- RenderingControl sends `Volume` and `VolumeDB` on every step of a drag.
- In events, `Mute` and `Loudness` arrive as `TRUE`/`FALSE`. The SOAP read
  `GetMute` returns `0`/`1`. `ZoneClient.bool` accepts both forms.
- Track metadata is pushed: an AVTransport `LastChange` carries
  `CurrentTrackMetaData`, `X_NUVO_Info` and `X_NUVO_Context`, all DIDL.
- `Zone.Get` can lag 1-2 s behind a grouping change **[public]**; events are
  the more current source.

Evented variables per service (from the SCPDs):

| Service | Evented state |
|---|---|
| Zone | FirmwareVersion, APIVersion, SystemID, MemberID, Title, Icon, HttpPort, Active, Connecting, UpdateState, MasterGroup, MemberGroup, UpdateURL, WirelessSupported, Language, Model, AudioInput, PowerState, CompatibleDevices |
| AVTransport | LastChange (TransportState, CurrentTransportActions, AVTransportURI, AVTransportURIMetaData, CurrentTrackURI, CurrentTrackMetaData, X_NUVO_Info, X_NUVO_Context, X_NUVO_Rating, X_NUVO_ExtraInfo, X_NUVO_MatchingAVTransportURIs, ...) |
| RenderingControl | LastChange (Volume, VolumeDB, Mute, Loudness) |
| ContentDirectory | SystemUpdateID, ContainerUpdateIDs, TransferIDs (not subscribed) |

### In NuvoKit

- `EventServer` is a minimal HTTP server on `NWListener`, bound to an
  OS-assigned TCP port. It accumulates bytes until `HTTPRequest.parse` sees a
  complete head plus `Content-Length` bytes of body, answers
  `200 OK` / `Connection: close`, and forwards `NOTIFY` requests that have a
  `SID` as `UPnPEvent(sid, properties)`. Anything over 1 MB is dropped.
- `LocalAddress.ipv4(toReach:)` finds which local IP the zone can call back
  on by `connect()`ing a UDP socket to the zone (sends nothing) and reading
  the socket's own address. The callback URL is
  `http://<that ip>:<port>/event`.
- `GENA.subscribe / renew / unsubscribe` send the requests above with a
  300 s timeout. Unsubscribe is best effort with a 2 s timeout.
- `GENAParser.properties` flattens a property set; `GENAParser.lastChange`
  flattens a `LastChange` document, preferring the `Master` channel when a
  variable appears for several channels.
- `NuvoSystem` keeps a table `SID -> (zone, service type, renew time)`. An
  incoming event is routed by SID to `Zone.apply(_:from:)`. Subscriptions
  are renewed at half their timeout. If any of a zone's three subscriptions
  is missing, `zone.hasLiveUpdates` is false and the zone is polled instead
  while NuvoKit drops and re-creates all three.
- If the event server cannot start, nothing breaks: state stays current by
  polling, just less promptly.

---

## 6. Layer 4: the services and their actions

Action lists are from the Sound Bar's SCPDs **[seen]**. "Used" means NuvoKit
sends it.

### Zone (`urn:schemas-nuvotechnologies-com:service:Zone:1`)

| Action | Arguments -> result | Used |
|---|---|---|
| `Get` | -> FirmwareVersion, SystemID, MemberID, Title, Icon, Active, Connecting, MasterGroup, MemberGroup, Model, AudioInput, PowerState | yes |
| `GroupCreate` | `memberIDs` (JSON array of zone IDs) -> `groupID` | yes |
| `GroupDisband` | `groupID` | yes |
| `GroupMemberSetGroup` | `memberIDs` (JSON array), `groupID` (empty = leave) | yes |
| `GetActive`, `GetConnecting`, `GetUpdateState`, `GetFirmwareVersion`, `GetMemberID`, `GetSystemID` | single-value reads | no |
| `UserTap`, `UserDoubleTap` | **[unknown]** | no |
| `SystemCreate`, `SystemJoin`, `SystemConfigureGWs`, `RestoreFactoryDefaults` | re-home or wipe the player | **blocked** |

### RenderingControl

All take `InstanceID=0` and, for volume and mute, `Channel=Master`.

| Action | Notes | Used |
|---|---|---|
| `GetVolume` / `SetVolume` | 0-100, `DesiredVolume`; result `CurrentVolume` | yes |
| `GetMute` / `SetMute` | `DesiredMute` 1/0; result `CurrentMute` | yes |
| `X_NUVO_AdjustVolume` | signed delta **[public]** | no |
| `GetVolumeDB` / `SetVolumeDB`, `GetLoudness` / `SetLoudness`, `ListPresets` | | no |
| `SelectPreset` | its only preset is FactoryDefaults | **blocked** |

Volume is per zone. Zones in a group keep separate volumes.

### AVTransport

All take `InstanceID=0`.

| Action | Notes | Used |
|---|---|---|
| `GetTransportInfo` | -> `CurrentTransportState` | yes |
| `GetCurrentTransportActions` | -> `Actions`, comma-separated | yes |
| `GetPositionInfo` | -> `TrackMetaData` (DIDL) among others | yes |
| `GetMediaInfo` | -> `CurrentURIMetaData` (DIDL); fallback for now-playing | yes |
| `Play` (`Speed=1`), `Pause`, `Stop`, `Next`, `Previous` | | yes |
| `X_NUVO_Like`, `X_NUVO_Dislike` | only when listed in the current actions | yes |
| `X_NUVO_PlayContainerURI` | the one request that starts any source (section 9) | yes |
| `X_NUVO_PlayURI`, `X_NUVO_TogglePause`, `X_NUVO_PauseOrStop`, `X_NUVO_BeginPrevious` | | no |
| `Seek`, `SetPlayMode`, `GetDeviceCapabilities`, `GetTransportSettings` | | no |
| `SetAVTransportURI` | hazard, see section 13 | no |

Transport states: `STOPPED`, `PLAYING`, `TRANSITIONING`, `PAUSED_PLAYBACK`,
`NO_MEDIA_PRESENT`.

`GetCurrentTransportActions` is the source of truth for which buttons make
sense, and it varies by source **[seen]**:

| Source | Actions |
|---|---|
| SiriusXM live | Play, Stop |
| Pandora | Next, Pause, Play, Stop, X_NUVO_Like, X_NUVO_Dislike (no Previous) |
| TuneIn (as last seen on Sound Bar) | Play, Stop |
| Idle | none |

### ContentDirectory

| Action | Notes | Used |
|---|---|---|
| `Browse` | standard listing; works for some IDs | yes (line-in, fallback) |
| `X_NUVO_Browse` | what the official app uses; adds `ContainerProperties` | yes |
| `X_NUVO_Browse2` | returns a `ResultEncrypted` flag **[unknown]** | no |
| `X_NUVO_Action(ObjectID)`, `X_NUVO_Action2(ObjectID, GroupID, MetaData, ParentMetaData, Index, Context...)` -> Result, Events | looks like "invoke this menu row" | no |
| `X_NUVO_AddChild`, `X_NUVO_MoveChild`, `X_NUVO_RemoveChild`, `X_NUVO_ClearChildren` | list editing, presumably queue/favorites | no |
| `X_NUVO_GetQueryID(ObjectID, Query)` | search | no |
| `X_NUVO_CreateSubscribeQueue`, `X_NUVO_Subscribe(QueueID, ObjectID, Type)`, `X_NUVO_Unsubscribe`, `X_NUVO_ReadSubscribeQueue(QueueID)` | a second, polled event channel; Type is `rows` or `item` | no |
| `GetSearchCapabilities`, `GetSortCapabilities`, `GetSystemUpdateID`, `UpdateObject` | | no |

Reading of the unused half: the official app's UI is server-driven. The
player hands out a tree of menu rows; the app browses it, invokes rows with
`Action2`, and watches rows through a subscribe queue. A faithful clone is
mostly a generic renderer for that tree.

### ConnectionManager (two instances)

Standard, mostly unimplemented on the device **[public]**. Unused.

---

## 7. Layer 5: data formats

### Group JSON

`MasterGroup` and `MemberGroup` are JSON objects:

```json
{"id":"gidO1p1DFsnw9h8p9YL","sortKey":"00000001794876909021"}
```

`id` is empty when there is no group. `sortKey` is a zero-padded epoch
timestamp in milliseconds of the last change; NuvoKit uses the MemberGroup
sort key to order followers by when they joined.

### DIDL-Lite

The XML dialect UPnP uses to describe media. A document is a `<DIDL-Lite>`
root holding `<item>` (playable or informational row) and `<container>`
(folder) elements. Nuvo's namespaces:

```
xmlns      = urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/
xmlns:dc   = http://purl.org/dc/elements/1.1/
xmlns:upnp = urn:schemas-upnp-org:metadata-1-0/upnp/
xmlns:x    = urn:schemas.nuvotechnologies.com
```

A real row (the Sound Bar's optical input) **[seen]**. Shown unescaped, with
the nsdk JSON shortened; the full text is in
`captures/browse_lineIn_systemLineIns.xml`:

```xml
<item id="nuvoremote:memberId-0025ed1e2a55/lineIn_memberId-0025ed1e2a55"
      parentID="lineIn:systemLineIns" restricted="1">
  <dc:title>Optical</dc:title>
  <dc:creator>lineIn</dc:creator>
  <res protocolInfo="nuvo:*:*:*">nuvo:nuvoremote:memberId-0025ed1e2a55/lineIn_memberId-0025ed1e2a55</res>
  <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>
  <dc:description>Sound Bar</dc:description>
  <upnp:icon>skin:iconLineIn</upnp:icon>
  <x:x_nuvo_disabled>1</x:x_nuvo_disabled>
  <x:x_nuvo_itemId>memberId-0025ed1e2a55</x:x_nuvo_itemId>
  <x:x_nuvo_nsdk>{"mediaData":{"metaData":{"playLogicPath":"...","serviceID":"lineIn"}},
                  "title":"Optical","type":"audio","disabled":true,"sortKey":"1", ...}</x:x_nuvo_nsdk>
</item>
```

Field meanings:

| Element | Meaning |
|---|---|
| `id` attribute | the object ID to browse into (containers) |
| `res` | the playable URI, scheme `nuvo:`. **No `res` means not playable** (footers, placeholders, info rows) |
| `dc:title` | row label, or headline of what is playing |
| `dc:creator` | the **service ID** (`lineIn`, `siriusxm2`, `tuneIn`), not an artist |
| `dc:description`, `upnp:longDescription` | secondary text; meaning depends on the service |
| `upnp:icon` / `upnp:albumArtURI` | art URL, or `skin:<name>` for art built into the official app |
| `x:x_nuvo_nsdk` | JSON row model the official app renders: `title`, `path`, `icon`, `type`, `sortKey`, `disabled`, `mediaData.metaData.playLogicPath` (e.g. `siriusxm2:playback/playLogic`), ... |
| `x:x_nuvo_context` | path of the row's context menu |
| `x:x_nuvo_disabled` | `1` when the player reports the row unavailable |

Row types seen in the nsdk JSON `type`: `container`, `audio`, `footer`,
`spacer`, `action`, `www`.

### Now-playing metadata by source [seen]

| Field | SiriusXM | Pandora | TuneIn |
|---|---|---|---|
| `dc:title` | station ("Ch 9 - 90s on 9") | song ("Doin' Time") | station |
| `dc:description` | song and year ("Slide (98)") | album and artist | |
| `upnp:longDescription` | "artist - album" | | |
| `upnp:artist` | absent | artist ("311") | |
| `dc:creator` | `siriusxm2` | `pandora` | `tuneIn` |
| `upnp:icon` | art URL over plain http | | |

- On radio, song changes arrive as a new `CurrentTrackMetaData` event while
  the URI stays constant. The station logo is sent first, then replaced by
  album art once known.
- When the official app plays a SiriusXM channel, `AVTransportURIMetaData`
  holds the channel item itself, not its parent folder.

### In NuvoKit (`Models.swift`)

- `ZoneInfo(response:)` maps `Zone.Get` output and decodes the group JSON.
- `MediaEntry.parse(didl:firstIndex:)` turns a listing into rows.
  `isPlayable` is true for a non-container with a `res` whose row type is
  absent or `audio`.
- `DIDL.track(from:)` builds `TrackInfo` for now-playing. `service` is
  `dc:creator`; `detail` and `longDetail` are passed through uninterpreted
  because their meaning varies by source.
- **Rows are kept as raw substrings.** `DIDL.rawElements` cuts each
  `<item>`/`<container>` out of the listing untouched, and play requests
  send that text back wrapped in a fresh `<DIDL-Lite>` root. The player
  expects its own metadata back byte for byte, embedded JSON and entities
  included, so NuvoKit never re-serialises a row.
- `DIDL.artworkURL` drops `skin:` icons, and upgrades `http` to `https` for
  named hosts because App Transport Security blocks plain http. Hosts given
  as an IP (local players) are left on http.

---

## 8. Behaviour model

### On and off are group membership

There is no power switch. **[seen]**

- Each zone has a **MasterGroup** (a group it hosts) and a **MemberGroup**
  (the group it is listening to).
- **A zone is on exactly when its MemberGroup ID is non-empty.**
- A zone can host a group it is not in: idle Bar and Gym showed a non-empty
  MasterGroup with an empty MemberGroup. Only MemberGroup means "on".
- `PowerState` is not on/off. Idle P4300 zones report `active`; the idle
  P500 reports `standby` and switches to `active` when it joins a group,
  back to `standby` when it leaves. (`learning` also exists per the code
  comments; not observed.)
- `AudioInput` (`player` and `toslink` observed; `rca` per the code
  comments) tracks what the input jack currently detects, not a setting. The Sound Bar read `toslink`, then
  `player` once the optical source went quiet.

| Goal | Request | Sent to |
|---|---|---|
| Turn a zone on | `GroupCreate(memberIDs=["<its id>"])`, then a play request | the zone |
| Add a zone to a group | `GroupMemberSetGroup(memberIDs=["<its id>"], groupID=<group>)` | the group's master |
| Remove a follower | `GroupMemberSetGroup(memberIDs=["<its id>"], groupID="")` | the follower |
| Turn off a master (ends the group for everyone) | `GroupDisband(groupID)` | the master |

Of these, the follower leave is confirmed by capture (`leave-test.txt`): it
removed only that zone and the leader kept playing. The other three are what
NuvoKit sends, following the public notes; no capture in this repo records
each of them individually.

### Playback belongs to the group master

- In a group, the master has `MasterGroup == MemberGroup`. A follower has
  `MemberGroup` = the master's group ID.
- Transport commands and play requests go to the master. Sent there, a
  source change switches every zone in the group.
- **A follower's own AVTransport is not meaningful.** It has been seen
  reporting `NO_MEDIA_PRESENT`, and on another occasion `PLAYING` with its
  own previous TuneIn station, both while following a Pandora group and
  after going idle. For any zone that is not a group leader, transport state
  and metadata are leftovers. Playback truth = MemberGroup + the leader's
  transport.
- Idle zones drop out of their group after an inactivity timeout
  **[public]**.

### Timing

- A player accepts a transport command before its reported state changes.
  Starting a stream goes `TRANSITIONING` -> `PLAYING`; stopping goes to
  `STOPPED`.
- Group changes take a second or two to show up in what zones report.

---

## 9. Browsing and playing sources

### Object IDs

Everything browsable is addressed by an object ID string. Results below are
from standard `Browse` on an idle P4300 unless noted **[seen]**:

| Object ID | Result |
|---|---|
| `pandora:` | 52 rows: folder "New Genre Station" + 51 stations (`pandora:StationList/station_<n>`, URI `nuvo:pandora:...`). Canonical ID is `pandora:StationList`. |
| `tunein:` | 8 folders (My Favorites, Local Radio, Music, Talk, Sports, By Location, By Language, Podcasts). Child IDs are `tunein:browse/uri/Browse.ashx?...` |
| `siriusxm2:ui/root` | All Channels, Favorites, Recents, For You (see below). Reports its own ID as `siriusxm2:ui/browse`. |
| `lineIn:systemLineIns` (also `/stable/lineIn/`) | one row per detected line input across the whole system, plus a footer |
| `spotify:` | 4 informational rows (Spotify Connect) |
| `alexa:` | 1 informational row |
| `sirius:`, `napster:`, `deezer:` | "not configured" plus a "Fix it!" row of type `action` |
| `0` | no rows; `X_NUVO_Browse` returns `ContainerProperties` describing an empty container. The home menu is not here **[unknown]** |
| `siriusxm2:`, `top10:`, `bluetooth:`, `/`, `/stable/` | 501 "Node at path '...' does not exist" |
| `iheart:`, `rhapsody:`, `amazon:`, `favorites:`, `presets:`, `playHistory:`, `usb:`, `library:`, `airplay2:`, `testStreams:`, `ui:`, `nuvo:`, `sxZone:` | no answer (timed out at 5 s) |

SiriusXM menu:

| Row | ID |
|---|---|
| All Channels | `siriusxm2:ui/carousel?primary=App:carousel:channels_all` |
| Favorites | `siriusxm2:ui/carousel?primary=App:carousel:favorites_everest` |
| Recents | `siriusxm2:ui/carousel?primary=App:carousel:recents` |
| For You | `siriusxm2:ui/root/forYou` |

A channel's URI looks like
`nuvo:siriusxm2:ui/carousel?primary=Api:tune:liveAudio:8206&assetType=channel&channelId=8206&...`.
`siriusxm2:playerMenu` is the now-playing context menu ("Sleep Timer" =
`nuvoUIMenu:sleepTimer`, "Save to Top 10" = `top10:saveTo`).

Three distinct failure modes:

1. **501 "Node at path ... does not exist"**: no such node.
2. **Timeout**: probably a provider that exists whose bare root is not a
   browsable node.
3. **501 "Service is currently unavailable. Try again later."**: the node
   exists but the upstream request failed (seen on `siriusxm2:ui/carousel`
   with no or an unknown query).

### Browse vs X_NUVO_Browse

Both take `ObjectID`, `BrowseFlag=BrowseDirectChildren`, `Filter=*`,
`StartingIndex` (0-based) and `RequestedCount`, and return `Result` (DIDL),
`NumberReturned`, `TotalMatches`, `UpdateID`.

- Standard `Browse` also takes `SortCriteria` (sent empty).
- `X_NUVO_Browse` instead takes `SubscribeQueueID` and `Arguments` (both
  sent empty; meaning **[unknown]**) and additionally returns
  **`ContainerProperties`**: a DIDL document describing the folder itself.

`ContainerProperties` for `pandora:` **[seen]**: ID `pandora:StationList`,
title "Pandora", icon `skin:iconPandora`, `x:x_nuvo_activity` 1 (nsdk
`"activity": true`; meaning unknown), and a child
`<x:x_nuvo_search id="pandora:searches">` titled "Artist, Track" with class
`object.container.x_nuvo_searchContainer` (nsdk `containerType` `search`).
That child is how a folder advertises that it is searchable.

### The line-in listing is dynamic [seen]

`lineIn:systemLineIns` lists an input only while a player detects something
on the jack. With nothing connected it returns a "No devices" placeholder
(`upnp:class` `object.item`, no `res`) plus the footer. Any zone can play any
zone's input. Filter non-inputs by the absence of `res`.

### The play request

One action starts every source tried so far (line-in, TuneIn, Pandora):
`X_NUVO_PlayContainerURI` on AVTransport, sent to the group master, with
these arguments in order:

| Argument | Value |
|---|---|
| `InstanceID` | `0` |
| `CurrentURI` | empty |
| `CurrentURIMetaData` | DIDL describing the **folder** the row was listed in. Best is the folder's `ContainerProperties`, verbatim |
| `TrackURI` | the row's `res` |
| `TrackURIMetaData` | the row's DIDL, verbatim as the player returned it |
| `StartingIndex` | the row's 1-based position in the full listing (11 for the Pandora station played in `play-pandora.txt`; 1 in the public line-in template) |
| `UpdateID` | `-1` |

The zone must already be in a group, so turning a zone on and playing
something is `GroupCreate` followed by this.

---

## 10. NuvoKit: how the code maps onto the layers

| File | Layer | Role |
|---|---|---|
| `UPnP/XMLNode.swift` | - | XML tree, `xmlEscape` |
| `UPnP/SSDP.swift` | 1 | discovery sockets, `LocalAddress` |
| `UPnP/DeviceDescription.swift` | 1 | description document, `UPnPService` |
| `UPnP/SOAP.swift` | 2 | `SOAPClient`, `SOAPFault`, `UPnPError` |
| `UPnP/Eventing.swift` | 3 | `EventServer`, `GENA`, `GENAParser` |
| `Nuvo/Models.swift` | 4-5 | constants, `NuvoSafety`, `ZoneInfo`, `TrackInfo`, `MediaEntry`, `BrowsePage`, `DIDL` |
| `Nuvo/ZoneClient.swift` | 4 | stateless per-zone API, `NuvoDiscovery` |
| `Nuvo/Zone.swift` | state | observable state of one zone |
| `Nuvo/NuvoSystem.swift` | state | the whole installation: discovery, events, groups, commands |
| `Nuvo/MediaBrowser.swift` | state | navigation state for browsing sources |

Everything under `UPnP/` is generic and knows nothing about Nuvo. NuvoKit has
no third-party dependencies.

### ZoneClient: stateless

One `ZoneClient` per zone, holding the parsed description and a shared
`SOAPClient`. Each public method is one SOAP action (occasionally two) and
nothing is cached.

`ZoneClient.call` is the single path from NuvoKit to a control URL. It checks
`NuvoSafety.isForbidden(action)` first and throws
`UPnPError.forbiddenAction` for `SystemCreate`, `SystemJoin`,
`SystemConfigureGWs`, `RestoreFactoryDefaults`, `SelectPreset` and
`StartWpsPbc`.

`ZoneClient.page(of:start:count:)` tries `X_NUVO_Browse` and falls back to
standard `Browse` only on a `SOAPFault`. Timeouts are not retried, because
both actions hang on the same folders.

### Zone: one zone's live state

`@MainActor @Observable`. Holds `info`, `volume`, `isMuted`, `transport`,
`transportActions`, `nowPlaying`, `isReachable`, `hasLiveUpdates`.

- `refresh()` is the full poll: `Get`, `GetVolume`, `GetMute`,
  `GetTransportInfo`, `GetCurrentTransportActions`, `GetPositionInfo` (and
  `GetMediaInfo` if the first has no usable metadata). Any failure marks the
  zone unreachable.
- `apply(_:from:)` merges a pushed event. After any AVTransport event it
  schedules one full transport read-back 300 ms later, so partial deltas
  cannot leave the three transport fields inconsistent.
- `setVolume` is safe to call on every slider tick: the local value updates
  at once, and network writes are coalesced so only the latest pending value
  is sent. For 1.5 s after a local change, volume reports from the device
  are ignored so the slider does not jump backwards.

### NuvoSystem: the installation

`start()` launches one loop that ticks every 5 s:

| Every | Work |
|---|---|
| first tick, then every 12th tick (60 s), or whenever no zones are known | SSDP discovery |
| every tick | renew due subscriptions; re-subscribe zones without live updates |
| every tick | `refresh()` zones that have no live updates or are unreachable |
| every 6th tick (30 s) | `refresh()` every zone as a safety net; reload line inputs |

Rediscovery is how a rebooted player is picked up: a known UDN at a new
`Location` gets a new `ZoneClient`, its old subscriptions are discarded, and
it is re-subscribed.

Derived state:

- `groups`: zones that are on, bucketed by MemberGroup ID. The leader (the
  member whose MasterGroup ID equals the group ID) comes first, then
  followers by MemberGroup `sortKey`.
- `idleZones`: zones with an empty MemberGroup ID.
- `playbackOwner(of:)`: the group master for a follower, else the zone
  itself. The UI reads transport and now-playing from this.

Commands apply the behaviour model from section 8:

- Transport (`play`, `pause`, `stop`, `next`, `previous`, `like`, `dislike`)
  is redirected to the group master. For play/pause/stop the call does not
  return until the master reports an expected state or 3 s pass, so
  "returned" means "the state on screen is confirmed".
- `togglePlayPause` uses `Pause` if the current actions include it, else
  `Stop` (live radio and line-in cannot pause).
- `play(_:containerDIDL:on:)` and `playLineInput(_:on:)` create a
  single-zone group first if the zone is off, then send the play request to
  the master.
- `turnOff`, `join(_:to:)` map to the group requests in section 8.
- After a group or source change, `settle()` waits 1.5 s and refreshes every
  zone.

### MediaBrowser: browsing state

One per browsing session, for one zone. Holds a `path` of folders and the
`rows` of the current one.

- Starting points are a fixed list because the real home menu has not been
  found: `pandora:`, `siriusxm2:ui/root`, `tunein:`, `lineIn:systemLineIns`.
- Loads the first 30 rows, then continues automatically in pages of 100,
  appending as they arrive. A generation counter discards replies for a
  folder the user has already left.
- For a play request it picks the folder description in this order: the
  player's `ContainerProperties`; the row the folder was opened from; the
  built-in line-in container; a minimal hand-built container.

---

## 11. Interfacing with the system

### From Swift (what the app does)

```swift
let system = NuvoSystem()
system.knownHosts = ["10.0.0.91"]      // optional unicast probes
system.start()                         // discovery, events, refresh loop

// Observe: system.zones, system.groups, system.idleZones, system.errorMessage
// Per zone: zone.name, zone.isOn, zone.volume, zone.isMuted
// Playback: system.playbackOwner(of: zone).transport / .nowPlaying / .transportActions

zone.setVolume(30)
await zone.setMuted(true)
await system.togglePlayPause(zone)
await system.join(zone, to: group)
await system.turnOff(zone)

let browser = MediaBrowser(system: system, zone: zone)
await browser.open(MediaBrowser.sources[0])   // Pandora
await browser.play(browser.rows[10])
```

For one-off scripting without the observable layer, use `ZoneClient`
directly: `NuvoDiscovery.zoneLocations()` then
`ZoneClient.connect(location:)`.

### From the command line (`nuvoctl`)

Read-only:

```
swift run nuvoctl discover [host ...]   # address, port, IDs, services of each zone
swift run nuvoctl status                # playback state of each zone
swift run nuvoctl inputs                # line inputs system-wide
swift run nuvoctl sources [zone]        # probe every known source ID
swift run nuvoctl browse <id> [zone]    # list one menu, e.g. browse "pandora:"
swift run nuvoctl try <id> [<id> ...]   # quick check of many menu addresses
swift run nuvoctl watch [seconds]       # print pushed events (default 120 s)
```

These change the system:

```
swift run nuvoctl volume <zone> <0-100>
swift run nuvoctl mute <zone> on|off
swift run nuvoctl linein <zone> [input]     # turn the zone on, play a line input
swift run nuvoctl play <zone> <id> <row>    # e.g. play Gym "pandora:" "90s Pop"
swift run nuvoctl off <zone>
```

`watch` is the tool for reverse engineering: run it, do something in the
official app, and read what the players push.

### Raw, without NuvoKit

`tools/probe.py [zone-ip]` and `tools/discover.py [known-zone-ip]` are
read-only Python scripts. `probe.py` downloads the description and every
SCPD and calls a handful of read actions; `discover.py` does repeated
multicast SSDP, a unicast sweep of the /24, and mDNS. Both write to
`captures/`.

By hand with curl, once you have the current port from discovery:

```
curl -s http://10.0.0.91:<port>/ZoneService/control \
  -H 'Content-Type: text/xml; charset="utf-8"' \
  -H 'SOAPACTION: "urn:schemas-nuvotechnologies-com:service:Zone:1#Get"' \
  -d '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Get xmlns:u="urn:schemas-nuvotechnologies-com:service:Zone:1"/></s:Body></s:Envelope>'
```

### What is verified, and how

- `swift test` covers parsing and request building only, against three
  captured P500 responses in `Tests/NuvoKitTests/Fixtures` plus hand-written
  samples. No network.
- Everything stateful (discovery, sending, events, grouping, the refresh
  loop) is verified only by running `nuvoctl` or the app against the real
  system. There is no simulated player.

---

## 12. Other interfaces on the players (not used by NuvoKit)

### Port 80 JSON API ("nSDK") [public]

- Login: `POST /api/authenticate` with the base64 of the device serial
  number. The serial is therefore a secret.
- Read: `/api/getData?path=...&roles=value`, `/api/getRows?path=...`
- Write: `/api/setData?...` (settings; treat as risky).
- Holds settings such as turn-on volume, volume step, inactivity timeout.
- tcp/80 is confirmed open on the player **[seen]**; the API itself is
  untested here.

### TCP 4747

Open on the player and advertised over mDNS as `_nuvoplayer._tcp`
**[seen]**. What speaks on it is **[unknown]**.

### Zone service extras [seen]

`APIVersion` is JSON
(`{"userTapAction":{"min":0,"max":1},"api":{"min":15,"max":15},"wifiThirdParty":{"min":0,"max":1}}`).
`CompatibleDevices` lists
`pcDevBuild,dev_board,p100,p200,p300,p400,p500,p3100,p3500,p4300,p600,p5050,p5100,p5200,au7001,au7002`.
`UpdateURL` is `http://<ip>:80/firmwareupdate.fcgi`. Zone icons are
`skin:` names (`skin:iconZoneBar`, `skin:iconSoundbarPlayer`, ...).

### The official app

Its bundle name is "Tesla". Its home tabs, from the App Store screenshot:
SiriusXM, Library, This iPad, Top 10, Napster.

---

## 13. Hazards

- **Never send** `SystemCreate`, `SystemJoin`, `SystemConfigureGWs`,
  `RestoreFactoryDefaults`, `SelectPreset` or (to the gateway) `StartWpsPbc`.
  They re-home, reconfigure or wipe a player. NuvoKit refuses them.
- `SetAVTransportURI` + `Play` with a WAV URL crashed a zone's UPnP process
  **[public]**. NuvoKit never sends `SetAVTransportURI`.
- Port-80 `setData` writes change device settings; untested, avoid.
- Bass, treble and balance can be written but reportedly do nothing audible
  **[public]**.
- The device description and the port-80 login both expose the serial
  number. Keep captures redacted.

---

## 14. Open questions

1. Where is the real home menu? Not at object ID `0`. Until found, source
   starting points are hardcoded.
2. `X_NUVO_Browse` arguments `SubscribeQueueID` and `Arguments`, and all of
   `X_NUVO_Browse2` including what sets `ResultEncrypted`.
3. `X_NUVO_Action` / `X_NUVO_Action2`: needed for `action` rows ("Fix it!"),
   context menus, and probably search.
4. Search: `X_NUVO_GetQueryID` and the `x_nuvo_search` container.
5. Queue and favorites editing (`X_NUVO_AddChild` and friends).
6. The subscribe-queue event channel: when does the official app use it
   instead of GENA?
7. What `x:x_nuvo_activity` means.
8. `UserTap` / `UserDoubleTap` on the Zone service.
9. What speaks on TCP 4747.
10. Group join and leave events have not been captured as they happen, only
    the state before and after.
11. Which other music services still work, given the backend is abandoned.
    Known working: SiriusXM, Pandora, TuneIn, line-in.
12. Is the official "Wireless Audio System API" document obtainable?

---

## 15. Sources

- https://github.com/mattmoo/ha-nuvo-player-portfolio (docs/protocol.md)
- https://github.com/mpdrago/nuvo-zone-keepalive (the line-in play template)
- https://www.legrand.us/c/discontinued-p3100-professional-series-player/p/nvp3100na

Evidence for **[seen]** items, in `captures/`:

| File | What |
|---|---|
| `probe-log.txt`, `desc_*.xml`, `scpd_*.xml`, `soap_*.xml`, `ssdp_*.txt` | first probe of the Sound Bar and gateway |
| `discover-log.txt`, `zone_*.xml`, `browse_lineIn_systemLineIns.xml` | full-network sweep, line-in listing |
| `p4300-first-look.txt` | all four zones online |
| `watch-playback.txt` | first live GENA capture (SiriusXM on Family Room). Metadata values are cut off at 160 characters in this file; `nuvoctl` no longer truncates |
| `status-playing.txt`, `watch-grouping.txt` | grouped playback |
| `sources.txt` | source ID probe |
| `play-pandora.txt` | first playback started by NuvoKit |
| `leave-test.txt` | follower leaving a group; stale follower transport |
| `sxm-try.txt` | SiriusXM menu root |
