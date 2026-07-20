import Foundation
import CoreServices

/// Watches the Exports root via FSEvents and fires a callback when a file has
/// been stable for 30 seconds (quiet timer debounce).
final class ExportsWatcher: @unchecked Sendable {

    private var streamRef: FSEventStreamRef?
    private let debounceSeconds: TimeInterval = 30
    private var pendingTimers: [String: Timer] = [:]
    private let queue = DispatchQueue(label: "com.ivp.exports-syncer.fsevent",
                                      qos: .background)
    private var watchRoot: String = ""
    private let onFileReady: (String) -> Void // abs path

    // Ignore these — Dropbox artifacts and Resolve internals
    private let ignoredPatterns: [String] = [
        "(conflicted copy)",
        ".dropbox",
        ".dropbox.cache",
        ".syncprojectinfo.json",
        ".blackmagicsync",
        ".DS_Store"
    ]

    // Extensions explicitly excluded (system/app artifacts with no upload value)
    static let excludedExtensions: Set<String> = [
        "tmp", "part", "crdownload", "download", "lock", "lrv", "thm"
    ]

    init(onFileReady: @escaping (String) -> Void) {
        self.onFileReady = onFileReady
    }

    func start(root: String) {
        stop()
        watchRoot = root
        guard FileManager.default.fileExists(atPath: root) else {
            Log("ExportsWatcher: root path not found — \(root)")
            return
        }

        let paths = [root] as CFArray
        // Retain self for the lifetime of the stream so the C callback can never
        // dereference a freed watcher. Balanced by the release callback, which
        // FSEvents invokes when the stream is released in stop().
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { rawInfo in
                guard let rawInfo = rawInfo else { return }
                Unmanaged<ExportsWatcher>.fromOpaque(rawInfo).release()
            },
            copyDescription: nil
        )
        streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, _, _ in
                guard let info = info, numEvents > 0 else { return }
                let watcher = Unmanaged<ExportsWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let count = CFArrayGetCount(cfArray)
                // Extract paths at the CoreFoundation level — avoid NSArray subscript
                // bridging, which segfaults on the FileEvents path array.
                var extracted: [String] = []
                extracted.reserveCapacity(count)
                for i in 0..<count {
                    guard let raw = CFArrayGetValueAtIndex(cfArray, i) else { continue }
                    let cfStr = unsafeBitCast(raw, to: CFString.self)
                    extracted.append(cfStr as String)
                }
                for path in extracted {
                    watcher.handleEvent(path: path)
                }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,    // latency seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagNoDefer |
                                     kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream = streamRef else {
            Log("ExportsWatcher: failed to create stream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        Log("ExportsWatcher: watching \(root)")
    }

    func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        pendingTimers.values.forEach { $0.invalidate() }
        pendingTimers.removeAll()
    }

    // MARK: - Event handling

    private func handleEvent(path: String) {
        guard shouldProcess(path: path) else { return }

        // Start debounce timer on first event; ignore subsequent events while timer is pending
        DispatchQueue.main.async {
            guard self.pendingTimers[path] == nil else { return }
            self.pendingTimers[path] = Timer.scheduledTimer(
                withTimeInterval: self.debounceSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.pendingTimers.removeValue(forKey: path)
                self?.fileSettled(path: path)
            }
        }
    }

    private func shouldProcess(path: String) -> Bool {
        let lower = path.lowercased()
        for pattern in ignoredPatterns {
            if lower.contains(pattern.lowercased()) { return false }
        }
        // Skip hidden files, macOS custom-folder Icon files, and known artifact extensions
        let filename = (path as NSString).lastPathComponent
        guard !filename.hasPrefix(".") else { return false }
        guard filename != "Icon\r" && filename != "Icon" else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !Self.excludedExtensions.contains(ext) else { return false }
        // Must be a real file, not a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        return true
    }

    private func fileSettled(path: String) {
        // Final check: still exists and non-empty?
        guard FileManager.default.fileExists(atPath: path) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            Log("ExportsWatcher: skipping zero-byte file — \(path)")
            return
        }
        Log("ExportsWatcher: file settled — \(path)")
        onFileReady(path)
    }
}
