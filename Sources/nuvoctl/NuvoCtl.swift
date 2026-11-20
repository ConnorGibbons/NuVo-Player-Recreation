import Foundation
import NuvoKit

/// Command-line access to NuvoKit, for testing against real hardware.
@main
struct NuvoCtl {
    static let usage = """
    usage: nuvoctl <command>

    Read-only:
      discover [host ...]        network identity of each zone: address, port,
                                 IDs, services (optionally also probe these IPs)
      status                     playback state of each zone
      inputs                     line inputs available system-wide
      sources [zone]             probe every known source ID and list what answers
      browse <id> [zone]         list one menu, e.g. browse "pandora:"
      try <id> [<id> ...]        quick check of many menu addresses at once
      watch [seconds]            print pushed events (default 120 s)

    These change the system:
      volume <zone> <0-100>
      mute <zone> on|off
      linein <zone> [input]      turn the zone on and play a line input
      play <zone> <id> <row>     play a row of a menu; <row> is its number or
                                 part of its title, e.g.
                                 play Gym "pandora:" "90s Pop"
      off <zone>                 turn the zone off
    """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            return
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "discover":
                try await discover(hosts: rest)
            case "status":
                try await status(hosts: [], detailed: true)
            case "inputs":
                try await inputs()
            case "sources":
                try await sources(zoneName: rest.first)
            case "try":
                try await tryAddresses(rest)
            case "browse":
                guard let objectID = rest.first else { return print(usage) }
                try await browse(objectID: objectID, zoneName: rest.count > 1 ? rest[1] : nil)
            case "watch":
                try await watch(seconds: Int(rest.first ?? "") ?? 120)
            case "volume":
                guard rest.count == 2, let value = Int(rest[1]) else { return print(usage) }
                let zone = try await find(rest[0])
                try await zone.client.setVolume(value)
                let readBack = try await zone.client.volume()
                print("\(zone.info.title): volume is now \(readBack)")
            case "mute":
                guard rest.count == 2 else { return print(usage) }
                let zone = try await find(rest[0])
                try await zone.client.setMuted(rest[1] == "on")
                let readBack = try await zone.client.isMuted()
                print("\(zone.info.title): muted = \(readBack)")
            case "linein":
                guard let name = rest.first else { return print(usage) }
                try await lineIn(zoneName: name, inputName: rest.count > 1 ? rest[1] : nil)
            case "play":
                guard rest.count == 3 else { return print(usage) }
                try await play(zoneName: rest[0], objectID: rest[1], selector: rest[2])
            case "off":
                guard let name = rest.first else { return print(usage) }
                try await off(zoneName: name)
            default:
                print(usage)
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    struct Found {
        let client: ZoneClient
        let info: ZoneInfo
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func connectAll(hosts: [String] = []) async -> [Found] {
        let locations = await NuvoDiscovery.zoneLocations(knownHosts: hosts)
        var found: [Found] = []
        for location in locations {
            do {
                let client = try await ZoneClient.connect(location: location)
                found.append(Found(client: client, info: try await client.info()))
            } catch {
                print("could not read \(location.absoluteString): \(error)")
            }
        }
        return found.sorted { $0.info.title < $1.info.title }
    }

    static func find(_ name: String) async throws -> Found {
        let zones = await connectAll()
        let matches = zones.filter { $0.info.title.localizedCaseInsensitiveContains(name) }
        guard matches.count == 1 else {
            let names = zones.map { $0.info.title }.joined(separator: ", ")
            throw Failure(description: "\"\(name)\" matched \(matches.count) zones. Zones found: \(names)")
        }
        return matches[0]
    }

    /// Where each zone lives on the network and what it exposes.
    static func discover(hosts: [String]) async throws {
        let responses = await SSDP.search(target: Nuvo.zoneDeviceType, unicastHosts: hosts)
        var seen = Set<URL>()
        for response in responses {
            guard let location = response.location, seen.insert(location).inserted else { continue }
            print(location.absoluteString)
            print("    address     \(response.address), description port \(location.port ?? 80)")
            print("    server      \(response.server ?? "?")")
            do {
                let client = try await ZoneClient.connect(location: location)
                let info = try await client.info()
                let description = client.description
                print("    name        \(info.title)")
                print("    model       \(info.model), firmware \(info.firmware)")
                print("    zone id     \(info.memberID)")
                print("    system id   \(info.systemID)")
                print("    udn         \(description.udn)")
                print("    upnp name   \(description.friendlyName)")
                print("    services")
                for service in description.services {
                    let parts = service.type.split(separator: ":")
                    let shortType = parts.count >= 2 ? String(parts[parts.count - 2]) : service.type
                    let padded = shortType.padding(toLength: 20, withPad: " ", startingAt: 0)
                    print("        \(padded)\(service.controlURL.path)")
                }
            } catch {
                print("    could not read device: \(error)")
            }
            print("")
        }
        if seen.isEmpty {
            print("No zones found.")
        }
    }

    static func status(hosts: [String], detailed: Bool) async throws {
        let zones = await connectAll(hosts: hosts)
        if zones.isEmpty {
            print("No zones found.")
            return
        }
        for zone in zones {
            let info = zone.info
            let host = zone.client.description.location.host ?? "?"
            print("\(info.title)  [\(info.model), fw \(info.firmware)]  \(host)")
            print("    id \(info.memberID)   power \(info.powerState)   input \(info.audioInput)")
            let groupText = info.memberGroupID.isEmpty ? "(none, zone is off)" : info.memberGroupID
            let isMaster = !info.memberGroupID.isEmpty && info.masterGroupID == info.memberGroupID
            let masterText = isMaster ? "  (master)" : ""
            print("    group \(groupText)\(masterText)")
            guard detailed else { continue }
            let volume = try await zone.client.volume()
            let muted = try await zone.client.isMuted()
            let state = try await zone.client.transportState()
            let actionSet = try await zone.client.transportActions()
            let actions = actionSet.sorted().joined(separator: ",")
            let mutedText = muted ? " (muted)" : ""
            print("    volume \(volume)\(mutedText)   transport \(state.rawValue)   actions [\(actions)]")
            if let track = try await zone.client.nowPlaying() {
                var line = "    playing: \(track.title)"
                if let detail = track.detail { line += " | \(detail)" }
                if let longDetail = track.longDetail { line += " | \(longDetail)" }
                if let artist = track.artist { line += " | artist \(artist)" }
                if let service = track.service { line += "  [\(service)]" }
                print(line)
            }
        }
    }

    // MARK: Source exploration (read-only)

    static let standardCandidates = [
        "0", "/", "/stable/", "/stable/lineIn/", "lineIn:systemLineIns",
        "siriusxm2:", "sirius:", "sxZone:", "tunein:", "pandora:", "spotify:", "iheart:",
        "rhapsody:", "napster:", "deezer:", "amazon:", "alexa:", "top10:",
        "favorites:", "presets:", "playHistory:", "usb:", "library:", "bluetooth:",
        "airplay2:", "testStreams:", "ui:", "nuvo:",
    ]

    static let nuvoCandidates = ["0", "", "/", "/stable/", "ui:", "nuvo:", "siriusxm2:", "favorites:", "presets:"]

    /// A client with a short timeout, so IDs that never answer do not stall the probe.
    static func probeClient(zoneName: String?) async throws -> (ZoneClient, ZoneInfo) {
        let found: Found
        if let zoneName {
            found = try await find(zoneName)
        } else {
            found = try await firstZone()
        }
        let client = try await ZoneClient.connect(location: found.client.description.location,
                                                  soap: SOAPClient(timeout: 5))
        return (client, found.info)
    }

    static func firstZone() async throws -> Found {
        guard let zone = await connectAll().first else {
            throw Failure(description: "No zones found.")
        }
        return zone
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "timed out"
        }
        return String(describing: error)
    }

