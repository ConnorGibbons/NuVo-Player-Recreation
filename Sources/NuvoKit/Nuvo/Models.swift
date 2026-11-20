import Foundation

/// Protocol constants for the Nuvo Player Portfolio.
public enum Nuvo {
    public static let zoneDeviceType = "urn:schemas-nuvotechnologies-com:device:Zone:1"
    public static let zoneService = "urn:schemas-nuvotechnologies-com:service:Zone:1"
    public static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
    public static let contentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1"
    public static let lineInContainer = "lineIn:systemLineIns"
}

/// Actions NuvoKit refuses to send, whatever the caller asks.
/// They re-home, reconfigure or wipe a player.
public enum NuvoSafety {
    public static let forbiddenActions: Set<String> = [
        "SystemCreate",
        "SystemJoin",
        "SystemConfigureGWs",
        "RestoreFactoryDefaults",
        "SelectPreset",      // its only preset is FactoryDefaults
        "StartWpsPbc",
    ]

    public static func isForbidden(_ action: String) -> Bool {
        forbiddenActions.contains(action)
    }
}

/// What `Zone.Get` reports about a zone.
public struct ZoneInfo: Sendable, Equatable {
    public var memberID: String
    public var title: String
    public var model: String
    public var firmware: String
    public var systemID: String
    public var icon: String
    /// `player`, `toslink` or `rca`.
    public var audioInput: String
    /// `standby`, `active` or `learning`.
    public var powerState: String
    /// ID of the group this zone hosts. Empty when it hosts none.
    public var masterGroupID: String
    /// ID of the group this zone is listening to. Empty means the zone is off.
    public var memberGroupID: String
    /// When this zone's group membership last changed, as the player's
    /// zero-padded millisecond timestamp. Orders followers by when they joined.
    public var memberGroupSortKey: String

    public init(response r: [String: String]) {
        memberID = r["MemberID"] ?? ""
        title = r["Title"] ?? ""
        model = r["Model"] ?? ""
        firmware = r["FirmwareVersion"] ?? ""
        systemID = r["SystemID"] ?? ""
        icon = r["Icon"] ?? ""
        audioInput = r["AudioInput"] ?? ""
        powerState = r["PowerState"] ?? ""
        masterGroupID = ZoneInfo.groupID(fromJSON: r["MasterGroup"] ?? "")
        memberGroupID = ZoneInfo.groupID(fromJSON: r["MemberGroup"] ?? "")
        memberGroupSortKey = ZoneInfo.groupSortKey(fromJSON: r["MemberGroup"] ?? "")
    }

    /// Group fields arrive as JSON: `{"id":"gid...","sortKey":"..."}`.
    static func groupID(fromJSON json: String) -> String {
        groupField("id", fromJSON: json)
    }

    static func groupSortKey(fromJSON json: String) -> String {
        groupField("sortKey", fromJSON: json)
    }

    private static func groupField(_ name: String, fromJSON json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        return object[name] as? String ?? ""
    }
}

public enum TransportState: String, Sendable {
    case stopped = "STOPPED"
    case playing = "PLAYING"
    case transitioning = "TRANSITIONING"
    case paused = "PAUSED_PLAYBACK"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown = ""

    public init(raw: String) {
        self = TransportState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
    }
}

/// What is playing, taken from DIDL-Lite metadata.
public struct TrackInfo: Sendable, Equatable {
    /// Headline. For radio this is the station ("Ch 9 - 90s on 9").
    public var title: String
    public var artist: String?
    public var album: String?
    /// `dc:description`. For SiriusXM this is the song ("Slide (98)").
    public var detail: String?
    /// `upnp:longDescription`. For SiriusXM, "Artist - Album".
    public var longDetail: String?
    /// `dc:creator`. Nuvo puts the source's ID here ("siriusxm2", "lineIn"), not an artist.
    public var service: String?
    public var artworkURL: URL?
}

/// A line input somewhere in the system. Any zone can play any zone's input.
public struct LineInput: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    /// Name of the zone that owns the physical input.
    public let ownerName: String
    public let uri: String
    /// 1-based position in the system's line-in listing.
    public let index: Int
    /// True when the player reports nothing connected to the input.
    public let isDisabled: Bool
    /// The device's own DIDL for this item, sent back verbatim when playing it.
    let rawItemXML: String
}

