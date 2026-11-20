import Foundation
import Observation

/// Zones that are playing the same thing.
public struct ZoneGroup: Identifiable {
    public let id: String
    /// The zone hosting the group. Transport commands go here.
    public let master: Zone?
    public let members: [Zone]
}

/// The whole Nuvo installation: discovery, live state and commands.
/// Create one, call `start()`, and bind UI to `zones` / `groups`.
@MainActor
@Observable
public final class NuvoSystem {
    public private(set) var zones: [Zone] = []
    public private(set) var lineInputs: [LineInput] = []
    /// Why `lineInputs` could not be loaded, if the last attempt failed.
    public private(set) var lineInputError: String?
    public private(set) var isDiscovering = false
    /// True once at least one discovery pass has finished.
    public private(set) var hasSearched = false
    /// The most recent command failure, for the UI to show.
    public var errorMessage: String?
    /// Hosts to probe directly, as well as multicast discovery.
    public var knownHosts: [String] = []

    @ObservationIgnored private let soap = SOAPClient()
    @ObservationIgnored private var eventServer: EventServer?
    @ObservationIgnored private var eventPort: UInt16 = 0
    @ObservationIgnored private var subscriptions: [String: SubscriptionRecord] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    private struct SubscriptionRecord {
        let zoneID: String
        let serviceType: String
        var subscription: EventSubscription
        var renewAt: Date
    }

    public nonisolated init() {}

    // MARK: Lifecycle

    /// Starts discovery, event subscriptions and background refresh.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.startEventServer()
            var tick = 0
            while !Task.isCancelled {
                await self?.runTick(tick)
                tick += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        let records = Array(subscriptions.values)
        let session = soap.session
        subscriptions.removeAll()
        Task {
            for record in records {
                await GENA.unsubscribe(record.subscription, session: session)
            }
        }
        eventServer?.stop()
        eventServer = nil
        eventPort = 0
    }

    private func runTick(_ tick: Int) async {
        // Rediscover every minute: description ports change when a player reboots.
        if zones.isEmpty || tick % 12 == 0 {
            await discover()
        }
        await maintainSubscriptions()
        // Zones pushing events only need an occasional safety-net poll.
        for zone in zones where !zone.hasLiveUpdates || !zone.isReachable || tick % 6 == 0 {
            await zone.refresh()
        }
        if tick % 6 == 0 {
            await refreshLineInputs()
        }
    }

    // MARK: Discovery

