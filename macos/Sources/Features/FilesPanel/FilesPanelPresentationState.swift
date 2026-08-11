import Foundation

enum FilesPanelRootMode: String, Codable, Equatable, Sendable {
    case followPWD
    case pinned
}

struct FilesPanelPresentationState: Equatable, Sendable {
    static let widthRange = 220.0...480.0
    static let minimumTerminalWidth = 320.0

    static func shouldAutoCollapse(
        availableWidth: Double,
        sidebarWidth: Double,
        panelWidth: Double
    ) -> Bool {
        availableWidth < sidebarWidth + panelWidth + minimumTerminalWidth
    }

    var visible: Bool
    var isAutoCollapsedByLayout = false
    var width: Double {
        didSet { width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
    }
    var rootMode: FilesPanelRootMode
    var pinnedRoot: String?
    var showHidden: Bool

    struct Seed: Sendable {
        var visible: Bool
        var width: Double
        var rootMode: FilesPanelRootMode
        var pinnedRoot: String?
        var showHidden: Bool

        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Seed {
            let storedWidth = defaults.object(forKey: "chostty.filesPanelWidth") as? Double ?? 280
            return .init(
                visible: defaults.object(forKey: "chostty.filesPanelVisible") as? Bool ?? false,
                width: min(max(storedWidth, widthRange.lowerBound), widthRange.upperBound),
                rootMode: .followPWD,
                pinnedRoot: nil,
                showHidden: defaults.object(forKey: "chostty.filesPanelShowHidden") as? Bool ?? false
            )
        }
    }

    struct Persisted: Codable, Equatable, Sendable {
        var visible: Bool
        var width: Double
        var rootMode: FilesPanelRootMode
        var pinnedRoot: String?
        var showHidden: Bool
    }

    init(seed: Seed) {
        visible = seed.visible
        width = min(max(seed.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        rootMode = seed.rootMode
        pinnedRoot = seed.pinnedRoot
        showHidden = seed.showHidden
    }

    var persisted: Persisted {
        .init(visible: visible, width: width, rootMode: rootMode, pinnedRoot: pinnedRoot, showHidden: showHidden)
    }
}
