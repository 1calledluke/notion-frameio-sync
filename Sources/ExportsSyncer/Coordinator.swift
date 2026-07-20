import Foundation

/// The central object that owns all long-running state and wires everything together.
/// AppDelegate holds the single instance; UI components hold a weak reference.
/// Always accessed from the main thread — @unchecked Sendable is safe here.
final class Coordinator: @unchecked Sendable {

    var config: Config
    let ledger: Ledger
    let frameio = FrameioClient()
    private var watcher: ExportsWatcher!
    private var pipeline: Pipeline!
    private var poller: ProjectPoller!

    private(set) var isPaused = false
    private(set) var needsAttention = false
    private(set) var attentionReason: String = ""

    var onActivityChanged: (() -> Void)?

    init() {
        config = Config.load()

        // Ledger lives alongside the Dropbox tree when configured;
        // falls back to Application Support during initial setup.
        let ledgerPath: String
        if !config.exportsRoot.isEmpty {
            ledgerPath = (config.exportsRoot as NSString)
                .appendingPathComponent(".ivp-ledger.db")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            ledgerPath = support.appendingPathComponent("ExportsSyncer/ledger.db").path
        }

        ledger = (try? Ledger(atPath: ledgerPath)) ?? {
            fatalError("Failed to open ledger at \(ledgerPath)")
        }()

        watcher = ExportsWatcher { [weak self] path in
            Task { @MainActor in
                guard let self = self, !self.isPaused else { return }
                self.pipeline.process(filePath: path)
            }
        }

        pipeline = Pipeline(coordinator: self)
        poller   = ProjectPoller(coordinator: self)
    }

    func start() {
        guard config.isConfigured else {
            Log("Coordinator: not configured — watching deferred")
            return
        }
        applyConfig()
    }

    func applyConfig(newConfig: Config? = nil) {
        if let cfg = newConfig {
            config = cfg
            cfg.save()
        }
        if !config.exportsRoot.isEmpty {
            watcher.start(root: config.exportsRoot)
        }
        poller.stop()
        poller.start()
        frameio_setAccountID()
        Log("Coordinator: running — exports root: \(config.exportsRoot)")
        onActivityChanged?()
    }

    func pause() {
        isPaused = true
        Log("Coordinator: paused")
        onActivityChanged?()
    }

    func resume() {
        isPaused = false
        Log("Coordinator: resumed")
        onActivityChanged?()
    }

    func setNeedsAttention(reason: String) {
        needsAttention = true
        attentionReason = reason
        Log("Coordinator: needs attention — \(reason)")
        onActivityChanged?()
    }

    func clearAttention() {
        needsAttention = false
        attentionReason = ""
        onActivityChanged?()
    }

    func notifyActivity(_ message: String) {
        Log("Activity: \(message)")
        onActivityChanged?()
    }

    private func frameio_setAccountID() {
        guard !config.frameioAccountID.isEmpty else { return }
        frameio.setAccountID(config.frameioAccountID)
        frameio.setRootFolderID(config.frameioRootFolderID)
    }
}