/// One row of a browse listing: a folder (container) or something playable.
public struct MediaEntry: Sendable, Hashable {
    public let id: String
    public let title: String
    public let isContainer: Bool
    public let upnpClass: String
    /// The playable address, when the row has one.
    public let uri: String?
    public let detail: String?
    /// The row type from Nuvo's embedded JSON: `container`, `audio`, `footer`,
    /// `spacer`, `action`, `www`...
    public let rowType: String?
    /// 1-based position in the full listing. The player wants this back when playing.
    public let index: Int
    public let artworkURL: URL?
    /// The player's own XML for this row, kept verbatim.
    let rawXML: String

    /// True for rows that start playback when chosen.
    public var isPlayable: Bool {
        !isContainer && uri != nil && (rowType == nil || rowType == "audio")
    }

    /// This row as a standalone DIDL-Lite document, as the player expects it
    /// when the row (or a row inside this folder) is played.
    public var didl: String {
        DIDL.wrap(rawXML)
    }

    /// Parses a DIDL-Lite document into rows, in order.
    /// `firstIndex` is the listing position of the first row, for paged results.
    public static func parse(didl: String, firstIndex: Int = 1) -> [MediaEntry] {
        var entries: [MediaEntry] = []
        for (offset, raw) in DIDL.rawElements(in: didl).enumerated() {
            guard let node = XMLNode.parse(DIDL.wrap(raw))?.children.first else { continue }
            func text(_ name: String) -> String? {
                guard let value = node.child(name)?.trimmedText, !value.isEmpty else { return nil }
                return value
            }
            var rowType: String?
            if let json = text("x_nuvo_nsdk"), let data = json.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                rowType = object["type"] as? String
            }
            entries.append(MediaEntry(
                id: node.attributes["id"] ?? "",
                title: text("title") ?? "",
                isContainer: node.name == "container",
                upnpClass: text("class") ?? "",
                uri: text("res"),
                detail: text("description"),
                rowType: rowType,
                index: firstIndex + offset,
                artworkURL: DIDL.artworkURL(text("albumArtURI") ?? text("icon")),
                rawXML: raw
            ))
        }
        return entries
    }
}

/// What a folder says about itself (from X_NUVO_Browse's ContainerProperties).
public struct FolderInfo: Sendable, Hashable {
    /// The folder's canonical ID. `pandora:` reports `pandora:StationList`.
    public let id: String
    public let title: String
    /// Present when the folder is searchable: the ID to search under.
    public let searchID: String?
    /// Prompt for the search box, e.g. "Artist, Track".
    public let searchPrompt: String?

    static func parse(_ didl: String) -> FolderInfo? {
        guard let container = XMLNode.parse(didl)?.child("container") else { return nil }
        let search = container.child("x_nuvo_search")
        return FolderInfo(
            id: container.attributes["id"] ?? "",
            title: container.child("title")?.trimmedText ?? "",
            searchID: search?.attributes["id"],
            searchPrompt: search?.child("title")?.trimmedText
        )
    }
}

/// One page of a folder's rows.
public struct BrowsePage: Sendable {
    public let entries: [MediaEntry]
    /// Zero-based offset of this page within the folder.
    public let start: Int
    /// How many rows the player says it returned (may exceed `entries.count` if a row failed to parse).
    public let returned: Int
    public let totalMatches: Int
    /// The folder's description, when the player supplied one.
    public let folder: FolderInfo?
    /// The folder's DIDL exactly as the player sent it. Pass this back when
    /// playing one of the rows.
    public let containerDIDL: String?

    public var nextStart: Int { start + returned }
    public var hasMore: Bool { returned > 0 && nextStart < totalMatches }

