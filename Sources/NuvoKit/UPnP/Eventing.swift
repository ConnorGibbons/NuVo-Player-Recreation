import Foundation
import Network

/// One GENA event notification: the changed state variables of a service.
public struct UPnPEvent: Sendable {
    public let sid: String
    public let properties: [String: String]
}

/// A parsed inbound HTTP request. Only what GENA NOTIFY needs.
struct HTTPRequest {
    let method: String
    let headers: [String: String]   // keys lowercased
    let body: Data

    /// Returns nil until the buffer holds the full head and body.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let method = requestLine.split(separator: " ").first.map { String($0) } ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let available = buffer.distance(from: headEnd.upperBound, to: buffer.endIndex)
        guard available >= length else { return nil }
        let bodyEnd = buffer.index(headEnd.upperBound, offsetBy: length)
        return HTTPRequest(method: method, headers: headers, body: Data(buffer[headEnd.upperBound..<bodyEnd]))
    }
}

enum GENAParser {
    /// `<e:propertyset><e:property><Name>value</Name></e:property>...` to a dictionary.
    static func properties(_ body: Data) -> [String: String] {
        guard let root = XMLNode.parse(body) else { return [:] }
        var out: [String: String] = [:]
        for property in root.all("property") {
            for variable in property.children {
                out[variable.name] = variable.text
            }
        }
        return out
    }

    /// AVTransport and RenderingControl wrap their state in one `LastChange`
    /// variable: `<Event><InstanceID val="0"><Volume channel="Master" val="28"/>...`.
    static func lastChange(_ xml: String) -> [String: String] {
        guard let root = XMLNode.parse(xml) else { return [:] }
        let instance = root.name == "InstanceID" ? root : (root.first("InstanceID") ?? root)
        var out: [String: String] = [:]
        for variable in instance.children {
            if let channel = variable.attributes["channel"], channel != "Master", out[variable.name] != nil {
                continue
            }
            out[variable.name] = variable.attributes["val"] ?? variable.text
        }
        return out
    }
}

/// A tiny HTTP server that receives GENA NOTIFY callbacks from devices.
public final class EventServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NuvoKit.EventServer")
    // Both touched only on `queue`.
    private var handler: (@Sendable (UPnPEvent) -> Void)?
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    public init() throws {
        listener = try NWListener(using: .tcp)
    }

    /// Starts listening on an OS-assigned port and returns that port.
    public func start(handler: @escaping @Sendable (UPnPEvent) -> Void) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async {
                self.handler = handler
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.listenerStateChanged(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? 0
            startContinuation?.resume(returning: port)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        case .cancelled:
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if let request = HTTPRequest.parse(buffer) {
                self.respond(on: connection)
                self.dispatch(request)
            } else if isComplete || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func dispatch(_ request: HTTPRequest) {
        guard request.method == "NOTIFY", let sid = request.headers["sid"] else { return }
        let properties = GENAParser.properties(request.body)
        guard !properties.isEmpty else { return }
        handler?(UPnPEvent(sid: sid, properties: properties))
    }
}

/// An active event subscription on one service.
public struct EventSubscription: Sendable {
    public let sid: String
    public let eventURL: URL
    public let timeout: TimeInterval
}

/// GENA subscribe / renew / unsubscribe requests.
public enum GENA {
    public static func subscribe(to eventURL: URL, callback: URL, session: URLSession,
                                 timeout: Int = 300) async throws -> EventSubscription {
        var request = URLRequest(url: eventURL)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callback.absoluteString)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
        return try await send(request, eventURL: eventURL, session: session, fallbackTimeout: timeout)
    }

    public static func renew(_ subscription: EventSubscription, session: URLSession,
                             timeout: Int = 300) async throws -> EventSubscription {
        var request = URLRequest(url: subscription.eventURL)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(subscription.sid, forHTTPHeaderField: "SID")
        request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
        return try await send(request, eventURL: subscription.eventURL, session: session, fallbackTimeout: timeout)
    }

    public static func unsubscribe(_ subscription: EventSubscription, session: URLSession) async {
        var request = URLRequest(url: subscription.eventURL)
        request.httpMethod = "UNSUBSCRIBE"
        request.timeoutInterval = 2   // best effort; subscriptions expire on their own anyway
        request.setValue(subscription.sid, forHTTPHeaderField: "SID")
        _ = try? await session.data(for: request)
    }

    private static func send(_ request: URLRequest, eventURL: URL, session: URLSession,
                             fallbackTimeout: Int) async throws -> EventSubscription {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let sid = http.value(forHTTPHeaderField: "SID") else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UPnPError.badResponse("SUBSCRIBE to \(eventURL.path) failed (HTTP \(status))")
        }
        var seconds = TimeInterval(fallbackTimeout)
        if let header = http.value(forHTTPHeaderField: "TIMEOUT"),
           let value = Int(header.replacingOccurrences(of: "Second-", with: "")) {
            seconds = TimeInterval(value)
        }
        return EventSubscription(sid: sid, eventURL: eventURL, timeout: seconds)
    }
}

public extension UPnPEvent {
    /// The decoded contents of a `LastChange` variable, if this event has one.
    var lastChange: [String: String]? {
        properties["LastChange"].map { GENAParser.lastChange($0) }
    }
}
