import Foundation

/// Polls Notion for projects where the "Folder Request" checkbox is checked
/// (set by the "Create Folders" button) and provisions local folder skeletons.
final class ProjectPoller {

    private var timer: Timer?
    private weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func start() {
        let interval = coordinator?.config.pollIntervalSeconds ?? 90
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
        Log("ProjectPoller: started (interval \(Int(interval))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func provisionFrameio(project: NotionProject, client: NotionClient,
                                   folderName: String, clientFolderName: String,
                                   cfg: Config, coord: Coordinator) async {
        do {
            let token = try await AuthManager.shared.validAccessToken()
            let fio = coord.frameio
            let rootID = try await fio.ensureRootFolderID(token: token)

            // Find or create client folder, then project folder inside it
            let clientFolder  = try await fio.findOrCreateFolder(token: token, name: clientFolderName, parentID: rootID)
            let projectFolder = try await fio.findOrCreateFolder(token: token, name: project.name, parentID: clientFolder.id)

            // Create a public share link for the project folder
            let share = try await fio.createShare(token: token,
                                                   folderID: projectFolder.id,
                                                   name: "\(project.name) - Client Review")

            // Cache in ledger
            coord.ledger.upsertFrameioFolder(clientID: client.id,
                                              projectID: project.id,
                                              folderID: projectFolder.id,
                                              shareLink: share.url)

            // Write share link back to Notion project's Review Link
            NotionAPI.updateProjectReviewLink(token: cfg.notionToken,
                                              pageID: project.id,
                                              link: share.url)

            // Update the Notion comment with the Frame.io link
            NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                  text: "🎬 Frame.io folder ready: \(share.url)")
            Log("ProjectPoller: Frame.io folder created for '\(project.name)' → \(share.url)")
        } catch {
            Log("ProjectPoller: Frame.io provisioning failed for '\(project.name)' — \(error)")
            NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                  text: "⚠️ Local folders created but Frame.io setup failed: \(error.localizedDescription)")
        }
    }

    private func poll() {
        guard let coord = coordinator, coord.config.isConfigured else { return }
        let cfg = coord.config
        let ledger = coord.ledger

        DispatchQueue.global(qos: .background).async {
            let projects = NotionAPI.folderRequestedProjects(token: cfg.notionToken,
                                                             databaseID: cfg.notionProjectsDB)
            for project in projects {
                // Uncheck immediately so the button is ready to use again
                NotionAPI.uncheckFolderRequest(token: cfg.notionToken, pageID: project.id)

                // Ledger guard: already provisioned by a previous run
                if ledger.isProvisioned(notionProjectID: project.id) {
                    // Repair path: if the Review Link is blank, Frame.io setup
                    // previously failed — retry it instead of just skipping.
                    if project.reviewLink == nil || project.reviewLink?.isEmpty == true,
                       let clientID = project.clientID,
                       let client = NotionAPI.client(token: cfg.notionToken,
                                                     databaseID: cfg.notionClientsDB,
                                                     clientID: clientID) {
                        Log("ProjectPoller: '\(project.name)' in ledger but no review link — retrying Frame.io setup")
                        Task {
                            await self.provisionFrameio(
                                project: project,
                                client: client,
                                folderName: project.name,
                                clientFolderName: client.name,
                                cfg: cfg,
                                coord: coord
                            )
                        }
                    } else {
                        Log("ProjectPoller: '\(project.name)' already in ledger — skipping")
                        NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                             text: "⚠️ Folders were already created for this project — no changes made.")
                    }
                    continue
                }

                guard let clientID = project.clientID else {
                    Log("ProjectPoller: '\(project.name)' has no Client set — skipping")
                    NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                         text: "❌ Folder creation failed: no Client is set on this project.")
                    continue
                }

                guard let client = NotionAPI.client(token: cfg.notionToken,
                                                    databaseID: cfg.notionClientsDB,
                                                    clientID: clientID) else {
                    Log("ProjectPoller: couldn't fetch client \(clientID)")
                    NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                         text: "❌ Folder creation failed: couldn't load the linked Client record.")
                    continue
                }

                var parentClient: NotionClient?
                if let parentID = client.parentClientID {
                    parentClient = NotionAPI.client(token: cfg.notionToken,
                                                    databaseID: cfg.notionClientsDB,
                                                    clientID: parentID)
                }

                do {
                    let result = try Provisioner.provision(
                        project: project,
                        client: client,
                        parentClient: parentClient,
                        assetsRoot: cfg.assetsRoot,
                        exportsRoot: cfg.exportsRoot
                    )

                    ledger.markProvisioned(notionProjectID: project.id,
                                           assetsRelPath: result.assetsRelPath,
                                           exportsRelPath: result.exportsRelPath)

                    if result.alreadyExisted {
                        Log("ProjectPoller: folders already existed for '\(project.name)'")
                        NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                             text: "⚠️ Folders already exist on disk — no changes made.\nPath: \(result.assetsRelPath)")
                    } else {
                        Log("ProjectPoller: provisioned '\(project.name)'")

                        // Create Frame.io folder structure and share link
                        Task {
                            await self.provisionFrameio(
                                project: project,
                                client: client,
                                folderName: (result.exportsRelPath as NSString).lastPathComponent,
                                clientFolderName: client.name,
                                cfg: cfg,
                                coord: coord
                            )
                        }

                        NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                             text: "✅ Folders created.\nAssets: \(result.assetsRelPath)\nExports: \(result.exportsRelPath)")
                        DispatchQueue.main.async {
                            coord.notifyActivity("Folders created: \(project.name)")
                        }
                    }
                } catch {
                    Log("ProjectPoller: provisioning failed for '\(project.name)' — \(error)")
                    NotionAPI.postComment(token: cfg.notionToken, pageID: project.id,
                                         text: "❌ Folder creation failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
