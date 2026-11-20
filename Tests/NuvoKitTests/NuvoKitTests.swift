import XCTest
@testable import NuvoKit

/// Parsing tests driven by responses captured from a real P500 ("Sound Bar").
final class NuvoKitTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDeviceDescription() throws {
        let location = try XCTUnwrap(URL(string: "http://10.0.0.91:44242/00000000-0000-0000-0000-0025ed1e2a55.xml"))
        let description = try XCTUnwrap(DeviceDescription.parse(try fixture("description"), location: location))

        XCTAssertEqual(description.udn, "uuid:00000000-0000-0000-0000-0025ed1e2a55")
        XCTAssertEqual(description.deviceType, Nuvo.zoneDeviceType)
        XCTAssertEqual(description.services.count, 6)
        XCTAssertEqual(description.service(Nuvo.zoneService)?.controlURL.absoluteString,
                       "http://10.0.0.91:44242/ZoneService/control")
        XCTAssertEqual(description.service(Nuvo.renderingControl)?.eventURL.absoluteString,
                       "http://10.0.0.91:44242/RenderingControl/event")
        XCTAssertNotNil(description.service(Nuvo.avTransport))
        XCTAssertNotNil(description.service(Nuvo.contentDirectory))
    }

    func testZoneGetResponse() throws {
        let values = try SOAPClient.parseResponse(try fixture("zone_get"), action: "Get", httpStatus: 200)
        let info = ZoneInfo(response: values)

        XCTAssertEqual(info.title, "Sound Bar")
        XCTAssertEqual(info.model, "p500")
        XCTAssertEqual(info.firmware, "2025.0")
        XCTAssertEqual(info.memberID, "memberId-0025ed1e2a55")
        XCTAssertEqual(info.audioInput, "toslink")
        XCTAssertEqual(info.powerState, "standby")
        XCTAssertEqual(info.memberGroupID, "")
        XCTAssertEqual(info.masterGroupID, "")
        XCTAssertEqual(info.memberGroupSortKey, "00000001789611514033")
    }

    func testGroupIDParsing() {
        XCTAssertEqual(ZoneInfo.groupID(fromJSON: #"{"id":"gid123","sortKey":"0001"}"#), "gid123")
        XCTAssertEqual(ZoneInfo.groupID(fromJSON: #"{"id":"","sortKey":"0001"}"#), "")
        XCTAssertEqual(ZoneInfo.groupID(fromJSON: ""), "")
        XCTAssertEqual(ZoneInfo.groupSortKey(fromJSON: #"{"id":"gid123","sortKey":"0001"}"#), "0001")
        XCTAssertEqual(ZoneInfo.groupSortKey(fromJSON: ""), "")
    }

    func testLineInputs() throws {
        let values = try SOAPClient.parseResponse(try fixture("browse_linein"), action: "Browse", httpStatus: 200)
        let inputs = DIDL.lineInputs(fromBrowseResult: values["Result"] ?? "")

        // The listing has two rows; the second is a footer with no playable URI.
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.title, "Optical")
        XCTAssertEqual(input.ownerName, "Sound Bar")
        XCTAssertEqual(input.uri, "nuvo:nuvoremote:memberId-0025ed1e2a55/lineIn_memberId-0025ed1e2a55")
        XCTAssertEqual(input.index, 1)
        XCTAssertTrue(input.isDisabled)
        XCTAssertTrue(input.rawItemXML.hasPrefix("<item "))
        XCTAssertTrue(input.rawItemXML.hasSuffix("</item>"))
        // The embedded JSON must survive untouched, entities included.
        XCTAssertTrue(input.rawItemXML.contains("&quot;playLogicPath&quot;"))
    }

    func testSOAPFault() {
        let fault = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
        <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
        <errorCode>501</errorCode><errorDescription>Action Failed</errorDescription>
        </UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
        XCTAssertThrowsError(try SOAPClient.parseResponse(Data(fault.utf8), action: "GroupDisband", httpStatus: 500)) { error in
            let soapFault = error as? SOAPFault
            XCTAssertEqual(soapFault?.code, "501")
            XCTAssertEqual(soapFault?.detail, "Action Failed")
        }
    }

    func testEnvelopeEscapesArguments() {
        let envelope = SOAPClient.envelope(action: "GroupCreate", service: Nuvo.zoneService,
                                           arguments: [("memberIDs", #"["memberId-a&b"]"#)])
        XCTAssertTrue(envelope.contains("<memberIDs>[&quot;memberId-a&amp;b&quot;]</memberIDs>"))
        XCTAssertTrue(envelope.contains("<u:GroupCreate xmlns:u=\"\(Nuvo.zoneService)\">"))
    }

    func testLastChange() {
        let rendering = """
        <Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/"><InstanceID val="0">
        <Volume channel="Master" val="28"/><Mute channel="Master" val="0"/></InstanceID></Event>
        """
        let changes = GENAParser.lastChange(rendering)
        XCTAssertEqual(changes["Volume"], "28")
        XCTAssertEqual(changes["Mute"], "0")
    }

    func testEventPropertySet() {
        let body = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
        <e:property><Title>Sound Bar</Title></e:property>
        <e:property><PowerState>active</PowerState></e:property>
        </e:propertyset>
        """
        let properties = GENAParser.properties(Data(body.utf8))
        XCTAssertEqual(properties["Title"], "Sound Bar")
        XCTAssertEqual(properties["PowerState"], "active")
    }

    func testHTTPRequestParsing() throws {
        let raw = "NOTIFY /event HTTP/1.1\r\nSID: uuid:abc\r\nContent-Length: 5\r\n\r\nhello"
        let request = try XCTUnwrap(HTTPRequest.parse(Data(raw.utf8)))
        XCTAssertEqual(request.method, "NOTIFY")
        XCTAssertEqual(request.headers["sid"], "uuid:abc")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")

        // Body not fully arrived yet: the parser must wait.
        let partial = "NOTIFY /event HTTP/1.1\r\nContent-Length: 50\r\n\r\nhello"
        XCTAssertNil(HTTPRequest.parse(Data(partial.utf8)))
    }

    func testSSDPResponseParsing() throws {
        let raw = "HTTP/1.1 200 OK\r\nLocation: http://10.0.0.91:44242/x.xml\r\n"
            + "ST: urn:schemas-nuvotechnologies-com:device:Zone:1\r\nUSN: uuid:1::zone\r\n\r\n"
        let response = try XCTUnwrap(SSDP.parse(raw, from: "10.0.0.91"))
        XCTAssertEqual(response.location?.port, 44242)
        XCTAssertEqual(response.searchTarget, Nuvo.zoneDeviceType)
    }

    /// Shape of what a P4300 pushed while playing SiriusXM.
    func testRadioMetadata() throws {
        let didl = DIDL.wrap("""
        <item id="siriusxm2:ui/carousel?primary=Api:tune:liveAudio:8206&amp;assetType=channel" restricted="1">
            <dc:title>Ch 9 - 90s on 9</dc:title>
            <dc:creator>siriusxm2</dc:creator>
            <upnp:class>object.item</upnp:class>
            <dc:description>Slide (98)</dc:description>
            <upnp:longDescription>Goo Goo Dolls - Dizzy Up the Girl</upnp:longDescription>
            <upnp:icon>http://albumart.siriusxm.com/albumart/0030/example_m.jpg</upnp:icon>
            <x:x_nuvo_context id="ctx" restricted="1"><dc:title></dc:title></x:x_nuvo_context>
        </item>
        """)
        let track = try XCTUnwrap(DIDL.track(from: didl))
        XCTAssertEqual(track.title, "Ch 9 - 90s on 9")
        XCTAssertEqual(track.detail, "Slide (98)")
        XCTAssertEqual(track.longDetail, "Goo Goo Dolls - Dizzy Up the Girl")
        XCTAssertEqual(track.service, "siriusxm2")
        XCTAssertNil(track.artist)
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://albumart.siriusxm.com/albumart/0030/example_m.jpg")
    }

    func testArtworkURLRules() {
        XCTAssertNil(DIDL.artworkURL("skin:iconLineIn"))
        XCTAssertNil(DIDL.artworkURL(nil))
        // Local players by IP are exempt from ATS and may not serve https.
        XCTAssertEqual(DIDL.artworkURL("http://10.0.0.91/art.png")?.scheme, "http")
    }

    func testMediaEntriesKeepOrderAndRawXML() throws {
        let values = try SOAPClient.parseResponse(try fixture("browse_linein"), action: "Browse", httpStatus: 200)
        let entries = MediaEntry.parse(didl: values["Result"] ?? "", firstIndex: 1)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Optical")
        XCTAssertEqual(entries[0].index, 1)
        XCTAssertEqual(entries[0].rowType, "audio")
        XCTAssertTrue(entries[0].isPlayable)
        XCTAssertTrue(entries[0].didl.hasPrefix("<DIDL-Lite "))
        XCTAssertTrue(entries[0].didl.contains("&quot;playLogicPath&quot;"))

        XCTAssertEqual(entries[1].index, 2)
        XCTAssertEqual(entries[1].rowType, "footer")
        XCTAssertFalse(entries[1].isPlayable)
    }

    func testFoldersAndItemsInterleaved() {
        let didl = DIDL.wrap("""
        <container id="pandora:GenreStations" parentID="pandora:" restricted="1">
            <dc:title>New Genre Station</dc:title><upnp:class>object.container</upnp:class>
        </container>
        <item id="pandora:StationList/station_1" parentID="pandora:" restricted="1">
            <dc:title>QuickMix</dc:title>
            <res protocolInfo="nuvo:*:*:*">nuvo:pandora:StationList/station_1</res>
            <upnp:class>object.item.audioItem</upnp:class>
        </item>
        """)
        let entries = MediaEntry.parse(didl: didl, firstIndex: 101)
        XCTAssertEqual(entries.map { $0.title }, ["New Genre Station", "QuickMix"])
        XCTAssertTrue(entries[0].isContainer)
        XCTAssertFalse(entries[0].isPlayable)
        XCTAssertEqual(entries[0].index, 101)
        XCTAssertTrue(entries[1].isPlayable)
        XCTAssertEqual(entries[1].index, 102)
        XCTAssertEqual(entries[1].uri, "nuvo:pandora:StationList/station_1")
        XCTAssertTrue(entries[0].didl.contains("<container id=\"pandora:GenreStations\""))
    }

    func testSyntheticContainerEscapesID() {
        let didl = DIDL.container(id: "tunein:browse?c=music&x=1", title: "Music")
        XCTAssertTrue(didl.contains("id=\"tunein:browse?c=music&amp;x=1\""))
        XCTAssertNotNil(XMLNode.parse(didl))
    }

    /// ContainerProperties as a P4300 returned it for `pandora:`.
    func testFolderInfoAndPage() {
        let properties = DIDL.wrap("""
        <container id="pandora:StationList" parentID="0" restricted="1">
            <dc:title>Pandora</dc:title>
            <upnp:class>object.container</upnp:class>
            <upnp:icon>skin:iconPandora</upnp:icon>
            <x:x_nuvo_search id="pandora:searches" restricted="1">
                <dc:title>Artist, Track</dc:title>
                <upnp:class>object.container.x_nuvo_searchContainer</upnp:class>
            </x:x_nuvo_search>
            <x:x_nuvo_activity>1</x:x_nuvo_activity>
        </container>
        """)
        let rows = DIDL.wrap("""
        <item id="pandora:StationList/station_1" restricted="1">
            <dc:title>QuickMix</dc:title>
            <res protocolInfo="nuvo:*:*:*">nuvo:pandora:StationList/station_1</res>
        </item>
        """)
        let page = BrowsePage(
            response: ["Result": rows, "NumberReturned": "1", "TotalMatches": "52", "ContainerProperties": properties],
            start: 10
        )
        XCTAssertEqual(page.folder?.id, "pandora:StationList")
        XCTAssertEqual(page.folder?.title, "Pandora")
        XCTAssertEqual(page.folder?.searchID, "pandora:searches")
        XCTAssertEqual(page.folder?.searchPrompt, "Artist, Track")
        XCTAssertEqual(page.containerDIDL, properties)
        XCTAssertEqual(page.entries.first?.index, 11)
        XCTAssertEqual(page.nextStart, 11)
        XCTAssertTrue(page.hasMore)

        // Standard Browse has no ContainerProperties.
        let plain = BrowsePage(response: ["Result": rows, "NumberReturned": "1", "TotalMatches": "1"], start: 0)
        XCTAssertNil(plain.folder)
        XCTAssertNil(plain.containerDIDL)
        XCTAssertFalse(plain.hasMore)
    }

    func testDangerousActionsAreBlocked() {
        for action in ["SystemCreate", "SystemJoin", "SystemConfigureGWs", "RestoreFactoryDefaults"] {
            XCTAssertTrue(NuvoSafety.isForbidden(action), action)
        }
        XCTAssertFalse(NuvoSafety.isForbidden("SetVolume"))
    }
}
