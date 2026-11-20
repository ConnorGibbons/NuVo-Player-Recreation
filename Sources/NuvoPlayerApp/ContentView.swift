import SwiftUI
import NuvoKit

@MainActor
struct ContentView: View {
    @Environment(NuvoSystem.self) private var system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if system.zones.isEmpty {
                    emptyState
                }
                ForEach(system.groups) { group in
                    GroupSection(group: group)
                }
                if !system.idleZones.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Not playing")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        ForEach(system.idleZones) { zone in
                            ZoneCard(zone: zone)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if let message = system.errorMessage {
                ErrorBar(message: message) {
                    system.errorMessage = nil
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await system.discover() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(system.isDiscovering)
                .help("Search the network for players")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if system.isDiscovering || !system.hasSearched {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for Nuvo players…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            ContentUnavailableView(
                "No players found",
                systemImage: "speaker.slash",
                description: Text("Check that this Mac is on the same network as your Nuvo players, then rescan.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

/// One playback group: its zones share a source and transport.
@MainActor
struct GroupSection: View {
    let group: ZoneGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if group.members.count > 1 {
                Label("Group - \(group.id)", systemImage: "link")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            ForEach(group.members) { zone in
                ZoneCard(zone: zone)
            }
        }
    }
}

@MainActor
struct ZoneCard: View {
    @Environment(NuvoSystem.self) private var system
    let zone: Zone
    @State private var isBrowsing = false
    @State private var isConfirmingStop = false
    @State private var isStopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if zone.isOn {
                nowPlaying
            } else {
                Text("Choose something to play to turn this zone on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            volumeRow
        }
        .padding(14)
        .background {
            // Same grey as every card, with a faint green wash on a leader,
            // so the card keeps the same weight and only its hue shifts.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.opacity(isLeadingOthers ? 0.06 : 0))
                }
        }
        .opacity(zone.isReachable ? 1 : 0.5)
        .sheet(isPresented: $isBrowsing) {
            BrowserSheet(system: system, zone: zone)
        }
        .confirmationDialog("Stop playing in all rooms?", isPresented: $isConfirmingStop) {
            Button("Stop Everywhere", role: .destructive) {
                Task {
                    isStopping = true
                    await system.turnOff(zone)
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sourceMenu
            groupMenu
            if zone.isOn {
                offButton
            }
        }
    }

    /// True when other rooms are following this one.
    private var isLeadingOthers: Bool {
        zone.isGroupMaster && !system.zonesSharingPlayback(with: zone).isEmpty
    }

    /// True when this zone is playing what another zone leads.
    private var isFollower: Bool {
        zone.isOn && owner !== zone
    }

    /// A follower gets a "leave" button; a leader or a zone playing alone
    /// gets a power button. Turning off a leader stops other rooms, so that
    /// case asks first.
    @ViewBuilder
    private var offButton: some View {
        if isFollower {
            CommandButton(systemImage: "rectangle.portrait.and.arrow.right",
                          help: "Leave the group. \(zone.name) stops playing; \(owner.name) carries on.",
                          tint: Color.red.opacity(0.7)) {
                await system.turnOff(zone)
            }
        } else {
            let affectsOthers = !system.zonesSharingPlayback(with: zone).isEmpty
            CommandButton(systemImage: "power",
                          help: affectsOthers ? "Turn off this room and every room following it" : "Turn off",
                          tint: .red,
                          isBusy: isStopping) {
                if affectsOthers {
                    // Ask first; the dialog's button does the work.
                    isConfirmingStop = true
                } else {
                    await system.turnOff(zone)
                }
            }
        }
    }

    private var stopConfirmationMessage: String {
        let names = system.zonesSharingPlayback(with: zone).map { $0.name }.joined(separator: ", ")
        return "\(zone.name) is leading the group. Turning it off ends the group and also stops playback in \(names)."
    }

    /// The zone whose playback this card reflects: the group's master.
    private var owner: Zone {
        system.playbackOwner(of: zone)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !zone.info.model.isEmpty {
            parts.append(zone.info.model.uppercased())
        }
        if !zone.isReachable {
            parts.append("not responding")
        } else if zone.isOn && owner !== zone {
            parts.append("following \(owner.name)")
        } else if zone.isOn && !system.zonesSharingPlayback(with: zone).isEmpty {
            parts.append("leading the group")
        }
        if !zone.hasLiveUpdates && zone.isReachable {
            parts.append("polling")
        }
        return parts.joined(separator: " · ")
    }

    private var sourceMenu: some View {
        Button {
            isBrowsing = true
        } label: {
            Label(zone.isOn ? "Source" : "Play", systemImage: zone.isOn ? "music.note.list" : "play.fill")
        }
        .disabled(isFollower)
        .help(sourceHelp)
    }

    private var sourceHelp: String {
        if isFollower {
            return "\(zone.name) plays whatever \(owner.name) plays. Change the source there, or leave the group first."
        }
        return zone.isOn ? "Choose something else to play" : "Turn this zone on by choosing something to play"
    }

    /// Only a room that is not playing can join a group. Rooms already in
    /// one are managed with their own buttons: leave on a follower, power on
    /// the leader.
    @ViewBuilder
    private var groupMenu: some View {
        if !zone.isOn && !system.groups.isEmpty {
            Menu {
                ForEach(system.groups) { group in
                    Button {
                        Task { await system.join(zone, to: group) }
                    } label: {
                        Text(joinLabel(for: group))
                    }
                }
            } label: {
                Label("Join", systemImage: "link")
            }
            .fixedSize()
            .help("Play the same thing as another room")
        }
    }

    private func joinLabel(for group: ZoneGroup) -> String {
        let names = group.members.map { $0.name }.joined(separator: " + ")
        if let title = group.master?.nowPlaying?.title {
            return "\(names) (\(title))"
        }
        return names
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            if let artwork = owner.nowPlaying?.artworkURL {
                AsyncImage(url: artwork) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(owner.nowPlaying?.title ?? transportLabel)
                    .font(.body)
                    .lineLimit(1)
                if let line = secondLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if zone.isGroupMaster || system.groups.first(where: { $0.id == zone.info.memberGroupID })?.members.count == 1 {
                transportButtons
            }
        }
    }

    private var secondLine: String? {
        guard let track = owner.nowPlaying else { return nil }
        let parts = [track.detail, track.longDetail, track.artist, track.album].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var transportLabel: String {
        switch owner.transport {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .transitioning: return "Starting…"
        case .noMedia: return "Nothing selected"
        case .unknown: return ""
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            CommandButton(systemImage: "backward.fill", help: "Previous",
                          isEnabled: zone.transportActions.contains("Previous")) {
                await system.previous(zone)
            }
            CommandButton(systemImage: playbackIcon, help: playbackHelp, isEnabled: canTogglePlayback) {
                await system.togglePlayPause(zone)
            }
            CommandButton(systemImage: "forward.fill", help: "Next",
                          isEnabled: zone.transportActions.contains("Next")) {
                await system.next(zone)
            }

            // Shown only for sources that offer them (Pandora).
            if zone.transportActions.contains("X_NUVO_Like") {
                CommandButton(systemImage: "hand.thumbsup", help: "More like this") {
                    await system.like(zone)
                }
                .padding(.leading, 8)
            }
            if zone.transportActions.contains("X_NUVO_Dislike") {
                CommandButton(systemImage: "hand.thumbsdown", help: "Not this song (skips it)") {
                    await system.dislike(zone)
                }
            }
        }
    }

    private var playbackHelp: String {
        guard zone.isPlayingOrStarting else { return "Play" }
        return zone.transportActions.contains("Pause") ? "Pause" : "Stop"
    }

    /// Shows stop rather than pause when the source cannot be paused.
    private var playbackIcon: String {
        guard zone.isPlayingOrStarting else { return "play.fill" }
        return zone.transportActions.contains("Pause") ? "pause.fill" : "stop.fill"
    }

    private var canTogglePlayback: Bool {
        let actions = zone.transportActions
        if zone.isPlayingOrStarting {
            return actions.contains("Pause") || actions.contains("Stop")
        }
        return actions.contains("Play")
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await zone.setMuted(!zone.isMuted) }
            } label: {
                Image(systemName: zone.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help(zone.isMuted ? "Unmute" : "Mute")

            Slider(value: volumeBinding, in: 0...100)

            Text("\(zone.volume)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(zone.volume) },
            set: { zone.setVolume(Int($0.rounded())) }
        )
    }
}

/// A bordered icon button for a command sent to a player. While the command
/// is in flight the icon is replaced by a spinner and the button ignores
/// clicks; it returns once the player has accepted the command and its new
/// state has been read back.
@MainActor
struct CommandButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    /// Icon colour. Nil uses the standard label colour.
    var tint: Color? = nil
    /// Lets the owner show the spinner for work started elsewhere, such as
    /// after a confirmation dialog.
    var isBusy = false
    let action: () async -> Void
    @State private var isRunning = false

    private var showsSpinner: Bool {
        isRunning || isBusy
    }

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            ZStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint ?? Color.primary)
                    .opacity(showsSpinner ? 0 : 1)
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 24, height: 18)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled || showsSpinner)
        .help(help)
    }
}

struct ErrorBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(3)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(12)
        .background(.bar)
    }
}
