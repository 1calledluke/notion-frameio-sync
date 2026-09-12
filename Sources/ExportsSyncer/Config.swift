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
    var commentsPollSeconds: Double = 900

    // MARK: - Decoding

    init() {}

    /// Decodes field-by-field, falling back to the property default for any key that
    /// is absent. The synthesized Decodable throws on a missing key, which meant that
    /// adding one new field made an existing config.json fail to decode entirely —
    /// the app then ran on all-defaults and the next save overwrote the real settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        assetsRoot          = try c.decodeIfPresent(String.self, forKey: .assetsRoot)          ?? d.assetsRoot
        exportsRoot         = try c.decodeIfPresent(String.self, forKey: .exportsRoot)         ?? d.exportsRoot
        notionToken         = try c.decodeIfPresent(String.self, forKey: .notionToken)         ?? d.notionToken
        frameioClientID     = try c.decodeIfPresent(String.self, forKey: .frameioClientID)     ?? d.frameioClientID
        frameioAccountID    = try c.decodeIfPresent(String.self, forKey: .frameioAccountID)    ?? d.frameioAccountID
        frameioRootFolderID = try c.decodeIfPresent(String.self, forKey: .frameioRootFolderID) ?? d.frameioRootFolderID
        notionClientsDB     = try c.decodeIfPresent(String.self, forKey: .notionClientsDB)     ?? d.notionClientsDB
        notionProjectsDB    = try c.decodeIfPresent(String.self, forKey: .notionProjectsDB)    ?? d.notionProjectsDB
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        notionTasksDB       = try c.decodeIfPresent(String.self, forKey: .notionTasksDB)       ?? d.notionTasksDB
        commentsPollSeconds = try c.decodeIfPresent(Double.self, forKey: .commentsPollSeconds) ?? d.commentsPollSeconds
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExportsSyncer/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Config()   // no file yet — first run
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // The file exists but is unreadable. Preserve it instead of letting a
            // later save overwrite it with defaults.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("config.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            Log("Config: FAILED to parse config.json — \(error). Saved a copy to \(backup.lastPathComponent). Running on defaults; re-enter settings before saving.")
            return Config()
        }
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
