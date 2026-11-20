import Foundation

/// A minimal XML tree built on Foundation's `XMLParser`.
/// Element names are local names: `dc:title` is stored as `title`.
public final class XMLNode {
    public let name: String
    public let attributes: [String: String]
    public var text: String = ""
    public var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First direct child with this name.
    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// First descendant with this name, depth first.
    public func first(_ name: String) -> XMLNode? {
        for c in children {
            if c.name == name { return c }
            if let found = c.first(name) { return found }
        }
        return nil
    }

    /// Every descendant with this name.
    public func all(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.all(name))
        }
        return out
    }

    public static func parse(_ data: Data) -> XMLNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    public static func parse(_ string: String) -> XMLNode? {
        parse(Data(string.utf8))
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.text += s
        }
    }
}

/// Escapes text for use as XML element content.
func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}
