import Foundation

public struct UPnPService: Sendable, Hashable {
    public let type: String
    public let controlURL: URL
    public let eventURL: URL
}

/// The parsed device description document that SSDP's LOCATION points at.
public struct DeviceDescription: Sendable {
    public let location: URL
    public let udn: String
    public let deviceType: String
    public let friendlyName: String
    public let services: [UPnPService]

    public func service(_ type: String) -> UPnPService? {
        services.first { $0.type == type }
    }

    public static func fetch(_ location: URL, using soap: SOAPClient) async throws -> DeviceDescription {
        let data = try await soap.get(location)
        guard let description = parse(data, location: location) else {
            throw UPnPError.badResponse("device description at \(location.absoluteString)")
        }
        return description
    }

    static func parse(_ data: Data, location: URL) -> DeviceDescription? {
        guard let root = XMLNode.parse(data), let device = root.child("device") else { return nil }
        var services: [UPnPService] = []
        // Includes services of embedded devices (MediaRenderer, MediaServer).
        for node in root.all("service") {
            guard let type = node.child("serviceType")?.trimmedText,
                  let control = node.child("controlURL")?.trimmedText,
                  let controlURL = URL(string: control, relativeTo: location)?.absoluteURL else { continue }
            let event = node.child("eventSubURL")?.trimmedText ?? ""
            let eventURL = URL(string: event, relativeTo: location)?.absoluteURL ?? controlURL
            services.append(UPnPService(type: type, controlURL: controlURL, eventURL: eventURL))
        }
        return DeviceDescription(
            location: location,
            udn: device.child("UDN")?.trimmedText ?? "",
            deviceType: device.child("deviceType")?.trimmedText ?? "",
            friendlyName: device.child("friendlyName")?.trimmedText ?? "",
            services: services
        )
    }
}
