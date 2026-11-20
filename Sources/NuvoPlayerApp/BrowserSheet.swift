import SwiftUI
import NuvoKit

/// Folder-by-folder source browser for one zone.
@MainActor
struct BrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var browser: MediaBrowser
    private let system: NuvoSystem
    private let zone: Zone

    init(system: NuvoSystem, zone: Zone) {
        self.system = system
        self.zone = zone
        _browser = State(initialValue: MediaBrowser(system: system, zone: zone))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if browser.path.isEmpty {
                sourceList
            } else {
                folderContents
            }
        }
        .frame(width: 460, height: 560)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !browser.path.isEmpty {
                    Button {
                        Task { await browser.back() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Play on \(zone.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            if let warning = sharedPlaybackWarning {
                Label(warning, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
    }

    /// Picking a source changes the whole group, so say who else is affected.
    private var sharedPlaybackWarning: String? {
        let others = system.zonesSharingPlayback(with: zone)
        guard !others.isEmpty else { return nil }
        let names = others.map { $0.name }.joined(separator: ", ")
        return "This also changes what plays in \(names)"
    }

    // MARK: Starting points

    private var sourceList: some View {
        List {
            ForEach(MediaBrowser.sources) { source in
                Button {
                    Task { await browser.open(source) }
                } label: {
                    HStack {
                        Image(systemName: icon(for: source))
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Text(source.title)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for source: SourceRoot) -> String {
        if source.id.hasPrefix("lineIn") {
            return "cable.connector"
        }
        if source.id.hasPrefix("tunein") {
            return "antenna.radiowaves.left.and.right"
        }
        if source.id.hasPrefix("sirius") {
            return "radio"
        }
        return "music.note"
    }

    // MARK: Folder contents

    @ViewBuilder
    private var folderContents: some View {
        if let message = browser.errorMessage, browser.rows.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await browser.retry() }
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.isLoading && browser.rows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(browser.rows.enumerated()), id: \.offset) { _, entry in
                    row(for: entry)
                }
                if browser.hasMore {
                    // More rows are on their way; they appear as they arrive.
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Loading more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let message = browser.errorMessage {
                    Text("The rest of this list could not be loaded. \(message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: MediaEntry) -> some View {
        if entry.isContainer {
            Button {
                Task { await browser.open(entry) }
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text(entry.title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if entry.isPlayable {
            Button {
                Task {
                    if await browser.play(entry) {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "play.circle")
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if !entry.title.isEmpty {
            // Footers, notices and rows whose action is not supported yet.
            Text(entry.title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
