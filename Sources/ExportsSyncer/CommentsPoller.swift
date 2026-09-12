import Foundation

/// Closes the review loop: polls Frame.io for new client comments on every
/// file we've uploaded and turns each into a Notion task on the right project.
/// Replies and Luke's own comments are recorded as seen but never become
/// tasks — only fresh top-level client feedback does.
final class CommentsPoller {
    private let ledger: Ledger
    private let frameio: FrameioClient
    private var timer: Timer?
    private var ownUserID: String?
    private var running = false

    init(ledger: Ledger, frameio: FrameioClient) {
        self.ledger = ledger
        self.frameio = frameio
    }

    func start() {
        let configured = Config.load().commentsPollSeconds
        guard configured > 0 else {
            Log("CommentsPoller disabled (commentsPollSeconds = 0)")
            return
        }
        // Floor of 15 minutes: a client comment can wait that long, and
        // anything faster shares the rate limit with uploads.
        let interval = max(configured, 900)
        Log("CommentsPoller started (every \(Int(interval))s)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // First pass shortly after launch, once auth has had a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !running else { return }   // never overlap slow passes
        running = true
        Task.detached { [weak self] in
            defer { Task { @MainActor in self?.running = false } }
            await self?.poll()
        }
    }

    private func poll() async {
        let cfg = Config.load()
        guard !cfg.notionToken.isEmpty else { return }
        guard let token = try? await AuthManager.shared.validAccessToken() else {
            Log("CommentsPoller: no Frame.io token; skipping pass")
            return
        }
        if ownUserID == nil {
            ownUserID = try? await frameio.fetchOwnUserID(token: token)
        }

        var newTasks = 0
        for (relPath, fileID) in ledger.allUploadedFiles() {
            let comments: [FrameioClient.FrameioComment]
            do {
                comments = try await frameio.listComments(token: token, fileID: fileID)
            } catch FrameioError.rateLimited {
                // Every remaining file would hit the same wall. Stop, say so,
                // and let the next pass pick up where this one left off — the
                // ledger means nothing is lost by stopping early.
                Notifier.report(reason: "frameio-rate-limit",
                                "Frame.io rate limit reached — client comments aren't syncing to Notion. It'll retry automatically; tell me if it keeps happening.")
                return
            } catch FrameioError.httpError(404, _) {
                // Deleted on Frame.io. Retire it so it never costs a request again.
                ledger.markFileGone(fileID: fileID)
                Log("CommentsPoller: \((relPath as NSString).lastPathComponent) is gone from Frame.io — retired from comment polling")
                continue
            } catch {
                continue
            }

            for c in comments where !ledger.hasSeenComment(c.id) {
                let isOwn = (ownUserID != nil && c.authorID == ownUserID)
                if c.isReply || isOwn || c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ledger.markCommentSeen(c.id, taskCreated: false)
                    continue
                }

                let filename = (relPath as NSString).lastPathComponent
                var title = "💬 \(filename): \(c.text)"
                if title.count > 95 { title = String(title.prefix(92)) + "…" }

                var bodyText = "\(c.authorName) on \(filename)"
                if let t = c.timestampSeconds {
                    let m = Int(t) / 60, s = Int(t) % 60
                    bodyText += String(format: " at %d:%02d", m, s)
                }
                bodyText += ":\n\n\(c.text)"

                let link = "https://next.frame.io/player/\(fileID)"
                let projectID = ledger.projectID(forExportsRelPath: relPath)
                let page = NotionAPI.createCommentTask(
                    token: cfg.notionToken, tasksDB: cfg.notionTasksDB,
                    title: title, projectID: projectID,
                    url: link, commentBody: bodyText)

                if page != nil {
                    ledger.markCommentSeen(c.id, taskCreated: true)
                    newTasks += 1
                    Log("comment task created -> \(filename): \(c.text.prefix(60))")
                } else {
                    // Leave unseen so the next pass retries (Notion hiccup).
                    Log("comment task FAILED -> \(filename) (will retry)")
                }
            }
        }
        if newTasks > 0 {
            Log("comments pass complete -> \(newTasks) new task(s) in Notion")
        }
    }
}
