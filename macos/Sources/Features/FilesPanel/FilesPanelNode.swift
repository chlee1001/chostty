import Foundation

struct FilesPanelNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case file
        case symbolicLink
    }

    enum Children: Hashable, Sendable {
        case unloaded
        case loading
        case loaded([FilesPanelNode])
        case failed(String)
    }

    let path: String
    let name: String
    let kind: Kind
    var children: Children

    var id: String { path }
    var isDirectory: Bool { kind == .directory }

    init(path: String, name: String? = nil, kind: Kind, children: Children? = nil) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
        self.children = children ?? (kind == .directory ? .unloaded : .loaded([]))
    }
}
