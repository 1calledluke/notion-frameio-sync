import Foundation

/// Orchestrates the full upload pipeline for a single file:
///   ffprobe check → Frame.io folder resolution → upload → version stack →
///   transcode poll → share links → Notion comment
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

        // 2. Resolve Frame.io account + root folder
        let token = try await AuthManager.shared.validAccessToken()
        frameio.setAccountID(cfg.frameioAccountID)
        let rootID: String
        if cfg.frameioRootFolderID.isEmpty {
            rootID = try await frameio.ensureRootFolderID(token: token)
        } else {
            rootID = (try? await frameio.projectRootFolderID(token: token, projectID: cfg.frameioRootFolderID)) ?? cfg.frameioRootFolderID
        }
        frameio.setRootFolderID(rootID)

        // 3. Determine relative path from exports root
        let exportsRoot = cfg.exportsRoot
        let relPath = relativePath(filePath, under: exportsRoot)

        // 4. Resolve the target Notion project from the path
        let folderContext = resolveFolderContext(relPath: relPath)

        // 5. Find or create Frame.io folder structure
        let (clientFolderID, projectFolderID, notionProject, notionClientID) =
            try await resolveFrameioFolders(token: token, cfg: cfg, context: folderContext, rootID: rootID)

        // 6. Upload
        let fileURL = URL(fileURLWithPath: filePath)
        let filename = fileURL.lastPathComponent
        let deliverableKey = relPath // relative path is the canonical deliverable key
        let existing = ledger.deliverable(relPath: deliverableKey)
        let uploaded = try await frameio.uploadFile(token: token, fileURL: fileURL,
                                                     folderID: projectFolderID)

        // 7. Version stacking
        var record = existing ?? Ledger.DeliverableRecord(
            versionCount: 0,
            frameioFileID: nil,
            frameioStackID: nil,
            frameioProjectFolderID: projectFolderID
        )
        let newVersionCount = record.versionCount + 1

        if let existingFileID = record.frameioFileID {
            do {
                if let stackID = record.frameioStackID {
                    // 3rd+ version: move onto existing stack
                    try await frameio.addToVersionStack(token: token, stackID: stackID,
                                                         newFileID: uploaded.id)
                } else {
                    // 2nd version: create stack
                    let stackID = try await frameio.createVersionStack(
                        token: token,
                        folderID: projectFolderID,
                        originalFileID: existingFileID,
                        newFileID: uploaded.id
                    )
                    record.frameioStackID = stackID
                }
            } catch {
                Log("Pipeline: version stack failed (non-fatal) — \(error)")
                // Clear stale stack ID so next upload tries fresh
                record.frameioStackID = nil
            }
        }

        record.versionCount = newVersionCount
        record.frameioFileID = uploaded.id
        record.frameioProjectFolderID = projectFolderID
        ledger.upsertDeliverable(relPath: deliverableKey, record: record)

        // 8. Share links (lazy: only on first upload for this project/client)
        do {
            try await ensureShareLinks(token: token, cfg: cfg,
                                        clientFolderID: clientFolderID,
                                        projectFolderID: projectFolderID,
                                        notionProject: notionProject,
                                        notionClientID: notionClientID,
                                        folderContext: folderContext)
        } catch {
            Log("Pipeline: share link creation failed (non-fatal) — \(error)")
        }

        // 9. Notion comment
        let commentText = newVersionCount > 1
            ? "A new version of \(filename) uploaded"
            : "\(filename) uploaded"
        if let pageID = notionProject?.id {
            NotionAPI.postComment(token: cfg.notionToken, pageID: pageID, text: commentText)
        }

        let summary = "\(filename) v\(newVersionCount) → Frame.io"
        Log("Pipeline: done — \(summary)")
        await MainActor.run { self.coordinator.notifyActivity(summary) }
    }

    // MARK: - Frame.io folder resolution

    struct FolderContext {
        var clientFolderName: String
        var projectFolderName: String
        var pathSegments: [String] // [parent?, client, project]
    }

    private func resolveFolderContext(relPath: String) -> FolderContext {
        let parts = relPath.split(separator: "/").map(String.init)
        // relPath could be: client/project/file.mov
        //                or parent/client/project/file.mov
        // File is always last; folder segments are everything before
        let folderParts = parts.dropLast() // remove filename

        switch folderParts.count {
        case 0, 1:
            let name = folderParts.first ?? "Untracked"
            return FolderContext(clientFolderName: name, projectFolderName: name,
                                 pathSegments: [name])
        case 2:
            let segs = Array(folderParts)
            return FolderContext(clientFolderName: segs[0], projectFolderName: segs[1],
                                 pathSegments: segs)
        default:
            let segs = Array(folderParts)
            // 3-level: parent/client/project or more
            return FolderContext(clientFolderName: segs[segs.count - 2],
                                 projectFolderName: segs[segs.count - 1],
                                 pathSegments: segs)
        }
    }

    private func resolveFrameioFolders(token: String, cfg: Config, context: FolderContext,
                                        rootID: String) async throws
        -> (clientFolderID: String, projectFolderID: String,
            notionProject: NotionProject?, notionClientID: String?)
    {
        let ledger = coordinator.ledger

        // Match to a Notion project: job code first, then sanitized name fallback
        var notionProject: NotionProject? = nil
        var notionClientID: String? = nil
        let projects = NotionAPI.allProjects(token: cfg.notionToken,
                                              databaseID: cfg.notionProjectsDB)
        let folderName = context.projectFolderName
        // Strip spaces from the folder name too, so "NCA Picnic" matches project "NCA Picnic"
        let folderNameCompact = folderName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined()
        for p in projects {
            // Primary: job code match (works if job code is in folder name)
            if !p.jobCode.isEmpty, folderName.contains(p.jobCode) {
                notionProject = p; notionClientID = p.clientID; break
            }
            // Fallback: sanitized project name match (spaces stripped, case-insensitive)
            let sanitized = p.name
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined()
            if !sanitized.isEmpty, folderNameCompact.localizedCaseInsensitiveContains(sanitized) {
                notionProject = p; notionClientID = p.clientID; break
            }
        }

        // Build Frame.io folder tree
        // For 3-level (parent/client/project), create parent first
        var parentID = rootID
        let segs = context.pathSegments

        if segs.count >= 3 {
            // Create/find parent client folder
            let parentFolder = try await frameio.findOrCreateFolder(
                token: token, name: segs[0], parentID: rootID)
            parentID = parentFolder.id
        }

        let clientName = context.clientFolderName
        let clientFolder = try await frameio.findOrCreateFolder(
            token: token, name: clientName, parentID: parentID)

        let projectFolderDisplayName = notionProject?.name ?? context.projectFolderName
        let projectFolder = try await frameio.findOrCreateFolder(
            token: token, name: projectFolderDisplayName, parentID: clientFolder.id)

        // Cache in ledger
        if let cid = notionClientID {
            if ledger.frameioFolder(clientID: cid, projectID: nil) == nil {
                ledger.upsertFrameioFolder(clientID: cid, projectID: nil,
                                            folderID: clientFolder.id, shareLink: nil)
            }
            if let pid = notionProject?.id,
               ledger.frameioFolder(clientID: cid, projectID: pid) == nil {
                ledger.upsertFrameioFolder(clientID: cid, projectID: pid,
                                            folderID: projectFolder.id, shareLink: nil)
            }
        }

        // Untracked fallback: auto-create Notion page
        if notionProject == nil {
            handleUntrackedUpload(cfg: cfg, context: context, clientFolderID: clientFolder.id,
                                   projectFolderID: projectFolder.id)
        }

        return (clientFolder.id, projectFolder.id, notionProject, notionClientID)
    }

    private func handleUntrackedUpload(cfg: Config, context: FolderContext,
                                        clientFolderID: String,
                                        projectFolderID: String) {
        Log("Pipeline: untracked upload — creating Notion page for '\(context.projectFolderName)'")

        // Match client by folder name against existing Notion clients
        // (exact match only — no fuzzy)
        let matchedClientID: String? = nil // defer to Notion lookup if needed

        if let pageID = NotionAPI.createProjectPage(
            token: cfg.notionToken,
            databaseID: cfg.notionProjectsDB,
            name: context.projectFolderName,
            clientID: matchedClientID,
            reviewLink: nil
        ) {
            let msg = "Someone exported and uploaded files to Frame.io — \(Date()). Please review and assign this project."
            NotionAPI.postComment(token: cfg.notionToken, pageID: pageID, text: msg)
        }
    }

    // MARK: - Share links

    private func ensureShareLinks(token: String, cfg: Config,
                                   clientFolderID: String,
                                   projectFolderID: String,
                                   notionProject: NotionProject?,
                                   notionClientID: String?,
                                   folderContext: FolderContext) async throws {
        let ledger = coordinator.ledger

        // Project-level share
        if let project = notionProject, let clientID = notionClientID {
            let projectRecord = ledger.frameioFolder(clientID: clientID, projectID: project.id)
            let notionLinkMissing = project.reviewLink == nil || project.reviewLink?.isEmpty == true
            if projectRecord?.shareLink == nil || projectRecord?.shareLink?.isEmpty == true || notionLinkMissing {
                let shareName = "\(project.name) - Client Review"
                let share = try await frameio.createShare(token: token,
                                                          folderID: projectFolderID,
                                                          name: shareName)
                ledger.upsertFrameioFolder(clientID: clientID, projectID: project.id,
                                            folderID: projectFolderID, shareLink: share.url)
                NotionAPI.updateProjectReviewLink(token: cfg.notionToken,
                                                   pageID: project.id,
                                                   link: share.url)
                Log("Pipeline: created project share → \(share.url)")
            }

            // Client-level share
            let clientRecord = ledger.frameioFolder(clientID: clientID, projectID: nil)
            if clientRecord?.shareLink == nil || clientRecord?.shareLink?.isEmpty == true {
                let shareName = "\(folderContext.clientFolderName) — All Projects"
                let share = try await frameio.createShare(token: token,
                                                          folderID: clientFolderID,
                                                          name: shareName)
                ledger.upsertFrameioFolder(clientID: clientID, projectID: nil,
                                            folderID: clientFolderID, shareLink: share.url)
                NotionAPI.updateClientFrameioLink(token: cfg.notionToken,
                                                   pageID: clientID,
                                                   link: share.url)
                Log("Pipeline: created client share → \(share.url)")
            }
        }
    }

    // MARK: - Helpers

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