    public func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer {
            isDiscovering = false
            hasSearched = true
        }
        let locations = await NuvoDiscovery.zoneLocations(knownHosts: knownHosts)
        for location in locations {
            await adopt(location)
        }
        zones.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        await refreshLineInputs()
    }

    private func adopt(_ location: URL) async {
        if zones.contains(where: { $0.client.description.location == location }) {
            return
        }
        do {
            let client = try await ZoneClient.connect(location: location, soap: soap)
            let udn = client.description.udn
            if let existing = zones.first(where: { $0.id == udn }) {
                // Same zone at a new address (it rebooted). Old subscriptions are dead.
                subscriptions = subscriptions.filter { $0.value.zoneID != udn }
                existing.client = client
                existing.hasLiveUpdates = false
                await existing.refresh()
                await subscribe(existing)
            } else {
                let info = try await client.info()
                let zone = Zone(id: udn, client: client, info: info)
                zones.append(zone)
                await zone.refresh()
                await subscribe(zone)
            }
        } catch {
            errorMessage = "Found a player at \(location.host ?? "?") but could not read it: \(error)"
        }
    }

    public func refreshLineInputs() async {
        guard let zone = zones.first(where: { $0.isReachable }) else { return }
        do {
            lineInputs = try await zone.client.lineInputs()
            lineInputError = nil
        } catch {
            lineInputError = String(describing: error)
        }
    }

    // MARK: Events

    private func startEventServer() async {
        guard eventServer == nil else { return }
        do {
            let server = try EventServer()
            let port = try await server.start { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            }
            eventServer = server
            eventPort = port
        } catch {
            // Not fatal: polling still keeps state current, just less promptly.
            eventPort = 0
        }
    }

    private func handle(_ event: UPnPEvent) {
        guard let record = subscriptions[event.sid],
              let zone = zones.first(where: { $0.id == record.zoneID }) else { return }
        zone.apply(event.properties, from: record.serviceType)
    }

    private func subscribe(_ zone: Zone) async {
        guard eventPort != 0,
              let host = zone.client.description.location.host,
              let localIP = LocalAddress.ipv4(toReach: host),
              let callback = URL(string: "http://\(localIP):\(eventPort)/event") else {
            zone.hasLiveUpdates = false
            return
        }
        let services = zone.client.eventedServices
        var succeeded = 0
        for service in services {
            do {
                let subscription = try await GENA.subscribe(to: service.eventURL, callback: callback,
                                                            session: soap.session)
                subscriptions[subscription.sid] = SubscriptionRecord(
                    zoneID: zone.id,
                    serviceType: service.type,
                    subscription: subscription,
                    renewAt: Date().addingTimeInterval(subscription.timeout / 2)
                )
                succeeded += 1
            } catch {
                // Leave this service to polling.
            }
        }
        zone.hasLiveUpdates = succeeded == services.count
    }

    private func dropSubscriptions(for zone: Zone) async {
        for (sid, record) in subscriptions where record.zoneID == zone.id {
            subscriptions[sid] = nil
            await GENA.unsubscribe(record.subscription, session: soap.session)
        }
    }

    /// Renews subscriptions before they expire and retries failed ones.
    private func maintainSubscriptions() async {
        let now = Date()
        for (sid, record) in subscriptions where record.renewAt <= now {
            do {
                let renewed = try await GENA.renew(record.subscription, session: soap.session)
                var updated = record
                updated.subscription = renewed
                updated.renewAt = Date().addingTimeInterval(renewed.timeout / 2)
                subscriptions[sid] = nil
                subscriptions[renewed.sid] = updated
            } catch {
                subscriptions[sid] = nil
                zones.first(where: { $0.id == record.zoneID })?.hasLiveUpdates = false
            }
        }
        for zone in zones where !zone.hasLiveUpdates && zone.isReachable {
            await dropSubscriptions(for: zone)
            await subscribe(zone)
        }
    }

    // MARK: Groups

    /// Active groups. Within each, the leader comes first and followers
    /// follow in the order they joined.
    public var groups: [ZoneGroup] {
        var order: [String] = []
        var buckets: [String: [Zone]] = [:]
        for zone in zones where zone.isOn {
            let groupID = zone.info.memberGroupID
            if buckets[groupID] == nil {
                order.append(groupID)
            }
            buckets[groupID, default: []].append(zone)
        }
        return order.map { groupID in
            let members = buckets[groupID] ?? []
            let leader = members.first { $0.info.masterGroupID == groupID }
            // Leader first, then followers in the order they joined.
            let followers = members.filter { $0 !== leader }.sorted { first, second in
                let firstKey = first.info.memberGroupSortKey
                let secondKey = second.info.memberGroupSortKey
                if firstKey != secondKey {
                    return firstKey < secondKey
                }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
            var ordered: [Zone] = []
            if let leader {
                ordered.append(leader)
            }
            ordered.append(contentsOf: followers)
            return ZoneGroup(id: groupID, master: leader, members: ordered)
        }
    }

    /// Zones that are not in any group.
    public var idleZones: [Zone] {
        zones.filter { !$0.isOn }
    }

    /// The zone whose transport state and now-playing info apply to `zone`.
    /// A group member reports NO_MEDIA_PRESENT itself; the truth is on its master.
    public func playbackOwner(of zone: Zone) -> Zone {
        controller(for: zone)
    }

    /// The zone that owns playback for `zone`: its group's master, or itself.
    private func controller(for zone: Zone) -> Zone {
        let groupID = zone.info.memberGroupID
        guard !groupID.isEmpty else { return zone }
        return zones.first { $0.info.masterGroupID == groupID } ?? zone
    }

    // MARK: Transport commands

    public func play(_ zone: Zone) async {
        await transport(zone, expecting: [.playing, .transitioning]) { try await $0.play() }
    }

    public func pause(_ zone: Zone) async {
        await transport(zone, expecting: [.paused, .stopped]) { try await $0.pause() }
    }

    public func stop(_ zone: Zone) async {
        await transport(zone, expecting: [.stopped, .noMedia]) { try await $0.stop() }
    }

    /// Starts playback, or halts it using whichever of Pause and Stop the
    /// current source allows. A live source such as line-in can only stop.
    public func togglePlayPause(_ zone: Zone) async {
        let target = controller(for: zone)
        guard target.isPlayingOrStarting else {
            await play(zone)
            return
        }
        if target.transportActions.contains("Pause") {
            await pause(zone)
        } else {
            await stop(zone)
        }
    }

    public func next(_ zone: Zone) async {
        await transport(zone) { try await $0.next() }
    }

    public func previous(_ zone: Zone) async {
        await transport(zone) { try await $0.previous() }
    }

    public func like(_ zone: Zone) async {
        await transport(zone) { try await $0.like() }
    }

    public func dislike(_ zone: Zone) async {
        await transport(zone) { try await $0.dislike() }
    }

    /// Sends a transport command to the zone that owns playback.
    ///
    /// A player accepts a command before its reported state changes, so when
    /// `expected` is given this does not return until the player reports one
    /// of those states (or three seconds pass). Callers can therefore treat
    /// "returned" as "the state on screen is the confirmed one".
    private func transport(_ zone: Zone, expecting expected: Set<TransportState> = [],
                           _ operation: (ZoneClient) async throws -> Void) async {
        let target = controller(for: zone)
        do {
            try await operation(target.client)
            errorMessage = nil
            await target.refreshTransport()
            if !expected.isEmpty {
                let deadline = ContinuousClock.now + .seconds(3)
                var waits = 0
                while !expected.contains(target.transport), ContinuousClock.now < deadline, !Task.isCancelled {
                    // Pushed events update `target.transport` while we sleep.
                    try? await Task.sleep(for: .milliseconds(150))
                    waits += 1
                    if waits % 3 == 0 {
                        // Re-read in case the event never arrives.
                        await target.refreshTransport()
                    }
                }
            }
            if target !== zone {
                await zone.refreshTransport()
            }
        } catch {
            report(error, zone)
        }
    }

    // MARK: Source and group commands

    /// Plays a browsed row on `zone`, turning the zone on first if needed.
    /// If the zone follows another, this changes what its whole group hears.
    /// Returns true once the player has accepted the request.
    @discardableResult
    public func play(_ entry: MediaEntry, containerDIDL: String, on zone: Zone) async -> Bool {
        do {
            var target = controller(for: zone)
            if !zone.isOn {
                _ = try await zone.client.createGroup(memberIDs: [zone.info.memberID])
                target = zone
            }
            try await target.client.play(entry, containerDIDL: containerDIDL)
            errorMessage = nil
            // Refresh in the background so the caller can dismiss its UI now.
            Task { await self.settle() }
            return true
        } catch {
            report(error, zone)
            return false
        }
    }

    /// Other zones that will also switch if `zone` changes source.
    public func zonesSharingPlayback(with zone: Zone) -> [Zone] {
        let groupID = zone.info.memberGroupID
        guard !groupID.isEmpty else { return [] }
        return zones.filter { $0 !== zone && $0.info.memberGroupID == groupID }
    }

    /// Plays a line input on `zone`, turning the zone on first if needed.
    public func playLineInput(_ input: LineInput, on zone: Zone) async {
        do {
            var target = controller(for: zone)
            if !zone.isOn {
                _ = try await zone.client.createGroup(memberIDs: [zone.info.memberID])
                target = zone
            }
            try await target.client.playLineInput(input)
            errorMessage = nil
            await settle()
        } catch {
            report(error, zone)
        }
    }

    /// Turns a zone off. For a group master this ends the whole group.
    public func turnOff(_ zone: Zone) async {
        let groupID = zone.info.memberGroupID
        guard !groupID.isEmpty else { return }
        do {
            if zone.info.masterGroupID == groupID {
                try await zone.client.disbandGroup(groupID)
            } else {
                try await zone.client.setGroup(memberIDs: [zone.info.memberID], groupID: "")
            }
            errorMessage = nil
            await settle()
        } catch {
            report(error, zone)
        }
    }

    /// Adds `zone` to an existing group so it plays the same thing.
    public func join(_ zone: Zone, to group: ZoneGroup) async {
        guard let target = group.master ?? group.members.first, target !== zone else { return }
        do {
            try await target.client.setGroup(memberIDs: [zone.info.memberID], groupID: group.id)
            errorMessage = nil
            await settle()
        } catch {
            report(error, zone)
        }
    }

    /// Group changes take a second or two to show up in what zones report.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(1500))
        for zone in zones {
            await zone.refresh()
        }
    }

    private func report(_ error: Error, _ zone: Zone) {
        errorMessage = "\(zone.name): \(error)"
    }
}
