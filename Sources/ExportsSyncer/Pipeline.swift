import Foundation

/// Orchestrates the full upload pipeline for a single file:
///   ffprobe check → unchanged check → Frame.io folder resolution → upload →
///   version stack → share links → Notion comment
final class Pipeline: @unchecked Sendable {

    private let coordinator: Coordinator
    private let frameio = FrameioClient()
    private var rootFolderID: String = ""

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func process(filePath: String) {
        guard coordinator.config.isConfigured else {
            Log("Pipeline: app not fully configured — skipping \(filePath)")
            return
        }
        let cfg = coordinator.config
        Task {
            do {
                try await run(filePath: filePath, cfg: cfg)
            } catch let err as AuthError {
                Log("Pipeline: auth error — \(err.localizedDescription)")
                await MainActor.run {
                    self.coordinator.setNeedsAttention(reason: err.localizedDescription)
                }
            } catch {
                Log("Pipeline: error processing \(filePath) — \(error)")
            }
        }
    }

    // MARK: - Main pipeline

    private func run(filePath: String, cfg: Config) async throws {
        let ledger = coordinator.ledger

        // 1. ffprobe integrity check (video only)
        let fileExt = (filePath as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = ["mov", "mp4", "mxf", "avi", "m4v", "braw", "mts", "m2ts", "mkv"]
        if videoExts.contains(fileExt) {
            guard ffprobeOK(path: filePath) else {
                Log("Pipeline: ffprobe failed for \(filePath) — will retry on next settle")
                return
            }
        }

        // 2. Relative path = the deliverable's identity in the ledger
        let exportsRoot = cfg.exportsRoot
        let relPath = relativePath(filePath, under: exportsRoot)
        let existing = ledger.deliverable(relPath: relPath)

        // 3. Unchanged since the last upload? Then this "settle" is Dropbox
        //    touching metadata, a re-save with identical bytes, or a second
        //    settle of the same write — not a new version. This is what
        //    turned one export into "v2" with a broken version stack.
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let ex = existing, ex.frameioFileID != nil,
           ex.lastSize == size, ex.lastMtime == mtime {
            Log("Pipeline: unchanged since last upload — skipping \(relPath)")
            return
        }

        // 4. Resolve Frame.io account + root folder
        let token = try await AuthManager.shared.validAccessToken()
        frameio.setAccountID(cfg.frameioAccountID)
        let rootID: String
        if cfg.frameioRootFolderID.isEmpty {
            rootID = try await frameio.ensureRootFolderID(token: token)
        } else {
            rootID = (try? await frameio.projectRootFolderID(token: token, projectID: cfg.frameioRootFolderID)) ?? cfg.frameioRootFolderID
        }
        frameio.setRootFolderID(rootID)

        // 5. Work out where this file belongs: which Notion project (if any),
        //    which client, and which subfolders under the project.
        let projects = NotionAPI.allProjects(token: cfg.notionToken, databaseID: cfg.notionProjectsDB)
        let placement = Self.resolvePlacement(relPath: relPath, projects: projects)

        // Every export belongs to a Notion project — that's the rule of the
        // tool. An unmatched file is held, not guessed into a folder: warn,
        // and it goes through as soon as it's moved into a project folder.
        guard let project = placement.project, let clientID = project.clientID else {
            let folder = (relPath as NSString).deletingLastPathComponent
            let why = placement.project == nil
                ? "no Notion project matches the folder “\(folder)”"
                : "the Notion project “\(placement.project!.name)” has no Client set"
            Notifier.report(reason: "unmatched:\(relPath)",
                            "NOT uploaded: \(baseName(relPath)) — \(why). Move it into a project folder with the job code in the name (or set the Client in Notion) and it will sync automatically.")
            await MainActor.run {
                self.coordinator.setNeedsAttention(reason: "Export not linked to a Notion project: \(self.baseName(relPath))")
            }
            return
        }

        // 6. Find or create the Frame.io folder tree
        let tree = try await resolveFrameioFolders(token: token, placement: placement, rootID: rootID)

        // 7. Upload. A re-export goes back into the folder its first version
        //    lives in (so version stacking works) unless that folder is gone.
        let fileURL = URL(fileURLWithPath: filePath)
        let filename = fileURL.lastPathComponent
        var targetFolderID = existing?.frameioProjectFolderID ?? tree.uploadFolderID
        var record = existing ?? Ledger.DeliverableRecord(
            versionCount: 0, frameioFileID: nil, frameioStackID: nil,
            frameioProjectFolderID: tree.uploadFolderID)

        let uploaded: FrameioClient.UploadedFile
        do {
            uploaded = try await frameio.uploadFile(token: token, fileURL: fileURL, folderID: targetFolderID)
        } catch FrameioError.httpError(404, _) where targetFolderID != tree.uploadFolderID {
            Log("Pipeline: previous Frame.io folder is gone — uploading \(filename) fresh")
            targetFolderID = tree.uploadFolderID
            record.frameioFileID = nil
            record.frameioStackID = nil
            uploaded = try await frameio.uploadFile(token: token, fileURL: fileURL, folderID: targetFolderID)
        }

        // 8. Version stacking
        let newVersionCount = record.versionCount + 1
        if let existingFileID = record.frameioFileID {
            do {
                if let stackID = record.frameioStackID {
                    try await frameio.addToVersionStack(token: token, stackID: stackID, newFileID: uploaded.id)
                } else {
                    record.frameioStackID = try await frameio.createVersionStack(
                        token: token, folderID: targetFolderID,
                        originalFileID: existingFileID, newFileID: uploaded.id)
                }
            } catch {
                Log("Pipeline: version stack failed (non-fatal) — \(error)")
                record.frameioStackID = nil
            }
        }

        record.versionCount = newVersionCount
        record.frameioFileID = uploaded.id
        record.frameioProjectFolderID = targetFolderID
        record.lastSize = size
        record.lastMtime = mtime
        ledger.upsertDeliverable(relPath: relPath, record: record)

        // 9. Share links + Notion comment
        if let projectFolderID = tree.projectFolderID {
            do {
                try await ensureShareLinks(token: token, cfg: cfg,
                                           clientFolderID: tree.clientFolderID,
                                           projectFolderID: projectFolderID,
                                           project: project, clientID: clientID,
                                           clientFolderName: placement.clientFolderName)
            } catch {
                Log("Pipeline: share link creation failed (non-fatal) — \(error)")
            }
        }
        let commentText = newVersionCount > 1
            ? "A new version of \(filename) uploaded"
            : "\(filename) uploaded"
        NotionAPI.postComment(token: cfg.notionToken, pageID: project.id, text: commentText)
        // A previously-held file that now matched: clear the menu-bar warning.
        await MainActor.run { self.coordinator.clearAttention() }

        let summary = "\(filename) v\(newVersionCount) → Frame.io"
        Log("Pipeline: done — \(summary)")
        await MainActor.run { self.coordinator.notifyActivity(summary) }
    }

    // MARK: - Placement: path → client / project / subfolders

    struct Placement {
        var parentFolderName: String?   // client nested under an agency ("Revel Advertising/Wilmington Beaches")
        var clientFolderName: String
        var project: NotionProject?     // nil when nothing in the path matched
        var subfolders: [String]        // folders below the project (or below the client if unmatched)
    }

    /// The project folder is the FIRST path segment that matches a Notion
    /// project — by job code first, then by name. Everything before it is the
    /// client (and optionally the client's parent); everything after it is a
    /// subfolder that gets mirrored in Frame.io. Nothing matched → the file
    /// mirrors its folder path under the first segment as the client.
    ///
    /// Before this, a 4-deep path like client/project/Promos/Vertical/file was
    /// read as parent/client/project and "Vertical" became a Notion project.
    static func resolvePlacement(relPath: String, projects: [NotionProject]) -> Placement {
        let segs = relPath.split(separator: "/").map(String.init).dropLast()   // folders only
        let folders = Array(segs)

        for (i, seg) in folders.enumerated() {
            guard let project = matchProject(seg, in: projects) else { continue }
            let before = Array(folders[..<i])
            let client = before.last ?? seg
            let parent = before.count >= 2 ? before[before.count - 2] : nil
            return Placement(parentFolderName: parent, clientFolderName: client,
                             project: project, subfolders: Array(folders[(i + 1)...]))
        }
        return Placement(parentFolderName: nil,
                         clientFolderName: folders.first ?? "Untracked",
                         project: nil,
                         subfolders: Array(folders.dropFirst()))
    }

    /// Job code wins ("…_0095", "AMP-0012"); a name match needs the whole
    /// compacted project name inside the folder name.
    static func matchProject(_ folder: String, in projects: [NotionProject]) -> NotionProject? {
        let compact = folder.filter { !$0.isWhitespace }.lowercased()
        for p in projects where !p.jobCode.isEmpty {
            let code = p.jobCode.lowercased()
            if compact == code || compact.hasSuffix("_" + code) || compact.contains("_" + code + "_") {
                return p
            }
        }
        for p in projects {
            let name = p.name.filter { !$0.isWhitespace }.lowercased()
            guard name.count >= 3, compact.contains(name) else { continue }
            return p
        }
        return nil
    }

    // MARK: - Frame.io folder resolution

    struct FolderTree {
        let clientFolderID: String
        let projectFolderID: String?
        let uploadFolderID: String      // deepest folder — where the file goes
    }

    private func resolveFrameioFolders(token: String, placement: Placement,
                                       rootID: String) async throws -> FolderTree {
        let ledger = coordinator.ledger

        var parentID = rootID
        if let parent = placement.parentFolderName {
            parentID = try await frameio.findOrCreateFolder(token: token, name: parent, parentID: rootID).id
        }
        let clientFolder = try await frameio.findOrCreateFolder(
            token: token, name: placement.clientFolderName, parentID: parentID)

        var projectFolderID: String? = nil
        var cursor = clientFolder.id
        if let project = placement.project {
            let projectFolder = try await frameio.findOrCreateFolder(
                token: token, name: project.name, parentID: clientFolder.id)
            projectFolderID = projectFolder.id
            cursor = projectFolder.id

            if let cid = project.clientID {
                if ledger.frameioFolder(clientID: cid, projectID: nil) == nil {
                    ledger.upsertFrameioFolder(clientID: cid, projectID: nil,
                                               folderID: clientFolder.id, shareLink: nil)
                }
                if ledger.frameioFolder(clientID: cid, projectID: project.id) == nil {
                    ledger.upsertFrameioFolder(clientID: cid, projectID: project.id,
                                               folderID: projectFolder.id, shareLink: nil)
                }
            }
        }

        // Mirror any deeper local folders ("JBITS 2026 Promos/Vertical").
        for sub in placement.subfolders {
            cursor = try await frameio.findOrCreateFolder(token: token, name: sub, parentID: cursor).id
        }

        return FolderTree(clientFolderID: clientFolder.id,
                          projectFolderID: projectFolderID,
                          uploadFolderID: cursor)
    }

    // MARK: - Share links

    private func ensureShareLinks(token: String, cfg: Config,
                                  clientFolderID: String, projectFolderID: String,
                                  project: NotionProject, clientID: String,
                                  clientFolderName: String) async throws {
        let ledger = coordinator.ledger

        // Project-level share: once per project, or again if Notion lost it.
        let projectRecord = ledger.frameioFolder(clientID: clientID, projectID: project.id)
        let notionLinkMissing = project.reviewLink?.isEmpty ?? true
        if (projectRecord?.shareLink?.isEmpty ?? true) || notionLinkMissing {
            if let link = projectRecord?.shareLink, !link.isEmpty, notionLinkMissing {
                // We have a link; Notion just doesn't. Reuse it, don't mint another.
                NotionAPI.updateProjectReviewLink(token: cfg.notionToken, pageID: project.id, link: link)
                Log("Pipeline: restored project review link in Notion → \(link)")
            } else {
                let share = try await frameio.createShare(token: token, folderID: projectFolderID,
                                                          name: "\(project.name) - Client Review")
                ledger.upsertFrameioFolder(clientID: clientID, projectID: project.id,
                                           folderID: projectFolderID, shareLink: share.url)
                NotionAPI.updateProjectReviewLink(token: cfg.notionToken, pageID: project.id, link: share.url)
                Log("Pipeline: created project share → \(share.url)")
            }
        }

        // Client-level share: once per client, ever. (The ledger lookup used
        // to return an old link-less row, so every upload minted a new
        // "All Projects" link and overwrote the one in Notion.)
        let clientRecord = ledger.frameioFolder(clientID: clientID, projectID: nil)
        if clientRecord?.shareLink?.isEmpty ?? true {
            let share = try await frameio.createShare(token: token, folderID: clientFolderID,
                                                      name: "\(clientFolderName) — All Projects")
            ledger.upsertFrameioFolder(clientID: clientID, projectID: nil,
                                       folderID: clientFolderID, shareLink: share.url)
            NotionAPI.updateClientFrameioLink(token: cfg.notionToken, pageID: clientID, link: share.url)
            Log("Pipeline: created client share → \(share.url)")
        }
    }

    // MARK: - Helpers

    private func baseName(_ relPath: String) -> String {
        (relPath as NSString).lastPathComponent
    }

    private func relativePath(_ path: String, under root: String) -> String {
        var r = root
        if !r.hasSuffix("/") { r += "/" }
        if path.hasPrefix(r) { return String(path.dropFirst(r.count)) }
        return (path as NSString).lastPathComponent
    }

    private func ffprobeOK(path: String) -> Bool {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe",
                          "/usr/bin/ffprobe"]
        guard let ffprobe = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            Log("Pipeline: ffprobe not found — skipping integrity check")
            return true // don't block if not installed
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = ["-v", "error", "-show_entries", "format=duration",
                          "-of", "default=noprint_wrappers=1", path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let ok = proc.terminationStatus == 0
            if !ok { Log("Pipeline: ffprobe returned error for \(path)") }
            return ok
        } catch {
            Log("Pipeline: ffprobe launch failed — \(error)")
            return false
        }
    }
}