    static func printEntries(_ entries: [MediaEntry], limit: Int) {
        for entry in entries.prefix(limit) {
            let kind = entry.isContainer ? "[folder]" : (entry.isPlayable ? "[play]  " : "[item]  ")
            let rowType = entry.rowType.map { " type=\($0)" } ?? ""
            let number = String(entry.index).padding(toLength: 4, withPad: " ", startingAt: 0)
            print("  \(number)\(kind) \(entry.title)\(rowType)")
            if !entry.id.isEmpty {
                print("               id  \(entry.id)")
            }
            if let uri = entry.uri {
                print("               uri \(uri)")
            }
        }
        if entries.count > limit {
            print("      ... and \(entries.count - limit) more")
        }
    }

    static func sources(zoneName: String?) async throws {
        let (client, info) = try await probeClient(zoneName: zoneName)
        print("Asking \(info.title) (\(info.model)).")
        print("")
        print("== Standard Browse ==")
        for objectID in standardCandidates {
            let label = objectID.padding(toLength: 24, withPad: " ", startingAt: 0)
            do {
                let entries = try await client.entries(in: objectID)
                print("\(label) \(entries.count) row(s)")
                printEntries(entries, limit: 15)
            } catch {
                print("\(label) FAILED: \(describe(error))")
            }
        }
        print("")
        print("== X_NUVO_Browse ==")
        for objectID in nuvoCandidates {
            let shown = objectID.isEmpty ? "(empty)" : objectID
            let label = shown.padding(toLength: 24, withPad: " ", startingAt: 0)
            do {
                let response = try await client.nuvoBrowse(objectID: objectID)
                let entries = MediaEntry.parse(didl: response["Result"] ?? "")
                let total = response["TotalMatches"] ?? "?"
                print("\(label) \(entries.count) row(s), TotalMatches \(total)")
                let properties = (response["ContainerProperties"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !properties.isEmpty {
                    print("      properties: \(properties)")
                }
                printEntries(entries, limit: 25)
            } catch {
                print("\(label) FAILED: \(describe(error))")
            }
        }
    }

    /// Checks many menu addresses quickly. Read-only. "does not exist" comes
    /// back at once; an address that hangs is abandoned after 6 seconds.
    static func tryAddresses(_ objectIDs: [String]) async throws {
        let found = try await firstZone()
        let client = try await ZoneClient.connect(location: found.client.description.location,
                                                  soap: SOAPClient(timeout: 6))
        print("Asking \(found.info.title).")
        for objectID in objectIDs {
            do {
                let page = try await client.page(of: objectID)
                let folderTitle = page.folder?.title ?? ""
                let folderID = page.folder?.id ?? ""
                print("")
                print("FOUND  \(objectID)  ->  \(page.entries.count) row(s) of \(page.totalMatches)  folder \"\(folderTitle)\" \(folderID)")
                printEntries(page.entries, limit: 40)
            } catch {
                print("no     \(objectID)  (\(describe(error)))")
            }
        }
    }

    static func browse(objectID: String, zoneName: String?) async throws {
        let (client, info) = try await probeClient(zoneName: zoneName)
        print("Asking \(info.title) for \(objectID)")

        print("")
        print("== 1. Standard Browse ==")
        var standardRows: [MediaEntry] = []
        do {
            let raw = try await client.browse(objectID: objectID)
            standardRows = MediaEntry.parse(didl: raw)
            print("\(standardRows.count) row(s)")
            printEntries(standardRows, limit: 200)
            if standardRows.isEmpty {
                print(raw)
            }
        } catch {
            print("FAILED: \(describe(error))")
        }

        print("")
        print("== 2. X_NUVO_Browse (the official app's action) ==")
        do {
            let response = try await client.nuvoBrowse(objectID: objectID)
            let rows = MediaEntry.parse(didl: response["Result"] ?? "")
            print("\(rows.count) row(s), TotalMatches \(response["TotalMatches"] ?? "?")")
            if rows == standardRows {
                print("(rows are identical to the standard listing above)")
            } else {
                printEntries(rows, limit: 200)
            }
            let properties = (response["ContainerProperties"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !properties.isEmpty {
                print("")
                print("-- the folder's own description (ContainerProperties) --")
                print(properties)
            }
        } catch {
            print("FAILED: \(describe(error))")
        }
    }

    static func inputs() async throws {
        guard let zone = await connectAll().first else {
            print("No zones found.")
            return
        }
        let raw = try await zone.client.browse(objectID: Nuvo.lineInContainer)
        let inputs = try await zone.client.lineInputs()
        print("\(inputs.count) input(s) parsed from \(raw.count) characters of DIDL, asked via \(zone.info.title)")
        if inputs.isEmpty {
            print("--- raw response ---")
            print(raw)
        }
        for input in inputs {
            let note = input.isDisabled ? "  (nothing connected)" : ""
            print("\(input.index). \(input.title) on \(input.ownerName)\(note)")
            print("     \(input.uri)")
        }
    }

    static func lineIn(zoneName: String, inputName: String?) async throws {
        let zone = try await find(zoneName)
        let inputs = try await zone.client.lineInputs()
        let wanted = inputName ?? zone.info.title
        guard let input = inputs.first(where: {
            $0.title.localizedCaseInsensitiveContains(wanted) || $0.ownerName.localizedCaseInsensitiveContains(wanted)
        }) else {
            throw Failure(description: "no line input matching \"\(wanted)\". Run `nuvoctl inputs`.")
        }
        if zone.info.memberGroupID.isEmpty {
            let groupID = try await zone.client.createGroup(memberIDs: [zone.info.memberID])
            print("created group \(groupID)")
        }
        try await zone.client.playLineInput(input)
        try await Task.sleep(for: .seconds(2))
        let state = try await zone.client.transportState()
        print("\(zone.info.title): transport is \(state.rawValue)")
    }

    /// Plays one row of a menu on a zone. Changes what the zone's group hears.
    static func play(zoneName: String, objectID: String, selector: String) async throws {
        let zones = await connectAll()
        let matches = zones.filter { $0.info.title.localizedCaseInsensitiveContains(zoneName) }
        guard matches.count == 1 else {
            let names = zones.map { $0.info.title }.joined(separator: ", ")
            throw Failure(description: "\"\(zoneName)\" matched \(matches.count) zones. Zones found: \(names)")
        }
        let zone = matches[0]

        let page = try await zone.client.page(of: objectID)
        var chosen: MediaEntry?
        if let number = Int(selector) {
            chosen = page.entries.first { $0.index == number }
        } else {
            chosen = page.entries.first { $0.isPlayable && $0.title.localizedCaseInsensitiveContains(selector) }
        }
        guard let entry = chosen else {
            throw Failure(description: "no row matching \"\(selector)\" in \(objectID). Run `nuvoctl browse` to list rows.")
        }
        guard entry.isPlayable else {
            throw Failure(description: "row \(entry.index) (\"\(entry.title)\") is not playable.")
        }

        let containerDIDL: String
        if let supplied = page.containerDIDL {
            containerDIDL = supplied
            print("folder: \(page.folder?.title ?? "?") (\(page.folder?.id ?? "?")), described by the player")
        } else {
            containerDIDL = await zone.client.containerDescription(for: objectID)
            print("folder: no description from the player; using a minimal one")
        }

        // Playback belongs to the group's master, so send the request there.
        var target = zone
        if zone.info.memberGroupID.isEmpty {
            let groupID = try await zone.client.createGroup(memberIDs: [zone.info.memberID])
            print("\(zone.info.title) was off; created group \(groupID)")
        } else if let master = zones.first(where: { $0.info.masterGroupID == zone.info.memberGroupID }) {
            target = master
            if master.info.memberID != zone.info.memberID {
                print("\(zone.info.title) follows \(master.info.title); this changes the whole group")
            }
        }

        let volume = try await zone.client.volume()
        print("playing row \(entry.index) \"\(entry.title)\" on \(target.info.title) (\(zone.info.title) volume \(volume))")
        try await target.client.play(entry, containerDIDL: containerDIDL)

        try await Task.sleep(for: .seconds(4))
        let state = try await target.client.transportState()
        let actionSet = try await target.client.transportActions()
        let actions = actionSet.sorted().joined(separator: ",")
        print("transport \(state.rawValue)   actions [\(actions)]")
        if let track = try await target.client.nowPlaying() {
            var line = "now playing: \(track.title)"
            if let detail = track.detail { line += " | \(detail)" }
            if let longDetail = track.longDetail { line += " | \(longDetail)" }
            print(line)
        }
    }

    static func off(zoneName: String) async throws {
        let zone = try await find(zoneName)
        let groupID = zone.info.memberGroupID
        guard !groupID.isEmpty else {
            print("\(zone.info.title) is already off.")
            return
        }
        if zone.info.masterGroupID == groupID {
            print("\(zone.info.title) is the master of \(groupID): ending the group (GroupDisband)")
            try await zone.client.disbandGroup(groupID)
        } else {
            print("\(zone.info.title) follows \(groupID): leaving the group (GroupMemberSetGroup with empty group)")
            try await zone.client.setGroup(memberIDs: [zone.info.memberID], groupID: "")
        }
        print("\(zone.info.title): request accepted")
    }

    static func watch(seconds: Int) async throws {
        let zones = await connectAll()
        guard !zones.isEmpty else {
            print("No zones found.")
            return
        }
        let server = try EventServer()
        let port = try await server.start { event in
            let tag = String(event.sid.suffix(6))
            if let changes = event.lastChange {
                for name in changes.keys.sorted() {
                    let value = (changes[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[\(tag)] \(name) = \(value)")
                }
            } else {
                for name in event.properties.keys.sorted() {
                    let value = (event.properties[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[\(tag)] \(name) = \(value)")
                }
            }
        }
        let session = URLSession.shared
        var subscriptions: [EventSubscription] = []
        for zone in zones {
            guard let host = zone.client.description.location.host,
                  let localIP = LocalAddress.ipv4(toReach: host),
                  let callback = URL(string: "http://\(localIP):\(port)/event") else { continue }
            for service in zone.client.eventedServices {
                do {
                    let subscription = try await GENA.subscribe(to: service.eventURL, callback: callback, session: session)
                    subscriptions.append(subscription)
                    let parts = service.type.split(separator: ":")
                    let shortType = parts.count >= 2 ? String(parts[parts.count - 2]) : service.type
                    let tag = String(subscription.sid.suffix(6))
                    print("subscribed [\(tag)] \(zone.info.title) / \(shortType)")
                } catch {
                    print("subscribe failed for \(zone.info.title) \(service.eventURL.path): \(error)")
                }
            }
        }
        print("Listening on port \(port) for \(seconds) s. Change volume or source to see events.")
        try await Task.sleep(for: .seconds(seconds))
        print("Done listening.")
        // Tell the players to stop sending, all at once, then quit. Each
        // request gives up after 2 s so a slow player cannot hold the exit.
        await withTaskGroup(of: Void.self) { group in
            for subscription in subscriptions {
                group.addTask {
                    await GENA.unsubscribe(subscription, session: session)
                }
            }
        }
        server.stop()
        exit(0)
    }
}
