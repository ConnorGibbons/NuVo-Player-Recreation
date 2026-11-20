import Foundation
import Observation

/// Live, observable state of one zone. UI code reads this directly.
@MainActor
@Observable
public final class Zone: Identifiable {
    /// The zone's UPnP UDN. Stable across reboots and IP changes.
    public nonisolated let id: String

    public internal(set) var info: ZoneInfo
    public internal(set) var volume: Int = 0
    public internal(set) var isMuted = false
    public internal(set) var transport: TransportState = .unknown
    public internal(set) var transportActions: Set<String> = []
    public internal(set) var nowPlaying: TrackInfo?
    /// False after a request fails; the system keeps retrying.
    public internal(set) var isReachable = true
    /// True while the zone is pushing state changes to us.
    public internal(set) var hasLiveUpdates = false
    public internal(set) var lastError: String?

    @ObservationIgnored var client: ZoneClient
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var transportRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocalVolumeChange = Date.distantPast

    init(id: String, client: ZoneClient, info: ZoneInfo) {
        self.id = id
        self.client = client
        self.info = info
    }

    public var name: String { info.title.isEmpty ? "Zone" : info.title }

    /// A zone is on when it is listening to a group.
    public var isOn: Bool { !info.memberGroupID.isEmpty }

    public var isGroupMaster: Bool { isOn && info.masterGroupID == info.memberGroupID }

    /// True while audio is playing or a stream is starting up. The player
    /// passes through TRANSITIONING on the way to PLAYING, and for the
    /// purposes of "what would the play/pause button do" they are the same.
    public var isPlayingOrStarting: Bool {
        transport == .playing || transport == .transitioning
    }

    public var host: String { client.description.location.host ?? "" }

    // MARK: Commands

    /// Sets the volume. Safe to call on every slider tick: the UI value
    /// updates at once and network writes are coalesced to the latest value.
    public func setVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        volume = clamped
        lastLocalVolumeChange = Date()
        pendingVolume = clamped
        guard volumeTask == nil else { return }
        volumeTask = Task { [weak self] in
            while let zone = self, let next = zone.pendingVolume {
                zone.pendingVolume = nil
                do {
                    try await zone.client.setVolume(next)
                    zone.lastError = nil
                } catch {
                    zone.lastError = String(describing: error)
                }
            }
            self?.volumeTask = nil
        }
    }

    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        do {
            try await client.setMuted(muted)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Reading state

    public func refresh() async {
        do {
            info = try await client.info()
            let current = try await client.volume()
            if !volumeIsLocallyHeld {
                volume = current
            }
            isMuted = try await client.isMuted()
            try await loadTransport()
            isReachable = true
        } catch {
            isReachable = false
            lastError = String(describing: error)
        }
    }

    func refreshTransport() async {
        do {
            try await loadTransport()
        } catch {
            lastError = String(describing: error)
        }
    }

    private func loadTransport() async throws {
        transport = try await client.transportState()
        transportActions = try await client.transportActions()
        nowPlaying = try await client.nowPlaying()
    }

    /// While the user is dragging the slider, ignore volume reports from the
    /// device so the thumb does not jump backwards.
    private var volumeIsLocallyHeld: Bool {
        Date().timeIntervalSince(lastLocalVolumeChange) < 1.5
    }

    // MARK: Events

    /// Applies a pushed state change from one of this zone's services.
    func apply(_ properties: [String: String], from serviceType: String) {
        switch serviceType {
        case Nuvo.zoneService:
            if let value = properties["Title"] { info.title = value }
            if let value = properties["Icon"] { info.icon = value }
            if let value = properties["Model"] { info.model = value }
            if let value = properties["FirmwareVersion"] { info.firmware = value }
            if let value = properties["AudioInput"] { info.audioInput = value }
            if let value = properties["PowerState"] { info.powerState = value }
            if let value = properties["MasterGroup"] { info.masterGroupID = ZoneInfo.groupID(fromJSON: value) }
            if let value = properties["MemberGroup"] {
                info.memberGroupID = ZoneInfo.groupID(fromJSON: value)
                info.memberGroupSortKey = ZoneInfo.groupSortKey(fromJSON: value)
            }

        case Nuvo.renderingControl:
            guard let xml = properties["LastChange"] else { return }
            let changes = GENAParser.lastChange(xml)
            if let text = changes["Volume"], let value = Int(text), !volumeIsLocallyHeld {
                volume = value
            }
            if let text = changes["Mute"] {
                isMuted = ZoneClient.bool(text)
            }

        case Nuvo.avTransport:
            guard let xml = properties["LastChange"] else { return }
            let changes = GENAParser.lastChange(xml)
            if let text = changes["TransportState"] {
                transport = TransportState(raw: text)
            }
            if let text = changes["CurrentTransportActions"] {
                transportActions = ZoneClient.actionSet(text)
            }
            // Radio pushes a new CurrentTrackMetaData on every song change
            // while the URI stays the same.
            if let didl = changes["CurrentTrackMetaData"], let track = DIDL.track(from: didl) {
                nowPlaying = track
            }
            // A read-back shortly after keeps everything consistent.
            scheduleTransportRefresh()

        default:
            break
        }
    }

    private func scheduleTransportRefresh() {
        guard transportRefreshTask == nil else { return }
        transportRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.refreshTransport()
            self?.transportRefreshTask = nil
        }
    }
}
