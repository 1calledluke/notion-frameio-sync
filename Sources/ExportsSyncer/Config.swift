import Foundation

/// User-facing settings stored in Application Support.
/// All paths here are absolute — the ledger stores paths relative to these roots.
struct Config: Codable {
    /// Absolute path to the Assets root, e.g. "/Users/luke/Dropbox/01_Index Video"
    var assetsRoot: String = ""
    /// Absolute path to the Exports root, e.g. "/Users/luke/Dropbox/06_Exports"
    var exportsRoot: String = ""
    /// Notion internal integration token
    var notionToken: String = ""
    /// Frame.io (Adobe) OAuth client ID for the PKCE flow — set in config.json,
    /// never committed to source control
    var frameioClientID: String = ""
    /// Frame.io V4 account ID (populated after first successful auth)
    var frameioAccountID: String = ""
    /// Frame.io project/folder ID to use as the upload root (e.g. "Dropbox Sync" project)
    var frameioRootFolderID: String = ""
    /// Notion Clients database ID
    var notionClientsDB: String = "232714d3-333f-8086-a62e-000ba0db43d2"
    /// Notion Projects database ID
    var notionProjectsDB: String = "232714d3-333f-800b-8b27-000b178352f3"
    /// How often (seconds) to poll Notion for newly-activated projects
    var pollIntervalSeconds: Double = 90
    /// Notion Tasks database ID (Frame.io comments become tasks here)
    var notionTasksDB: String = "232714d3-333f-8042-8de7-d13c03d2ea6e"
    /// How often (seconds) to poll Frame.io for new client comments; 0 disables
    var commentsPollSeconds: Double = 300

    // MARK: - Persistence

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExportsSyncer/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func save() {
        let url = Config.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url)
        }
    }

    var isConfigured: Bool {
        !assetsRoot.isEmpty && !exportsRoot.isEmpty && !notionToken.isEmpty
    }
}
