import Foundation

// MARK: - Data models

struct FrameioFolder {
    let id: String
    let name: String
    let parentID: String?
}

struct FrameioFile {
    let id: String
    let name: String
    let status: String // "processing", "complete", etc.
}

struct FrameioShare {
    let id: String
    let url: String
}

// MARK: - Client

/// Frame.io V4 API client. All methods are async.
final class FrameioClient: @unchecked Sendable {

    private let baseURL = "https://api.frame.io/v4"
    private var accountID: String = ""
    private var rootFolderID: String = ""
    private var projectID: String = ""

    func setAccountID(_ id: String) { accountID = id }
    func setRootFolderID(_ id: String) { rootFolderID = id }

    // MARK: - Account discovery

    /// Fetches the account ID via GET /accounts (V4 docs say /me does NOT return account_id).
    func fetchAccountInfo(token: String) async throws -> (accountID: String, rootFolderID: String) {
        let data = try await get(token: token, path: "/accounts")
        let raw = String(data: data, encoding: .utf8) ?? ""
        Log("FrameioClient /accounts response: \(raw.prefix(500))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameioError.unexpectedResponse("fetchAccountInfo: not JSON")
        }
        // V4 response: { "data": [ { "id": "...", ... } ] }
        if let arr = json["data"] as? [[String: Any]],
           let first = arr.first,
           let aid = first["id"] as? String, !aid.isEmpty {
            return (accountID: aid, rootFolderID: "")
        }
        // Flat array fallback
        if let arr = json as? [[String: Any]],
           let first = arr.first,
           let aid = first["id"] as? String, !aid.isEmpty {
            return (accountID: aid, rootFolderID: "")
        }
        throw FrameioError.unexpectedResponse("fetchAccountInfo: no account id in: \(raw.prefix(200))")
    }

