import Foundation
import TOMLDecoder
import Yams

indirect enum FilesPanelStructuredValue: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: String
        let value: FilesPanelStructuredValue
    }

    case object([Entry])
    case array([FilesPanelStructuredValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func convert(
        _ value: Any,
        remainingNodes: inout Int,
        depth: Int = 1
    ) throws -> Self {
        guard depth <= FilesPanelStructuredDocument.maximumDepth else {
            throw FilesPanelStructuredDocument.ParseError.tooDeep
        }
        remainingNodes -= 1
        guard remainingNodes >= 0 else {
            throw FilesPanelStructuredDocument.ParseError.tooManyNodes
        }
        switch value {
        case let value as [String: Any]:
            return .object(try value.keys.sorted().map {
                Entry(
                    key: $0,
                    value: try convert(value[$0] as Any, remainingNodes: &remainingNodes, depth: depth + 1)
                )
            })
        case let value as [Any]:
            return .array(try value.map {
                try convert($0, remainingNodes: &remainingNodes, depth: depth + 1)
            })
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.stringValue)
        case let value as String: return .string(value)
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }
}

struct FilesPanelStructuredDocument: Sendable {
    enum Format: String, Sendable { case json, yaml, toml, xml, plist }

    static let maximumNodes = 100_000
    static let maximumDepth = 256

    let sourcePath: String
    let source: String?
    let format: Format
    let root: FilesPanelStructuredValue?
    let parseError: String?

    var estimatedByteCost: Int { (source?.utf8.count ?? 0) + nodeCount * 64 }
    var nodeCount: Int { root?.metrics.nodes ?? 0 }

    static func parse(path: String, data: Data, format: Format) throws -> Self {
        let source = String(data: data, encoding: .utf8)
        var remainingNodes = maximumNodes
        let root: FilesPanelStructuredValue
        switch format {
        case .json:
            root = try .convert(
                JSONSerialization.jsonObject(with: data),
                remainingNodes: &remainingNodes
            )
        case .yaml:
            guard let source else { throw ParseError.invalidEncoding }
            if let value = try Yams.load(yaml: source) {
                root = try .convert(value, remainingNodes: &remainingNodes)
            } else {
                root = .null
            }
        case .toml:
            guard let source else { throw ParseError.invalidEncoding }
            root = try .convert(
                Dictionary(TOMLTable(source: source)),
                remainingNodes: &remainingNodes
            )
        case .xml:
            root = try FilesPanelXMLParser.parse(data: data)
        case .plist:
            root = try .convert(
                PropertyListSerialization.propertyList(from: data, format: nil),
                remainingNodes: &remainingNodes
            )
        }
        let metrics = root.metrics
        guard metrics.nodes <= maximumNodes else { throw ParseError.tooManyNodes }
        guard metrics.depth <= maximumDepth else { throw ParseError.tooDeep }
        return .init(sourcePath: path, source: source, format: format, root: root, parseError: nil)
    }

    static func failed(path: String, data: Data, format: Format, error: Error) -> Self {
        .init(
            sourcePath: path,
            source: String(data: data, encoding: .utf8),
            format: format,
            root: nil,
            parseError: String(describing: error)
        )
    }

    enum ParseError: Error { case invalidEncoding, tooManyNodes, tooDeep }
}

private final class FilesPanelXMLParser: NSObject, XMLParserDelegate {
    private struct Element {
        let name: String
        var children: [FilesPanelStructuredValue.Entry] = []
        var text = ""
    }

    private var stack: [Element] = []
    private var root: FilesPanelStructuredValue?
    private var failure: Error?
    private var nodeCount = 0

    static func parse(data: Data) throws -> FilesPanelStructuredValue {
        let delegate = FilesPanelXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw delegate.failure ?? parser.parserError ?? FilesPanelStructuredDocument.ParseError.invalidEncoding
        }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard stack.count < FilesPanelStructuredDocument.maximumDepth else {
            failure = FilesPanelStructuredDocument.ParseError.tooDeep
            parser.abortParsing()
            return
        }
        nodeCount += 1 + attributeDict.count
        guard nodeCount <= FilesPanelStructuredDocument.maximumNodes else {
            failure = FilesPanelStructuredDocument.ParseError.tooManyNodes
            parser.abortParsing()
            return
        }
        let attributes = attributeDict.keys.sorted().map {
            FilesPanelStructuredValue.Entry(key: "@\($0)", value: .string(attributeDict[$0] ?? ""))
        }
        stack.append(.init(name: elementName, children: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard var element = stack.popLast() else { return }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            element.children.append(.init(key: "#text", value: .string(text)))
        }
        let value: FilesPanelStructuredValue = .object(element.children)
        if stack.isEmpty {
            root = .object([.init(key: element.name, value: value)])
        } else {
            stack[stack.count - 1].children.append(.init(key: element.name, value: value))
        }
    }
}

private extension FilesPanelStructuredValue {
    var metrics: (nodes: Int, depth: Int) {
        switch self {
        case .object(let values):
            return values.reduce((1, 1)) { result, value in
                let child = value.value.metrics
                return (result.0 + child.nodes, max(result.1, child.depth + 1))
            }
        case .array(let values):
            return values.reduce((1, 1)) { result, value in
                let child = value.metrics
                return (result.0 + child.nodes, max(result.1, child.depth + 1))
            }
        case .string, .number, .bool, .null: return (1, 1)
        }
    }
}
