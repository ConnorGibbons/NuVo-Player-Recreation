import Foundation

public enum UPnPError: Error, CustomStringConvertible {
    case badResponse(String)
    case forbiddenAction(String)
    case missingService(String)

    public var description: String {
        switch self {
        case .badResponse(let why): return "Bad response: \(why)"
        case .forbiddenAction(let name): return "Action \(name) is blocked by NuvoKit's safety list"
        case .missingService(let type): return "Device has no service \(type)"
        }
    }
}

/// A UPnP error returned by the device (HTTP 500 with a SOAP fault body).
public struct SOAPFault: Error, CustomStringConvertible, Sendable {
    public let httpStatus: Int
    public let code: String?
    public let detail: String?

    public var description: String {
        "UPnP error \(code ?? "?"): \(detail ?? "no description") (HTTP \(httpStatus))"
    }
}

/// Sends UPnP control requests: a SOAP envelope POSTed to a service's control URL.
public struct SOAPClient: Sendable {
    public let session: URLSession

    public init(timeout: TimeInterval = 8) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }

    /// Calls `action` and returns the response's output arguments by name.
    public func call(_ action: String, service: String, at controlURL: URL,
                     arguments: [(String, String)] = []) async throws -> [String: String] {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(SOAPClient.envelope(action: action, service: service, arguments: arguments).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try SOAPClient.parseResponse(data, action: action, httpStatus: status)
    }

    static func envelope(action: String, service: String, arguments: [(String, String)]) -> String {
        var args = ""
        for (name, value) in arguments {
            args += "<\(name)>\(xmlEscape(value))</\(name)>"
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service)\">\(args)</u:\(action)></s:Body></s:Envelope>"
    }

    static func parseResponse(_ data: Data, action: String, httpStatus: Int) throws -> [String: String] {
        guard let root = XMLNode.parse(data) else {
            throw UPnPError.badResponse("\(action): unparseable XML (HTTP \(httpStatus))")
        }
        if let fault = root.first("Fault") {
            throw SOAPFault(
                httpStatus: httpStatus,
                code: fault.first("errorCode")?.trimmedText,
                detail: fault.first("errorDescription")?.trimmedText ?? fault.first("faultstring")?.trimmedText
            )
        }
        guard let body = root.first(action + "Response") else {
            throw UPnPError.badResponse("\(action): no response element (HTTP \(httpStatus))")
        }
        var out: [String: String] = [:]
        for arg in body.children {
            out[arg.name] = arg.text
        }
        return out
    }
}