    /// Lists top-level folders under the account root.
    func listRootFolders(token: String) async throws -> [FrameioFolder] {
        let data = try await get(token: token, path: "/accounts/\(accountID)/projects")
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let items: [[String: Any]]
        if let dict = json as? [String: Any] {
            if let dataArray = dict["data"] as? [[String: Any]] {
                items = dataArray
            } else if let dataDict = dict["data"] as? [String: Any] {
                items = [dataDict]
            } else if dict["id"] != nil {
                items = [dict]
            } else {
                items = []
            }
        } else if let array = json as? [[String: Any]] {
            items = array
        } else {
            items = []
        }
        return items.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return FrameioFolder(id: id, name: name, parentID: d["parent_id"] as? String)
        }
    }

    // MARK: - Folder operations

    func listFolders(token: String, parentID: String) async throws -> [FrameioFolder] {
        let data = try await get(token: token,
                                 path: "/accounts/\(accountID)/folders/\(parentID)/children")
        return parseFolders(data)
    }

    func createFolder(token: String, name: String, parentID: String) async throws -> FrameioFolder {
        let body: [String: Any] = ["data": ["name": name]]
        let data = try await post(token: token,
                                  path: "/accounts/\(accountID)/folders/\(parentID)/folders",
                                  body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let id = d["id"] as? String,
              let name = d["name"] as? String else {
            throw FrameioError.unexpectedResponse("createFolder")
        }
        return FrameioFolder(id: id, name: name, parentID: parentID)
    }

    /// Finds an existing folder by name under parentID, or creates it.
    func findOrCreateFolder(token: String, name: String, parentID: String) async throws -> FrameioFolder {
        let children = try await listFolders(token: token, parentID: parentID)
        if let existing = children.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return existing
        }
        return try await createFolder(token: token, name: name, parentID: parentID)
    }

    /// Returns the first project's root folder ID. Caches root folder ID and project ID after first call.
    /// Re-fetches if projectID is missing (rootFolderID may have been pre-set from config).
    func ensureRootFolderID(token: String) async throws -> String {
        if !rootFolderID.isEmpty && !projectID.isEmpty { return rootFolderID }
        let data = try await get(token: token, path: "/accounts/\(accountID)/projects")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let first = arr.first,
              let id = first["root_folder_id"] as? String,
              let pid = first["id"] as? String else {
            throw FrameioError.unexpectedResponse("ensureRootFolderID: no root_folder_id or project id in projects")
        }
        if rootFolderID.isEmpty { rootFolderID = id }
        projectID = pid
        return rootFolderID
    }

    func projectRootFolderID(token: String, projectID: String) async throws -> String {
        let data = try await get(token: token, path: "/accounts/\(accountID)/projects")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let project = arr.first(where: { $0["id"] as? String == projectID }),
              let folderID = project["root_folder_id"] as? String else {
            // Fall back: use first project's ID so createShare works
            if let arr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]],
               let first = arr.first, let pid = first["id"] as? String {
                self.projectID = pid
            }
            return projectID
        }
        self.projectID = projectID
        return folderID
    }

    // MARK: - File upload (multipart S3)

    struct UploadedFile {
        let id: String
    }

    /// Full upload flow: initiate → upload chunks → complete.
    func uploadFile(token: String, fileURL: URL, folderID: String) async throws -> UploadedFile {
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let filename = fileURL.lastPathComponent

        // 1. Initiate upload — V4 wraps body in "data", upload_urls is [{url, size}]
        let initiateBody: [String: Any] = ["data": [
            "name":       filename,
            "file_size":  fileSize,
            "media_type": mimeType(for: fileURL)
        ]]
        let initData = try await post(token: token,
                                      path: "/accounts/\(accountID)/folders/\(folderID)/files",
                                      body: initiateBody)
        guard let initJSON = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let fileData = initJSON["data"] as? [String: Any],
              let fileID = fileData["id"] as? String,
              let uploadURLObjs = fileData["upload_urls"] as? [[String: Any]] else {
            throw FrameioError.unexpectedResponse("uploadFile initiate")
        }
        let uploadURLs = uploadURLObjs.compactMap { $0["url"] as? String }
        guard !uploadURLs.isEmpty else {
            throw FrameioError.unexpectedResponse("uploadFile: no upload_urls")
        }

        // 2. Upload chunks to S3 signed URLs
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        let chunkSize = max(fileSize / uploadURLs.count, 5 * 1024 * 1024) // min 5MB

        for (i, uploadURL) in uploadURLs.enumerated() {
            let offset = i * chunkSize
            fileHandle.seek(toFileOffset: UInt64(offset))
            let chunk: Data
            if i == uploadURLs.count - 1 {
                chunk = fileHandle.readDataToEndOfFile()
            } else {
                chunk = fileHandle.readData(ofLength: chunkSize)
            }
            var req = URLRequest(url: URL(string: uploadURL)!)
            req.httpMethod = "PUT"
            req.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")
            req.setValue("private", forHTTPHeaderField: "x-amz-acl")
            req.httpBody = chunk
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FrameioError.uploadChunkFailed(i)
            }
        }

        Log("FrameioClient: uploaded '\(filename)' → file ID \(fileID)")
        return UploadedFile(id: fileID)
    }

    // MARK: - File status polling

    /// Polls until status is "complete" or timeout. Returns true if ready.
    func waitForTranscode(token: String, fileID: String,
                          timeout: TimeInterval = 300) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = try await get(token: token,
                                     path: "/accounts/\(accountID)/files/\(fileID)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] ?? json as [String: Any]?,
               let status = d["status"] as? String {
                if status == "complete" { return true }
                if status == "error" { throw FrameioError.transcodeError(fileID) }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        }
        return false
    }

    // MARK: - Version stacks

    func createVersionStack(token: String, folderID: String,
                             originalFileID: String,
                             newFileID: String) async throws -> String {
        let body: [String: Any] = ["data": ["file_ids": [originalFileID, newFileID]]]
        let data = try await post(token: token,
                                  path: "/accounts/\(accountID)/folders/\(folderID)/version_stacks",
                                  body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let stackID = d["id"] as? String else {
            throw FrameioError.unexpectedResponse("createVersionStack")
        }
        Log("FrameioClient: created version stack \(stackID)")
        return stackID
    }

    /// Adds a new version to an existing stack by moving the file.
    func addToVersionStack(token: String, stackID: String, newFileID: String) async throws {
        let body: [String: Any] = ["data": ["parent_id": stackID]]
        _ = try await patch(token: token,
                            path: "/accounts/\(accountID)/files/\(newFileID)/move",
                            body: body)
        Log("FrameioClient: moved file \(newFileID) onto stack \(stackID)")
    }

    // MARK: - Share links

    func createShare(token: String, folderID: String,
                     name: String) async throws -> FrameioShare {
        guard !projectID.isEmpty else {
            throw FrameioError.unexpectedResponse("createShare: projectID not set — call ensureRootFolderID first")
        }
        let body: [String: Any] = ["data": [
            "type": "asset",
            "name": name,
            "access": "public",
            "asset_ids": [folderID],
            "downloading_enabled": true
        ]]
        let data = try await post(token: token,
                                  path: "/accounts/\(accountID)/projects/\(projectID)/shares",
                                  body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let id = d["id"] as? String,
              let url = (d["short_url"] ?? d["url"]) as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            Log("FrameioClient: createShare unexpected response: \(raw.prefix(300))")
            throw FrameioError.unexpectedResponse("createShare")
        }
        Log("FrameioClient: created share '\(name)' → \(url)")
        return FrameioShare(id: id, url: url)
    }

    // MARK: - Comments

    struct FrameioComment {
        let id: String
        let text: String
        let authorName: String
        let authorID: String?
        let timestampSeconds: Double?   // position in the clip, if any
        let insertedAt: String
        let isReply: Bool
    }

    /// V4: GET /accounts/{a}/files/{f}/comments
    func listComments(token: String, fileID: String) async throws -> [FrameioComment] {
        let data = try await get(token: token,
                                 path: "/accounts/\(accountID)/files/\(fileID)/comments")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let owner = d["owner"] as? [String: Any]
            return FrameioComment(
                id: id,
                text: (d["text"] as? String) ?? "",
                authorName: (owner?["name"] as? String)
                    ?? (owner?["display_name"] as? String) ?? "Client",
                authorID: owner?["id"] as? String,
                timestampSeconds: d["timestamp"] as? Double,
                insertedAt: (d["inserted_at"] as? String) ?? "",
                isReply: (d["parent_id"] as? String) != nil
            )
        }
    }

    /// The signed-in user's ID, so our own replies never become tasks.
    func fetchOwnUserID(token: String) async throws -> String? {
        let data = try await get(token: token, path: "/me")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let user = (json?["data"] as? [String: Any]) ?? json
        return user?["id"] as? String
    }

    // MARK: - Helpers

    private func parseFolders(_ data: Data) -> [FrameioFolder] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return FrameioFolder(id: id, name: name, parentID: d["parent_id"] as? String)
        }
    }

    /// Read at point of use, not cached at init — the same trap `AuthManager`
    /// fell into. A blank ID here silently sends an empty `x-api-key` header for
    /// the life of the process.
    private var clientID: String { Config.load().frameioClientID }

    /// Frame.io rate-limits per account, and the comments pass fans out one
    /// request per uploaded file. Unspaced, a pass over 40 files fires 40
    /// requests at once and every one returns 429 — 1,267 of them on
    /// 2026-08-11 alone, which took the whole comments→Notion feature down
    /// while looking like ordinary log noise.
    private actor RateLimiter {
        private var nextSlot = Date.distantPast
        private let spacing: TimeInterval

        init(spacing: TimeInterval) { self.spacing = spacing }

        func reserve() async {
            let now = Date()
            let slot = max(now, nextSlot)
            nextSlot = slot.addingTimeInterval(spacing)
            let delay = slot.timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // 0.25s still drew a 429 roughly every fourth call on a long comments
    // pass; Frame.io's Retry-After is 2s, so 0.6s keeps a pass clean.
    private static let limiter = RateLimiter(spacing: 0.6)

    /// Single choke point for every JSON call: paces requests, and honours a
    /// 429 by backing off rather than hammering through the whole ledger.
    private func send(_ req: URLRequest, path: String) async throws -> Data {
        var attempt = 0
        while true {
            await Self.limiter.reserve()
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FrameioError.unexpectedResponse(path)
            }
            if http.statusCode == 429 {
                attempt += 1
                guard attempt <= 4 else {
                    Log("FrameioClient: still rate-limited after \(attempt) attempts for \(path) — abandoning this pass")
                    throw FrameioError.rateLimited
                }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? pow(2.0, Double(attempt))
                Log("FrameioClient: 429 for \(path) — backing off \(Int(retryAfter))s (attempt \(attempt))")
                try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                Log("FrameioClient: HTTP \(http.statusCode) for \(path): \(body.prefix(300))")
                throw FrameioError.httpError(http.statusCode, body)
            }
            return data
        }
    }

    private func get(token: String, path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "x-api-key")
        return try await send(req, path: path)
    }

    private func post(token: String, path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await send(req, path: path)
    }

    private func patch(token: String, path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await send(req, path: path)
    }

    private func checkResponse(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FrameioError.unexpectedResponse(path)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log("FrameioClient: HTTP \(http.statusCode) for \(path): \(body.prefix(300))")
            throw FrameioError.httpError(http.statusCode, body)
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let map: [String: String] = [
            "mov": "video/quicktime", "mp4": "video/mp4", "mxf": "video/mxf",
            "avi": "video/x-msvideo", "m4v": "video/x-m4v",
            "braw": "video/x-braw", "mts": "video/mp2t", "m2ts": "video/mp2t", "mkv": "video/x-matroska",
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "tiff": "image/tiff", "tif": "image/tiff", "gif": "image/gif",
            "heic": "image/heic", "webp": "image/webp",
            "cr2": "image/x-canon-cr2", "cr3": "image/x-canon-cr3",
            "arw": "image/x-sony-arw", "raw": "image/x-raw",
            "hif": "image/heif", "dng": "image/x-adobe-dng",
            "nef": "image/x-nikon-nef", "orf": "image/x-olympus-orf", "rw2": "image/x-panasonic-rw2",
            "mp3": "audio/mpeg", "wav": "audio/wav", "aiff": "audio/aiff", "aif": "audio/aiff",
            "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac",
            "ogg": "audio/ogg", "opus": "audio/opus"
        ]
        return map[ext] ?? "application/octet-stream"
    }
}

enum FrameioError: LocalizedError {
    case httpError(Int, String)
    case unexpectedResponse(String)
    case uploadChunkFailed(Int)
    case transcodeError(String)
    /// Distinct from `httpError(429, …)` so callers can abandon a whole pass
    /// instead of retrying every remaining item into the same wall.
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body): return "Frame.io HTTP \(code): \(body.prefix(300))"
        case .unexpectedResponse(let op):    return "Unexpected Frame.io response at \(op)"
        case .uploadChunkFailed(let i):      return "Upload chunk \(i) failed"
        case .transcodeError(let id):        return "Transcode error for file \(id)"
        case .rateLimited:                   return "Frame.io rate limit reached"
        }
    }
}
