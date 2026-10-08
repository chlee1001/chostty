import CoreServices
import Foundation

final class FilesPanelWatchBroker: @unchecked Sendable {
    typealias Handler = @Sendable (Set<String>?) -> Void

    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private weak var broker: FilesPanelWatchBroker?
        private var root: String?
        private let id: UUID

        fileprivate init(broker: FilesPanelWatchBroker, root: String, id: UUID) {
            self.broker = broker
            self.root = root
            self.id = id
        }

        func cancel() {
            let target: (FilesPanelWatchBroker, String)? = lock.withLock {
                guard let broker, let root else { return nil }
                self.root = nil
                return (broker, root)
            }
            guard let target else { return }
            target.0.unsubscribe(root: target.1, id: id)
        }

        deinit { cancel() }
    }

    private final class CallbackBox: @unchecked Sendable {
        weak var broker: FilesPanelWatchBroker?
        let root: String

        init(broker: FilesPanelWatchBroker, root: String) {
            self.broker = broker
            self.root = root
        }
    }

    private final class Entry: @unchecked Sendable {
        let stream: FSEventStreamRef
        let callbackBox: CallbackBox
        var handlers: [UUID: Handler]
        var debounceWorkItem: DispatchWorkItem?

        init(stream: FSEventStreamRef, callbackBox: CallbackBox, id: UUID, handler: @escaping Handler) {
            self.stream = stream
            self.callbackBox = callbackBox
            self.handlers = [id: handler]
        }
    }

    private static let debounceInterval: TimeInterval = 0.3
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kr.co.devch.chostty.files-panel.watch", qos: .utility)
    private var entries: [String: Entry] = [:]

    func subscribe(root: String, onChange: @escaping Handler) -> Subscription? {
        let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let id = UUID()

        let subscription: Subscription? = lock.withLock {
            if let entry = entries[canonicalRoot] {
                entry.handlers[id] = onChange
                return Subscription(broker: self, root: canonicalRoot, id: id)
            }

            let box = CallbackBox(broker: self, root: canonicalRoot)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard let stream = FSEventStreamCreate(
                nil,
                Self.callback,
                &context,
                [canonicalRoot] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.debounceInterval,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagWatchRoot |
                    kFSEventStreamCreateFlagUseCFTypes
                )
            ) else { return nil }

            let entry = Entry(stream: stream, callbackBox: box, id: id, handler: onChange)
            entries[canonicalRoot] = entry
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                entries.removeValue(forKey: canonicalRoot)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return nil
            }
            return Subscription(broker: self, root: canonicalRoot, id: id)
        }

        return subscription
    }

    func subscriberCount(for root: String) -> Int {
        let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock { entries[canonicalRoot]?.handlers.count ?? 0 }
    }

    var activeStreamCount: Int { lock.withLock { entries.count } }

    static func isBroadRoot(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        return root == "/" || root == home
    }

    private func unsubscribe(root: String, id: UUID) {
        let entryToStop: Entry? = lock.withLock {
            guard let entry = entries[root] else { return nil }
            entry.handlers.removeValue(forKey: id)
            guard entry.handlers.isEmpty else { return nil }
            entry.debounceWorkItem?.cancel()
            entries.removeValue(forKey: root)
            return entry
        }
        guard let entryToStop else { return }
        FSEventStreamStop(entryToStop.stream)
        FSEventStreamInvalidate(entryToStop.stream)
        FSEventStreamRelease(entryToStop.stream)
    }

    private func receive(root: String, paths: Set<String>?) {
        lock.withLock {
            guard let entry = entries[root] else { return }
            entry.debounceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.deliver(root: root, paths: paths) }
            entry.debounceWorkItem = item
            queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
        }
    }

    private func deliver(root: String, paths: Set<String>?) {
        let handlers: [Handler] = lock.withLock {
            guard let entry = entries[root] else { return [] }
            entry.debounceWorkItem = nil
            return Array(entry.handlers.values)
        }
        handlers.forEach { $0(paths) }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = (eventPaths as? [String]).map { Set($0.prefix(count)) }
        box.broker?.receive(root: box.root, paths: paths)
    }
}
