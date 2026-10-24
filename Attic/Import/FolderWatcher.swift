import Foundation

/// Watches Documents (Files › Attic) and imports whatever lands there.
@MainActor
final class FolderWatcher {
    private let paths: LibraryPaths
    private let coordinator: ImportCoordinator
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: Task<Void, Never>?
    /// Sizes from the previous scan, to wait until a copy has finished.
    private var lastSizes: [String: Int64] = [:]
    private let processedKey = "processedDocuments"

    init(paths: LibraryPaths = .shared, coordinator: ImportCoordinator) {
        self.paths = paths
        self.coordinator = coordinator
    }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let descriptor = open(paths.documents.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        scheduleScan(after: 0.2)
    }

    func stop() {
        source?.cancel()
        source = nil
        pendingScan?.cancel()
    }

    func scheduleScan(after delay: TimeInterval = 1.5) {
        pendingScan?.cancel()
        pendingScan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? fileManager.contentsOfDirectory(at: paths.documents, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { return }
        var processed = Set(UserDefaults.standard.stringArray(forKey: processedKey) ?? [])
        var stillCopying = false

        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let signature = "\(url.lastPathComponent)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            guard !processed.contains(signature) else { continue }
            if lastSizes[url.path] != size {
                lastSizes[url.path] = size
                stillCopying = true
                continue
            }
            processed.insert(signature)
            lastSizes[url.path] = nil
            coordinator.enqueue(.init(url: url, ownsSource: true, interactive: false))
        }
        UserDefaults.standard.set(Array(processed.suffix(500)), forKey: processedKey)
        if stillCopying {
            scheduleScan(after: 1.5)
        }
    }
}
