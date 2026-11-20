import Foundation

/// Stateless access to one zone's UPnP services.
/// Every call is one SOAP request; nothing is cached.
public struct ZoneClient: Sendable {
    public let description: DeviceDescription
    let soap: SOAPClient
    let zone: UPnPService
    let transport: UPnPService
    let rendering: UPnPService
    let content: UPnPService

    public static func connect(location: URL, soap: SOAPClient = SOAPClient()) async throws -> ZoneClient {
        let description = try await DeviceDescription.fetch(location, using: soap)
        return try ZoneClient(description: description, soap: soap)
    }

    init(description: DeviceDescription, soap: SOAPClient) throws {
        func require(_ type: String) throws -> UPnPService {
            guard let service = description.service(type) else { throw UPnPError.missingService(type) }
            return service
        }
        self.description = description
        self.soap = soap
        zone = try require(Nuvo.zoneService)
        transport = try require(Nuvo.avTransport)
        rendering = try require(Nuvo.renderingControl)
        content = try require(Nuvo.contentDirectory)
    }

    /// Services that push state changes worth subscribing to.
    public var eventedServices: [UPnPService] { [zone, transport, rendering] }

    /// The single choke point for control requests. The safety list is enforced here.
    @discardableResult
    func call(_ service: UPnPService, _ action: String,
              _ arguments: [(String, String)] = []) async throws -> [String: String] {
        guard !NuvoSafety.isForbidden(action) else { throw UPnPError.forbiddenAction(action) }
        return try await soap.call(action, service: service.type, at: service.controlURL, arguments: arguments)
    }

    private static let instance = ("InstanceID", "0")
    private static let master = ("Channel", "Master")

    // MARK: Zone

    public func info() async throws -> ZoneInfo {
        ZoneInfo(response: try await call(zone, "Get"))
    }

    // MARK: Volume

    public func volume() async throws -> Int {
        let response = try await call(rendering, "GetVolume", [ZoneClient.instance, ZoneClient.master])
        return Int(response["CurrentVolume"] ?? "") ?? 0
    }

    public func setVolume(_ value: Int) async throws {
        let clamped = max(0, min(100, value))
        try await call(rendering, "SetVolume",
                       [ZoneClient.instance, ZoneClient.master, ("DesiredVolume", String(clamped))])
    }

    public func isMuted() async throws -> Bool {
        let response = try await call(rendering, "GetMute", [ZoneClient.instance, ZoneClient.master])
        return ZoneClient.bool(response["CurrentMute"])
    }

    public func setMuted(_ muted: Bool) async throws {
        try await call(rendering, "SetMute",
                       [ZoneClient.instance, ZoneClient.master, ("DesiredMute", muted ? "1" : "0")])
    }

    // MARK: Transport

    public func transportState() async throws -> TransportState {
        let response = try await call(transport, "GetTransportInfo", [ZoneClient.instance])
        return TransportState(raw: response["CurrentTransportState"] ?? "")
    }

    /// Actions currently allowed, for example `Play`, `Pause`, `Next`.
    public func transportActions() async throws -> Set<String> {
        let response = try await call(transport, "GetCurrentTransportActions", [ZoneClient.instance])
        return ZoneClient.actionSet(response["Actions"] ?? "")
    }

    public func nowPlaying() async throws -> TrackInfo? {
        let position = try await call(transport, "GetPositionInfo", [ZoneClient.instance])
        if let track = DIDL.track(from: position["TrackMetaData"] ?? "") {
            return track
        }
        let media = try await call(transport, "GetMediaInfo", [ZoneClient.instance])
        return DIDL.track(from: media["CurrentURIMetaData"] ?? "")
    }

    public func play() async throws {
        try await call(transport, "Play", [ZoneClient.instance, ("Speed", "1")])
    }

    public func pause() async throws {
        try await call(transport, "Pause", [ZoneClient.instance])
    }

    public func stop() async throws {
        try await call(transport, "Stop", [ZoneClient.instance])
    }

    public func next() async throws {
        try await call(transport, "Next", [ZoneClient.instance])
    }

    public func previous() async throws {
        try await call(transport, "Previous", [ZoneClient.instance])
    }

    /// Thumbs up on the current song. Only some sources (Pandora) allow it;
    /// check for `X_NUVO_Like` in `transportActions()`.
    public func like() async throws {
        try await call(transport, "X_NUVO_Like", [ZoneClient.instance])
    }

    /// Thumbs down on the current song. Pandora also skips it.
    public func dislike() async throws {
        try await call(transport, "X_NUVO_Dislike", [ZoneClient.instance])
    }

    // MARK: Groups

    /// Creates a playback group and returns its ID. This is how a zone turns on.
    public func createGroup(memberIDs: [String]) async throws -> String {
        let response = try await call(zone, "GroupCreate", [("memberIDs", ZoneClient.jsonArray(memberIDs))])
        return response["groupID"] ?? ""
    }

    /// Ends a group. Every member stops and goes idle.
    public func disbandGroup(_ groupID: String) async throws {
        try await call(zone, "GroupDisband", [("groupID", groupID)])
    }

