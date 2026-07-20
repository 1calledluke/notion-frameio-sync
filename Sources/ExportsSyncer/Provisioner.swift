import Foundation

/// Creates local folder skeletons when a project transitions to Active.
enum Provisioner {

    static let assetSubfolders = [
        "01_Audio",
        "02_Stock",
        "03_Branding",
        "04_Photos",
        "05_Project Files",
        "06_Proxies",
        "07_Renders",
        "08_Fonts",
        "09_Unsorted"
    ]

    struct ProvisionResult {
        let assetsRelPath: String
        let exportsRelPath: String
        let alreadyExisted: Bool
    }

    /// Creates Assets and Exports folder trees for the given project.
    /// If both root folders already exist on disk, skips creation and returns
    /// `alreadyExisted = true` so the caller can post the appropriate comment.
    static func provision(project: NotionProject,
                          client: NotionClient,
                          parentClient: NotionClient?,
                          assetsRoot: String,
                          exportsRoot: String) throws -> ProvisionResult {
        let folderName = projectFolderName(project: project)
        let clientFolderName = client.name
        let parentFolderName = parentClient.map { $0.name }

        // Build relative path segments
        var segments: [String] = []
        if let parent = parentFolderName { segments.append(parent) }
        segments.append(clientFolderName)
        segments.append(folderName)

        let relPath = segments.joined(separator: "/")

        let assetsDir = (assetsRoot as NSString).appendingPathComponent(relPath)
        let exportsDir = (exportsRoot as NSString).appendingPathComponent(relPath)

        let fm = FileManager.default
        let assetsExist = fm.fileExists(atPath: assetsDir)
        let exportsExist = fm.fileExists(atPath: exportsDir)

        if assetsExist && exportsExist {
            Log("Provisioner: folders already exist for '\(project.name)' — skipping")
            return ProvisionResult(assetsRelPath: relPath, exportsRelPath: relPath,
                                   alreadyExisted: true)
        }

        // Assets: full skeleton
        if !assetsExist {
            try createDirectory(assetsDir)
            for sub in assetSubfolders {
                try createDirectory((assetsDir as NSString).appendingPathComponent(sub))
            }
        }

        // Exports: project folder only (no subfolders — Resolve renders directly here)
        if !exportsExist {
            try createDirectory(exportsDir)
        }

        Log("Provisioner: created folders for '\(project.name)' at \(relPath)")
        return ProvisionResult(assetsRelPath: relPath, exportsRelPath: relPath,
                               alreadyExisted: false)
    }

    // MARK: - Naming

    /// Format: YY.MM_ProjectName_JobCode
    /// e.g. "26.06_WatsonAbout_AMP-0012"
    static func projectFolderName(project: NotionProject) -> String {
        let cal = Calendar.current
        let now = Date()
        let yy = String(format: "%02d", cal.component(.year, from: now) % 100)
        let mm = String(format: "%02d", cal.component(.month, from: now))
        let name = sanitize(project.name)
        let jobCode = project.jobCode.isEmpty ? "" : "_\(project.jobCode)"
        return "\(yy).\(mm)_\(name)\(jobCode)"
    }

    // Used for project names — strips unsafe chars and collapses spaces (no separator)
    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: bad).joined()
        return cleaned.components(separatedBy: .whitespaces)
                      .filter { !$0.isEmpty }
                      .joined()
    }


    private static func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
    }
}
