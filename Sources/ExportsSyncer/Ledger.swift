import Foundation
import SQLite3

// Swift doesn't bridge SQLITE_TRANSIENT automatically
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed ledger stored alongside the Dropbox tree so it travels with
/// the data when switching machines. All paths are relative to the configured
/// roots so the ledger remains valid after the root setting is repointed.
///
/// Tables:
///   provisioned_projects  — projects whose local folder skeletons have been created
///   deliverables          — per-file upload history: version counter, Frame.io IDs
final class Ledger: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ivp.exports-syncer.ledger")

    // MARK: - Init

    init(atPath path: String) throws {
        try queue.sync {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir,
                                                    withIntermediateDirectories: true)
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                throw LedgerError.openFailed(String(cString: sqlite3_errmsg(db)))
            }
            try self.migrate()
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func migrate() throws {
        let stmts = [
            """
            CREATE TABLE IF NOT EXISTS provisioned_projects (
                notion_project_id TEXT PRIMARY KEY,
                assets_rel_path   TEXT NOT NULL,
                exports_rel_path  TEXT NOT NULL,
                created_at        TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS deliverables (
                rel_path            TEXT PRIMARY KEY,
                version_count       INTEGER NOT NULL DEFAULT 1,
                frameio_file_id     TEXT,
                frameio_stack_id    TEXT,
                frameio_project_folder_id TEXT,
                last_uploaded_at    TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS frameio_folders (
                notion_client_id    TEXT NOT NULL,
                notion_project_id   TEXT,
                frameio_folder_id   TEXT NOT NULL,
                share_link          TEXT,
                PRIMARY KEY (notion_client_id, notion_project_id)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS project_status (
                notion_project_id TEXT PRIMARY KEY,
                last_status       TEXT NOT NULL,
                updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS seen_comments (
                comment_id  TEXT PRIMARY KEY,
                task_created INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """
        ]
        for sql in stmts {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw LedgerError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }

        // Additive columns — "duplicate column" on an already-migrated file
        // is expected and ignored.
        for sql in [
            "ALTER TABLE deliverables ADD COLUMN last_size INTEGER",
            "ALTER TABLE deliverables ADD COLUMN last_mtime REAL",
            "ALTER TABLE deliverables ADD COLUMN comments_gone INTEGER NOT NULL DEFAULT 0",
        ] {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        // One-time cleanup: the client-level row (NULL project) was never
        // replaced by INSERT OR REPLACE because NULL ≠ NULL in a primary key,
        // so each client accumulated a dozen rows with a dozen share links.
        // Keep only the newest linked row per client; the link-less seed row
        // survives only where no linked row exists.
        let dedupe = """
            DELETE FROM frameio_folders
            WHERE notion_project_id IS NULL
              AND notion_client_id IN (
                  SELECT notion_client_id FROM frameio_folders
                  WHERE notion_project_id IS NULL AND share_link IS NOT NULL AND share_link != '')
              AND rowid NOT IN (
                  SELECT MAX(rowid) FROM frameio_folders
                  WHERE notion_project_id IS NULL AND share_link IS NOT NULL AND share_link != ''
                  GROUP BY notion_client_id)
        """
        sqlite3_exec(db, dedupe, nil, nil, nil)
    }

    // MARK: - Provisioned projects

    func isProvisioned(notionProjectID: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT 1 FROM provisioned_projects WHERE notion_project_id = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, notionProjectID, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func markProvisioned(notionProjectID: String, assetsRelPath: String, exportsRelPath: String) {
        queue.sync {
            let sql = """
                INSERT OR REPLACE INTO provisioned_projects
                  (notion_project_id, assets_rel_path, exports_rel_path)
                VALUES (?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, notionProjectID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, assetsRelPath,   -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, exportsRelPath,  -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Project status tracking (for Active-transition detection)

    /// Returns the last status we recorded for this project, or nil if we've
    /// never seen it before (used to establish a baseline without provisioning).
    func lastStatus(notionProjectID: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT last_status FROM project_status WHERE notion_project_id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, notionProjectID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return colText(stmt, 0)
        }
    }

    func setStatus(notionProjectID: String, status: String) {
        queue.sync {
            let sql = """
                INSERT OR REPLACE INTO project_status
                  (notion_project_id, last_status, updated_at)
                VALUES (?, ?, datetime('now'))
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, notionProjectID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, status,          -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Deliverables

    struct DeliverableRecord {
        var versionCount: Int
        var frameioFileID: String?
        var frameioStackID: String?
        var frameioProjectFolderID: String?
        /// Size + mtime of the bytes last uploaded, so a re-settle of the
        /// same file is recognised and not uploaded as a new version.
        var lastSize: Int64? = nil
        var lastMtime: Double? = nil
    }

    func deliverable(relPath: String) -> DeliverableRecord? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT version_count, frameio_file_id, frameio_stack_id,
                       frameio_project_folder_id, last_size, last_mtime
                FROM deliverables WHERE rel_path = ?
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, relPath, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return DeliverableRecord(
                versionCount: Int(sqlite3_column_int(stmt, 0)),
                frameioFileID: colText(stmt, 1),
                frameioStackID: colText(stmt, 2),
                frameioProjectFolderID: colText(stmt, 3),
                lastSize: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4),
                lastMtime: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            )
        }
    }

    func upsertDeliverable(relPath: String, record: DeliverableRecord) {
        queue.sync {
            let sql = """
                INSERT OR REPLACE INTO deliverables
                  (rel_path, version_count, frameio_file_id, frameio_stack_id,
                   frameio_project_folder_id, last_uploaded_at, last_size, last_mtime, comments_gone)
                VALUES (?, ?, ?, ?, ?, datetime('now'), ?, ?, 0)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, relPath,  -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(record.versionCount))
            bindOptional(stmt, 3, record.frameioFileID)
            bindOptional(stmt, 4, record.frameioStackID)
            bindOptional(stmt, 5, record.frameioProjectFolderID)
            if let s = record.lastSize { sqlite3_bind_int64(stmt, 6, s) } else { sqlite3_bind_null(stmt, 6) }
            if let m = record.lastMtime { sqlite3_bind_double(stmt, 7, m) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_step(stmt)
        }
    }

    /// A file that Frame.io says no longer exists: stop asking it for
    /// comments. Every deleted file was costing a 404 per pass forever.
    func markFileGone(fileID: String) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE deliverables SET comments_gone = 1 WHERE frameio_file_id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, fileID, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Comment tracking (Frame.io comments -> Notion tasks)

    /// Files worth polling for comments: uploaded in the last 30 days and not
    /// known to be deleted. Clients comment on this month's cut, not on
    /// headshots from the spring — and the whole ledger was 242 requests
    /// per pass, which is what tripped Frame.io's rate limit all day
    /// (60 days still left 211 files and ~50 429s per pass).
    func allUploadedFiles() -> [(relPath: String, fileID: String)] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT rel_path, frameio_file_id FROM deliverables
                WHERE frameio_file_id IS NOT NULL
                  AND COALESCE(comments_gone, 0) = 0
                  AND last_uploaded_at > datetime('now', '-30 days')
                ORDER BY last_uploaded_at DESC
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var out: [(String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let rel = colText(stmt, 0), let fid = colText(stmt, 1) {
                    out.append((rel, fid))
                }
            }
            return out
        }
    }

    func hasSeenComment(_ commentID: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT 1 FROM seen_comments WHERE comment_id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, commentID, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func markCommentSeen(_ commentID: String, taskCreated: Bool) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT OR REPLACE INTO seen_comments (comment_id, task_created) VALUES (?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, commentID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, taskCreated ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// Notion project for an exports-relative file path, via the provisioned
    /// project whose exports folder prefixes it (longest match wins).
    func projectID(forExportsRelPath relPath: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT notion_project_id, exports_rel_path FROM provisioned_projects"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            var best: (id: String, len: Int)? = nil
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let pid = colText(stmt, 0), let prefix = colText(stmt, 1) else { continue }
                if relPath.hasPrefix(prefix), prefix.count > (best?.len ?? -1) {
                    best = (pid, prefix.count)
                }
            }
            return best?.id
        }
    }

    // MARK: - Frame.io folder/share cache

    struct FolderRecord {
        var frameioFolderID: String
        var shareLink: String?
    }

    func frameioFolder(clientID: String, projectID: String?) -> FolderRecord? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            // Prefer a row that actually has a share link, newest first — an
            // old link-less seed row must never shadow the real one.
            let sql = """
                SELECT frameio_folder_id, share_link
                FROM frameio_folders
                WHERE notion_client_id = ? AND (notion_project_id = ? OR (notion_project_id IS NULL AND ? IS NULL))
                ORDER BY (share_link IS NULL OR share_link = '') ASC, rowid DESC
                LIMIT 1
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, clientID, -1, SQLITE_TRANSIENT)
            if let pid = projectID {
                sqlite3_bind_text(stmt, 2, pid, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, pid, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
                sqlite3_bind_null(stmt, 3)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return FolderRecord(frameioFolderID: String(cString: sqlite3_column_text(stmt, 0)),
                                shareLink: colText(stmt, 1))
        }
    }

    func upsertFrameioFolder(clientID: String, projectID: String?,
                              folderID: String, shareLink: String?) {
        queue.sync {
            // NULL never equals NULL, so INSERT OR REPLACE can't replace the
            // client-level row — clear it by hand first.
            if projectID == nil {
                var del: OpaquePointer?
                defer { sqlite3_finalize(del) }
                let delSQL = "DELETE FROM frameio_folders WHERE notion_client_id = ? AND notion_project_id IS NULL"
                if sqlite3_prepare_v2(db, delSQL, -1, &del, nil) == SQLITE_OK {
                    sqlite3_bind_text(del, 1, clientID, -1, SQLITE_TRANSIENT)
                    sqlite3_step(del)
                }
            }
            let sql = """
                INSERT OR REPLACE INTO frameio_folders
                  (notion_client_id, notion_project_id, frameio_folder_id, share_link)
                VALUES (?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, clientID, -1, SQLITE_TRANSIENT)
            bindOptional(stmt, 2, projectID)
            sqlite3_bind_text(stmt, 3, folderID, -1, SQLITE_TRANSIENT)
            bindOptional(stmt, 4, shareLink)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Helpers

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cstr)
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ col: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, col, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, col)
        }
    }
}

enum LedgerError: Error {
    case openFailed(String)
    case execFailed(String)
}