    /// Moves zones into a group. An empty `groupID` removes them from theirs.
    public func setGroup(memberIDs: [String], groupID: String) async throws {
        try await call(zone, "GroupMemberSetGroup",
                       [("memberIDs", ZoneClient.jsonArray(memberIDs)), ("groupID", groupID)])
    }

    // MARK: Sources

    /// The UPnP-standard listing call. Returns the raw output arguments.
    private func standardBrowse(objectID: String, start: Int, count: Int) async throws -> [String: String] {
        try await call(content, "Browse", [
            ("ObjectID", objectID),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "*"),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SortCriteria", ""),
        ])
    }

    /// Standard `Browse`, returning the raw DIDL-Lite document. Kept for
    /// diagnostics; normal browsing goes through `page(of:)`.
    public func browse(objectID: String) async throws -> String {
        try await standardBrowse(objectID: objectID, start: 0, count: 100)["Result"] ?? ""
    }

    /// Nuvo's own browse action, the one the official app uses. Read-only.
    /// Returns the raw output arguments: `Result`, `NumberReturned`,
    /// `TotalMatches`, `UpdateID` and `ContainerProperties`.
    /// `arguments` and `queueID` are not understood yet and default to empty.
    public func nuvoBrowse(objectID: String, start: Int = 0, count: Int = 100,
                           arguments: String = "", queueID: String = "") async throws -> [String: String] {
        try await call(content, "X_NUVO_Browse", [
            ("ObjectID", objectID),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "*"),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SubscribeQueueID", queueID),
            ("Arguments", arguments),
        ])
    }

    /// One page of a folder's rows, with the folder's own description.
    ///
    /// Uses X_NUVO_Browse. If the player rejects that outright, falls back to
    /// standard Browse, which returns the same rows without the description.
    /// A timeout is not retried: both actions hang on the same folders.
    public func page(of objectID: String, start: Int = 0, count: Int = 100) async throws -> BrowsePage {
        do {
            let response = try await nuvoBrowse(objectID: objectID, start: start, count: count)
            return BrowsePage(response: response, start: start)
        } catch is SOAPFault {
            let response = try await standardBrowse(objectID: objectID, start: start, count: count)
            return BrowsePage(response: response, start: start)
        }
    }

    /// The first page of a folder's rows.
    public func entries(in objectID: String) async throws -> [MediaEntry] {
        try await page(of: objectID).entries
    }

    /// A DIDL description of a folder, which the player wants alongside any
    /// row played from it. Asks the player first; falls back to a minimal one.
    /// When the folder was reached by browsing, prefer its `MediaEntry.didl`.
    public func containerDescription(for objectID: String, title: String = "") async -> String {
        if let supplied = (try? await page(of: objectID, start: 0, count: 1))?.containerDIDL {
            return supplied
        }
        return DIDL.container(id: objectID, title: title)
    }

    /// Plays a row on this zone's current group. The zone must be in a group.
    /// `containerDIDL` describes the folder the row was listed in.
    public func play(_ entry: MediaEntry, containerDIDL: String) async throws {
        guard entry.isPlayable, let uri = entry.uri else {
            throw UPnPError.badResponse("\"\(entry.title)\" is not a playable row")
        }
        try await playContainerItem(uri: uri, itemDIDL: entry.didl, index: entry.index,
                                    containerDIDL: containerDIDL)
    }

    /// The one request that starts any source: an item, its folder, and its position.
    private func playContainerItem(uri: String, itemDIDL: String, index: Int,
                                   containerDIDL: String) async throws {
        try await call(transport, "X_NUVO_PlayContainerURI", [
            ZoneClient.instance,
            ("CurrentURI", ""),
            ("CurrentURIMetaData", containerDIDL),
            ("TrackURI", uri),
            ("TrackURIMetaData", itemDIDL),
            ("StartingIndex", String(index)),
            ("UpdateID", "-1"),
        ])
    }

    public func lineInputs() async throws -> [LineInput] {
        DIDL.lineInputs(fromBrowseResult: try await browse(objectID: Nuvo.lineInContainer))
    }

    /// Starts a line input on this zone's current group.
    /// The zone must already be in a group (see `createGroup`).
    public func playLineInput(_ input: LineInput) async throws {
        try await playContainerItem(uri: input.uri, itemDIDL: DIDL.wrap(input.rawItemXML),
                                    index: input.index, containerDIDL: DIDL.lineInContainer)
    }

    // MARK: Helpers

    static func bool(_ text: String?) -> Bool {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    static func actionSet(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func jsonArray(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// Finds zones on the local network.
public enum NuvoDiscovery {
    /// Returns the description URL of every zone that answered.
    public static func zoneLocations(rounds: Int = 2, knownHosts: [String] = []) async -> [URL] {
        let responses = await SSDP.search(target: Nuvo.zoneDeviceType, rounds: rounds, unicastHosts: knownHosts)
        var seen = Set<URL>()
        var locations: [URL] = []
        for response in responses {
            guard response.searchTarget == Nuvo.zoneDeviceType, let location = response.location else { continue }
            if seen.insert(location).inserted {
                locations.append(location)
            }
        }
        return locations
    }
}