    /// Builds a page from the output arguments of Browse or X_NUVO_Browse.
    init(response: [String: String], start: Int) {
        let rows = MediaEntry.parse(didl: response["Result"] ?? "", firstIndex: start + 1)
        let count = Int(response["NumberReturned"] ?? "") ?? rows.count
        let properties = (response["ContainerProperties"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasProperties = properties.contains("<container")
        self.entries = rows
        self.start = start
        self.returned = count
        self.totalMatches = Int(response["TotalMatches"] ?? "") ?? (start + count)
        self.containerDIDL = hasProperties ? properties : nil
        self.folder = hasProperties ? FolderInfo.parse(properties) : nil
    }
}

/// Helpers for DIDL-Lite, the XML dialect UPnP uses to describe media.
enum DIDL {
    static let open = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
        + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" "
        + "xmlns:x=\"urn:schemas.nuvotechnologies.com\">"
    static let close = "</DIDL-Lite>"

    static func wrap(_ inner: String) -> String {
        open + inner + close
    }

    /// The `<item>...</item>` substrings of a DIDL document, untouched.
    /// Kept as raw text because the player expects its own metadata back
    /// byte for byte, including the embedded JSON.
    static func rawItems(in didl: String) -> [String] {
        var items: [String] = []
        var searchStart = didl.startIndex
        while let start = didl.range(of: "<item ", range: searchStart..<didl.endIndex),
              let end = didl.range(of: "</item>", range: start.upperBound..<didl.endIndex) {
            items.append(String(didl[start.lowerBound..<end.upperBound]))
            searchStart = end.upperBound
        }
        return items
    }

    /// Every `<item>` and `<container>` element of a DIDL document, in order,
    /// as untouched substrings.
    static func rawElements(in didl: String) -> [String] {
        var elements: [String] = []
        var cursor = didl.startIndex
        while cursor < didl.endIndex {
            let item = didl.range(of: "<item ", range: cursor..<didl.endIndex)
            let container = didl.range(of: "<container ", range: cursor..<didl.endIndex)
            let start: Range<String.Index>
            let closeTag: String
            if let item, let container {
                if item.lowerBound < container.lowerBound {
                    start = item
                    closeTag = "</item>"
                } else {
                    start = container
                    closeTag = "</container>"
                }
            } else if let item {
                start = item
                closeTag = "</item>"
            } else if let container {
                start = container
                closeTag = "</container>"
            } else {
                break
            }
            guard let end = didl.range(of: closeTag, range: start.upperBound..<didl.endIndex) else { break }
            elements.append(String(didl[start.lowerBound..<end.upperBound]))
            cursor = end.upperBound
        }
        return elements
    }

    /// A minimal folder description, for when the player will not supply one.
    static func container(id: String, title: String) -> String {
        wrap("<container id=\"\(xmlEscape(id))\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(xmlEscape(title))</dc:title>"
            + "<upnp:class>object.container</upnp:class>"
            + "</container>")
    }

    static func lineInputs(fromBrowseResult didl: String) -> [LineInput] {
        var inputs: [LineInput] = []
        for (offset, raw) in rawItems(in: didl).enumerated() {
            guard let item = XMLNode.parse(wrap(raw))?.child("item"),
                  let uri = item.child("res")?.trimmedText, !uri.isEmpty else { continue }  // skips footer rows
            inputs.append(LineInput(
                id: item.attributes["id"] ?? uri,
                title: item.child("title")?.trimmedText ?? "Line In",
                ownerName: item.child("description")?.trimmedText ?? "",
                uri: uri,
                index: offset + 1,
                isDisabled: item.child("x_nuvo_disabled")?.trimmedText == "1",
                rawItemXML: raw
            ))
        }
        return inputs
    }

    static func track(from didl: String) -> TrackInfo? {
        guard !didl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let root = XMLNode.parse(didl),
              let item = root.child("item") ?? root.child("container"),
              let title = item.child("title")?.trimmedText, !title.isEmpty else { return nil }
        func text(_ name: String) -> String? {
            guard let value = item.child(name)?.trimmedText, !value.isEmpty else { return nil }
            return value
        }
        return TrackInfo(
            title: title,
            artist: text("artist"),
            album: text("album"),
            detail: text("description"),
            longDetail: text("longDescription"),
            service: text("creator"),
            artworkURL: artworkURL(text("albumArtURI") ?? text("icon"))
        )
    }

    /// Art arrives as plain http from public hosts, which App Transport
    /// Security blocks, so those are upgraded to https. Icons with a
    /// `skin:` scheme are built into the official app and are skipped.
    static func artworkURL(_ text: String?) -> URL? {
        guard let text, text.hasPrefix("http"), var components = URLComponents(string: text) else { return nil }
        if components.scheme == "http", let host = components.host, host.contains(where: { $0.isLetter }) {
            components.scheme = "https"
        }
        return components.url
    }

    /// Container metadata the player expects alongside a line-in item.
    static let lineInContainer = wrap(
        "<container id=\"lineIn:systemLineIns\" parentID=\"0\" restricted=\"1\">"
        + "<dc:title>Line In</dc:title>"
        + "<upnp:class>object.container</upnp:class>"
        + "<x:x_nuvo_nsdk>{&quot;title&quot;:&quot;Line In&quot;,&quot;containerType&quot;:&quot;none&quot;,"
        + "&quot;path&quot;:&quot;lineIn:systemLineIns&quot;,&quot;type&quot;:&quot;container&quot;,"
        + "&quot;align&quot;:&quot;left&quot;}</x:x_nuvo_nsdk>"
        + "</container>"
    )
}
