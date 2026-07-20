import Foundation

// MARK: - Data models

struct NotionProject {
    let id: String
    let name: String
    let status: String
    let jobCode: String
    let clientID: String?
    let reviewLink: String?
    let folderRequest: Bool   // "Folder Request" checkbox — set by the Create Folders button
}

struct NotionClient {
    let id: String
    let name: String
    let parentClientID: String?
    let frameioLink: String?
}

// MARK: - Client

/// Calls the Notion API. All methods are synchronous (semaphore-wrapped) to
/// keep the same calling style as the existing DITIngest Notion client.
enum NotionAPI {
    static let version = "2022-06-28"

    // MARK: - Projects

    /// Fetches all projects (used by Pipeline to match uploads to Notion by job code).
    static func allProjects(token: String, databaseID: String) -> [NotionProject] {
        var all: [[String: Any]] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            guard let (results, next) = queryDatabasePage(token: token,
                                                          databaseID: databaseID,
                                                          body: body) else { break }
            all.append(contentsOf: results)
            cursor = next
        } while cursor != nil
        return all.compactMap(parseProject)
    }

    /// Fetches only projects where the "Folder Request" checkbox is checked.
    /// This is set by the "Create Folders" button in Notion.
    static func folderRequestedProjects(token: String, databaseID: String) -> [NotionProject] {
        let body: [String: Any] = [
            "filter": [
                "property": "Folder Request",
                "checkbox": ["equals": true]
            ],
            "page_size": 100
        ]
        guard let results = queryDatabase(token: token, databaseID: databaseID, body: body) else {
            return []
        }
        return results.compactMap(parseProject)
    }

    // MARK: - Clients

    static func client(token: String, databaseID: String, clientID: String) -> NotionClient? {
        let url = URL(string: "https://api.notion.com/v1/pages/\(clientID)")!
        guard let data = get(token: token, url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseClient(json)
    }

    // MARK: - Write back

    /// Clears the "Folder Request" checkbox after the app has processed it.
    @discardableResult
    static func uncheckFolderRequest(token: String, pageID: String) -> Bool {
        return updateProperty(token: token, pageID: pageID,
                              property: "Folder Request",
                              value: ["checkbox": false])
    }

    @discardableResult
    static func updateProjectReviewLink(token: String, pageID: String, link: String) -> Bool {
        return updateProperty(token: token, pageID: pageID, property: "Review Link",
                              value: ["url": link])
    }

    @discardableResult
    static func updateClientFrameioLink(token: String, pageID: String, link: String) -> Bool {
        return updateProperty(token: token, pageID: pageID, property: "Frame.io",
                              value: ["url": link])
    }

    @discardableResult
    static func postComment(token: String, pageID: String, text: String) -> Bool {
        let url = URL(string: "https://api.notion.com/v1/comments")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setHeaders(&req, token: token)
        let body: [String: Any] = [
            "parent": ["page_id": pageID],
            "rich_text": [["text": ["content": text]]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return send(req) != nil
    }

    /// Creates a new minimal project page for untracked uploads.
    static func createProjectPage(token: String, databaseID: String,
                                  name: String, clientID: String?,
                                  reviewLink: String?) -> String? {
        var properties: [String: Any] = [
            "Name": ["title": [["text": ["content": name]]]]
        ]
        if let cid = clientID {
            properties["Client"] = ["relation": [["id": cid]]]
        }
        if let link = reviewLink {
            properties["Review Link"] = ["url": link]
        }
        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": properties
        ]
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setHeaders(&req, token: token)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let data = send(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { return nil }
        return id
    }

    // MARK: - Private helpers

    private static func queryDatabase(token: String, databaseID: String,
                                      body: [String: Any]) -> [[String: Any]]? {
        queryDatabasePage(token: token, databaseID: databaseID, body: body)?.results
    }

    /// Single page of a database query, returning results plus the next cursor (if any).
    private static func queryDatabasePage(token: String, databaseID: String,
                                          body: [String: Any])
        -> (results: [[String: Any]], nextCursor: String?)? {
        let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)/query")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setHeaders(&req, token: token)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let data = send(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let next = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        return (results, next)
    }

    private static func get(token: String, url: URL) -> Data? {
        var req = URLRequest(url: url)
        setHeaders(&req, token: token)
        return send(req)
    }

    private static func updateProperty(token: String, pageID: String,
                                       property: String, value: Any) -> Bool {
        let url = URL(string: "https://api.notion.com/v1/pages/\(pageID)")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        setHeaders(&req, token: token)
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "properties": [property: value]
        ])
        return send(req) != nil
    }

    private static func setHeaders(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    @discardableResult
    private static func send(_ req: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Log("Notion HTTP \(http.statusCode): \(body.prefix(200))")
                return
            }
            result = data
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
    }

    // MARK: - Parsers

    private static func parseProject(_ page: [String: Any]) -> NotionProject? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }

        let name = titleValue(props["Name"]) ?? titleValue(props["name"]) ?? ""
        let status = statusValue(props["Status"]) ?? ""
        let jobCode = formulaValue(props["Job Code"]) ?? ""
        let clientID = relationValue(props["Client"])
        let reviewLink = urlValue(props["Review Link"])
        let folderRequest = checkboxValue(props["Folder Request"])

        return NotionProject(id: id, name: name, status: status, jobCode: jobCode,
                             clientID: clientID, reviewLink: reviewLink,
                             folderRequest: folderRequest)
    }

    private static func parseClient(_ page: [String: Any]) -> NotionClient? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }

        let name = titleValue(props["Company Name"]) ?? ""
        let parentClientID = relationValue(props["Parent Client"])
        let frameioLink = urlValue(props["Frame.io"])

        return NotionClient(id: id, name: name, parentClientID: parentClientID,
                            frameioLink: frameioLink)
    }

    private static func titleValue(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let arr = p["title"] as? [[String: Any]] else { return nil }
        let text = arr.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private static func statusValue(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let status = p["status"] as? [String: Any] else { return nil }
        return status["name"] as? String
    }

    private static func formulaValue(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let formula = p["formula"] as? [String: Any] else { return nil }
        return formula["string"] as? String
    }

    private static func relationValue(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any],
              let arr = p["relation"] as? [[String: Any]],
              let first = arr.first else { return nil }
        return first["id"] as? String
    }

    private static func urlValue(_ prop: Any?) -> String? {
        guard let p = prop as? [String: Any] else { return nil }
        return p["url"] as? String
    }

    private static func checkboxValue(_ prop: Any?) -> Bool {
        guard let p = prop as? [String: Any] else { return false }
        return p["checkbox"] as? Bool ?? false
    }
}
