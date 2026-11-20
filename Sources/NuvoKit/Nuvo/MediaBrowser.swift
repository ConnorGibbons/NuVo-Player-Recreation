import Foundation
import Observation

/// A place to start browsing from.
public struct SourceRoot: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
}

/// Navigation state for browsing sources on behalf of one zone.
/// Holds no UI; a view draws `path`, `rows` and the loading and error states.
@MainActor
@Observable
public final class MediaBrowser {
    /// One step of the path from a starting point to the current folder.
    public struct Level: Identifiable {
        public let id: String
        public let title: String
        /// The row this folder was opened from. Nil for a starting point.
        let entry: MediaEntry?
    }

    /// Starting points known to work with the browse action. The players'
    /// real home menu has not been found yet, so this list is fixed.
    public static let sources: [SourceRoot] = [
        SourceRoot(id: "pandora:", title: "Pandora"),
        SourceRoot(id: "siriusxm2:ui/root", title: "SiriusXM"),
        SourceRoot(id: "tunein:", title: "TuneIn Radio"),
        SourceRoot(id: Nuvo.lineInContainer, title: "Line In"),
    ]

    public let zone: Zone
    /// Empty while showing the starting points.
    public private(set) var path: [Level] = []
    public private(set) var rows: [MediaEntry] = []
    public private(set) var folder: FolderInfo?
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let system: NuvoSystem
    @ObservationIgnored private var containerDIDL: String?
    @ObservationIgnored private var nextStart = 0
    /// Bumped on every navigation so a slow reply for a folder the user has
    /// already left is ignored.
    @ObservationIgnored private var generation = 0

    public init(system: NuvoSystem, zone: Zone) {
        self.system = system
        self.zone = zone
    }

    public var title: String {
        path.last?.title ?? "Sources"
    }

    // MARK: Navigation

    public func open(_ source: SourceRoot) async {
        path = [Level(id: source.id, title: source.title, entry: nil)]
        await load(reset: true)
    }

    public func open(_ entry: MediaEntry) async {
        guard entry.isContainer else { return }
        path.append(Level(id: entry.id, title: entry.title, entry: entry))
        await load(reset: true)
    }

    public func back() async {
        guard !path.isEmpty else { return }
        path.removeLast()
        if path.isEmpty {
            generation += 1
            clear()
            isLoading = false
        } else {
            await load(reset: true)
        }
    }

    public func retry() async {
        await load(reset: true)
    }

    // MARK: Playing

    /// Plays a row on this browser's zone. Returns true if the player accepted it.
    public func play(_ entry: MediaEntry) async -> Bool {
        guard let level = path.last else { return false }
        return await system.play(entry, containerDIDL: folderDescription(for: level), on: zone)
    }

    /// The folder description the player wants with a play request. Best
    /// source first: the player's own, then the row we came through, then a
    /// minimal hand-built one.
    private func folderDescription(for level: Level) -> String {
        if let supplied = containerDIDL {
            return supplied
        }
        if let entry = level.entry {
            return entry.didl
        }
        if level.id == Nuvo.lineInContainer {
            return DIDL.lineInContainer
        }
        return DIDL.container(id: level.id, title: level.title)
    }

    // MARK: Loading

    private func clear() {
        rows = []
        folder = nil
        containerDIDL = nil
        nextStart = 0
        hasMore = false
        errorMessage = nil
    }

    /// Rows requested first, kept small so a long list appears quickly.
    static let firstPageSize = 30
    /// Rows per request for the rest of the list.
    static let laterPageSize = 100

    /// Loads the current folder. The first page is small; the remaining
    /// pages follow automatically and `rows` grows as each arrives, so the
    /// UI can show and use a long list while it is still coming in.
    private func load(reset: Bool) async {
        guard let level = path.last else { return }
        generation += 1
        let current = generation
        if reset {
            clear()
        }
        isLoading = true
        errorMessage = nil
        var pageSize = rows.isEmpty ? MediaBrowser.firstPageSize : MediaBrowser.laterPageSize
        repeat {
            do {
                let page = try await zone.client.page(of: level.id, start: nextStart, count: pageSize)
                // The user moved on while this was in flight: drop the result.
                guard current == generation else { return }
                rows.append(contentsOf: page.entries)
                if let info = page.folder {
                    folder = info
                }
                if let description = page.containerDIDL {
                    containerDIDL = description
                }
                nextStart = page.nextStart
                hasMore = page.hasMore
            } catch {
                guard current == generation else { return }
                // With rows already shown this is a partial list; the view
                // keeps them and reports the failure underneath.
                errorMessage = MediaBrowser.describe(error)
                hasMore = false
            }
            // The first page is in: stop the full-screen spinner. `hasMore`
            // drives the small one at the foot of the list from here on.
            isLoading = false
            pageSize = MediaBrowser.laterPageSize
        } while hasMore && current == generation
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "The player did not answer for this menu."
        }
        if let fault = error as? SOAPFault {
            return fault.detail ?? fault.description
        }
        return String(describing: error)
    }
}
