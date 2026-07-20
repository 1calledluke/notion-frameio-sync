import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private weak var coordinator: Coordinator?
    private var assetsField         = NSTextField()
    private var exportsField        = NSTextField()
    private var notionField         = NSTextField()
    private var accountField        = NSTextField()
    private var frameioProjectField = NSTextField()
    private var authLabel           = NSTextField(labelWithString: "Not authenticated")
    private var statusLabel         = NSTextField(labelWithString: "")
    private var discoverBtn: NSButton!
    private var pickProjectBtn: NSButton!

    convenience init(coordinator: Coordinator) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Exports Syncer — Settings"
        win.minSize = NSSize(width: 500, height: 480)
        win.center()
        self.init(window: win)
        self.coordinator = coordinator
        setupUI()
        loadValues()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        // ── Description banner ──────────────────────────────────────────────
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 8
        banner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        banner.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        banner.layer?.borderWidth = 1
        cv.addSubview(banner)

        let howTitle = NSTextField(labelWithString: "How it works")
        howTitle.translatesAutoresizingMaskIntoConstraints = false
        howTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        howTitle.textColor = .labelColor
        banner.addSubview(howTitle)

        let howBody = NSTextField(wrappingLabelWithString:
            "Step 1 — When a Notion project's status changes to Active, Exports Syncer automatically " +
            "creates the full Assets + Exports folder skeleton on disk.\n" +
            "Step 2 — It watches your Exports folder for new video files from DaVinci Resolve. " +
            "Each export is uploaded to the chosen Frame.io project (with automatic version stacking), " +
            "a share link is created, and a comment is posted on the Notion project page."
        )
        howBody.translatesAutoresizingMaskIntoConstraints = false
        howBody.font = .systemFont(ofSize: 11.5)
        howBody.textColor = .secondaryLabelColor
        banner.addSubview(howBody)

        NSLayoutConstraint.activate([
            howTitle.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            howTitle.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            howTitle.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),

            howBody.topAnchor.constraint(equalTo: howTitle.bottomAnchor, constant: 4),
            howBody.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            howBody.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            howBody.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
        ])

        // ── Separator ───────────────────────────────────────────────────────
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sep)

        // ── Form rows ────────────────────────────────────────────────────────
        let labelW: CGFloat = 148

        func makeLabel(_ s: String, tip: String = "") -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.alignment = .right
            f.font = .systemFont(ofSize: 13)
            if !tip.isEmpty { f.toolTip = tip }
            return f
        }

        func makeField(_ tip: String = "", placeholder: String = "") -> NSTextField {
            let f = NSTextField()
            f.translatesAutoresizingMaskIntoConstraints = false
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            if !tip.isEmpty { f.toolTip = tip }
            if !placeholder.isEmpty { f.placeholderString = placeholder }
            return f
        }

        func makeButton(_ title: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.bezelStyle = .rounded
            return b
        }

        // Assets root
        let assetsLbl = makeLabel("Assets root:",
            tip: "Root folder containing client/project folders (e.g. 01_Index Video). New project skeletons are provisioned here.")
        let browseAssetsBtn = makeButton("…", action: #selector(browseAssets))
        assetsField.translatesAutoresizingMaskIntoConstraints = false
        assetsField.isBezeled = true; assetsField.bezelStyle = .roundedBezel
        assetsField.cell?.lineBreakMode = .byTruncatingHead
        assetsField.toolTip = assetsLbl.toolTip
        cv.addSubview(assetsLbl); cv.addSubview(assetsField); cv.addSubview(browseAssetsBtn)

        // Exports root
        let exportsLbl = makeLabel("Exports root:",
            tip: "The 06_Exports folder watched for new video files. Each export triggers the upload pipeline.")
        let browseExportsBtn = makeButton("…", action: #selector(browseExports))
        exportsField.translatesAutoresizingMaskIntoConstraints = false
        exportsField.isBezeled = true; exportsField.bezelStyle = .roundedBezel
        exportsField.cell?.lineBreakMode = .byTruncatingHead
        exportsField.toolTip = exportsLbl.toolTip
        cv.addSubview(exportsLbl); cv.addSubview(exportsField); cv.addSubview(browseExportsBtn)

        // Notion token
        let notionLbl = makeLabel("Notion token:",
            tip: "Your Notion internal integration secret. Find it at notion.so/profile/integrations.")
        notionField.translatesAutoresizingMaskIntoConstraints = false
        notionField.isBezeled = true; notionField.bezelStyle = .roundedBezel
        notionField.toolTip = notionLbl.toolTip
        cv.addSubview(notionLbl); cv.addSubview(notionField)

        // Frame.io account ID
        let accountLbl = makeLabel("Frame.io account ID:",
            tip: "Your Frame.io account ID. Click Discover to fetch it automatically after authenticating.")
        discoverBtn = makeButton("Discover", action: #selector(discoverAccountID))
        accountField.translatesAutoresizingMaskIntoConstraints = false
        accountField.isBezeled = true; accountField.bezelStyle = .roundedBezel
        accountField.toolTip = accountLbl.toolTip
        cv.addSubview(accountLbl); cv.addSubview(accountField); cv.addSubview(discoverBtn)

        // Frame.io project
        let projectLbl = makeLabel("Frame.io project:",
            tip: "The Frame.io project uploads are placed inside. Click Pick… to choose from your existing projects.")
        pickProjectBtn = makeButton("Pick…", action: #selector(pickFrameioProject))
        frameioProjectField.translatesAutoresizingMaskIntoConstraints = false
        frameioProjectField.isBezeled = true; frameioProjectField.bezelStyle = .roundedBezel
        frameioProjectField.placeholderString = "Not set — uploads go to account root"
        frameioProjectField.cell?.lineBreakMode = .byTruncatingHead
        frameioProjectField.toolTip = projectLbl.toolTip
        cv.addSubview(projectLbl); cv.addSubview(frameioProjectField); cv.addSubview(pickProjectBtn)

        // Auth row
        let authRowLbl = makeLabel("Frame.io auth:")
        let authBtn = makeButton("Authenticate Frame.io…", action: #selector(startAuth))
        authLabel.translatesAutoresizingMaskIntoConstraints = false
        authLabel.font = .systemFont(ofSize: 13)
        cv.addSubview(authRowLbl); cv.addSubview(authLabel); cv.addSubview(authBtn)

        // ── Flexible spacer — absorbs extra height when window is resized ───
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(spacer)

        // ── Separator + bottom bar ───────────────────────────────────────────
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sep2)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        cv.addSubview(statusLabel)

        let saveBtn = NSButton(title: "Save & Apply", target: self, action: #selector(save))
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        cv.addSubview(saveBtn)

        // ── Constraints ──────────────────────────────────────────────────────
        let m: CGFloat = 16   // outer margin
        let gap: CGFloat = 10 // label-to-field gap
        let rowH: CGFloat = 26
        let rowGap: CGFloat = 12

        NSLayoutConstraint.activate([
            // Banner
            banner.topAnchor.constraint(equalTo: cv.topAnchor, constant: m),
            banner.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            banner.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            // Separator after banner
            sep.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: m),
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            // ── Assets root ──
            assetsLbl.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: m),
            assetsLbl.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            assetsLbl.widthAnchor.constraint(equalToConstant: labelW),
            assetsLbl.heightAnchor.constraint(equalToConstant: rowH),

            browseAssetsBtn.centerYAnchor.constraint(equalTo: assetsLbl.centerYAnchor),
            browseAssetsBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            browseAssetsBtn.widthAnchor.constraint(equalToConstant: 30),

            assetsField.centerYAnchor.constraint(equalTo: assetsLbl.centerYAnchor),
            assetsField.leadingAnchor.constraint(equalTo: assetsLbl.trailingAnchor, constant: gap),
            assetsField.trailingAnchor.constraint(equalTo: browseAssetsBtn.leadingAnchor, constant: -6),
            assetsField.heightAnchor.constraint(equalToConstant: rowH),

            // ── Exports root ──
            exportsLbl.topAnchor.constraint(equalTo: assetsLbl.bottomAnchor, constant: rowGap),
            exportsLbl.leadingAnchor.constraint(equalTo: assetsLbl.leadingAnchor),
            exportsLbl.widthAnchor.constraint(equalToConstant: labelW),
            exportsLbl.heightAnchor.constraint(equalToConstant: rowH),

            browseExportsBtn.centerYAnchor.constraint(equalTo: exportsLbl.centerYAnchor),
            browseExportsBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            browseExportsBtn.widthAnchor.constraint(equalToConstant: 30),

            exportsField.centerYAnchor.constraint(equalTo: exportsLbl.centerYAnchor),
            exportsField.leadingAnchor.constraint(equalTo: exportsLbl.trailingAnchor, constant: gap),
            exportsField.trailingAnchor.constraint(equalTo: browseExportsBtn.leadingAnchor, constant: -6),
            exportsField.heightAnchor.constraint(equalToConstant: rowH),

            // ── Notion token ──
            notionLbl.topAnchor.constraint(equalTo: exportsLbl.bottomAnchor, constant: rowGap),
            notionLbl.leadingAnchor.constraint(equalTo: assetsLbl.leadingAnchor),
            notionLbl.widthAnchor.constraint(equalToConstant: labelW),
            notionLbl.heightAnchor.constraint(equalToConstant: rowH),

            notionField.centerYAnchor.constraint(equalTo: notionLbl.centerYAnchor),
            notionField.leadingAnchor.constraint(equalTo: notionLbl.trailingAnchor, constant: gap),
            notionField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            notionField.heightAnchor.constraint(equalToConstant: rowH),

            // ── Frame.io account ID ──
            accountLbl.topAnchor.constraint(equalTo: notionLbl.bottomAnchor, constant: rowGap),
            accountLbl.leadingAnchor.constraint(equalTo: assetsLbl.leadingAnchor),
            accountLbl.widthAnchor.constraint(equalToConstant: labelW),
            accountLbl.heightAnchor.constraint(equalToConstant: rowH),

            discoverBtn.centerYAnchor.constraint(equalTo: accountLbl.centerYAnchor),
            discoverBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            accountField.centerYAnchor.constraint(equalTo: accountLbl.centerYAnchor),
            accountField.leadingAnchor.constraint(equalTo: accountLbl.trailingAnchor, constant: gap),
            accountField.trailingAnchor.constraint(equalTo: discoverBtn.leadingAnchor, constant: -6),
            accountField.heightAnchor.constraint(equalToConstant: rowH),

            // ── Frame.io project ──
            projectLbl.topAnchor.constraint(equalTo: accountLbl.bottomAnchor, constant: rowGap),
            projectLbl.leadingAnchor.constraint(equalTo: assetsLbl.leadingAnchor),
            projectLbl.widthAnchor.constraint(equalToConstant: labelW),
            projectLbl.heightAnchor.constraint(equalToConstant: rowH),

            pickProjectBtn.centerYAnchor.constraint(equalTo: projectLbl.centerYAnchor),
            pickProjectBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            frameioProjectField.centerYAnchor.constraint(equalTo: projectLbl.centerYAnchor),
            frameioProjectField.leadingAnchor.constraint(equalTo: projectLbl.trailingAnchor, constant: gap),
            frameioProjectField.trailingAnchor.constraint(equalTo: pickProjectBtn.leadingAnchor, constant: -6),
            frameioProjectField.heightAnchor.constraint(equalToConstant: rowH),

            // ── Auth row ──
            authRowLbl.topAnchor.constraint(equalTo: projectLbl.bottomAnchor, constant: rowGap),
            authRowLbl.leadingAnchor.constraint(equalTo: assetsLbl.leadingAnchor),
            authRowLbl.widthAnchor.constraint(equalToConstant: labelW),
            authRowLbl.heightAnchor.constraint(equalToConstant: rowH),

            authBtn.centerYAnchor.constraint(equalTo: authRowLbl.centerYAnchor),
            authBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            authLabel.centerYAnchor.constraint(equalTo: authRowLbl.centerYAnchor),
            authLabel.leadingAnchor.constraint(equalTo: authRowLbl.trailingAnchor, constant: gap),
            authLabel.trailingAnchor.constraint(equalTo: authBtn.leadingAnchor, constant: -8),

            // ── Spacer (absorbs extra height on resize) ──
            spacer.topAnchor.constraint(equalTo: authRowLbl.bottomAnchor, constant: m),
            spacer.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            spacer.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),

            // ── Bottom separator ──
            sep2.topAnchor.constraint(equalTo: spacer.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            sep2.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            // ── Bottom bar ──
            saveBtn.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 10),
            saveBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            saveBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -m),

            statusLabel.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            statusLabel.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
        ])

        window?.delegate = self

        AuthManager.shared.onAuthCompleted = { [weak self] in
            Task { @MainActor in
                self?.authLabel.stringValue = "Authenticated"
                self?.authLabel.textColor = .systemGreen
                self?.setStatus("Frame.io login successful")
            }
        }
        AuthManager.shared.onAuthFailed = { [weak self] msg in
            Task { @MainActor in
                self?.authLabel.stringValue = "Auth failed"
                self?.authLabel.textColor = .systemRed
                self?.setStatus("Auth error: \(msg)")
            }
        }
    }

    private func loadValues() {
        guard let cfg = coordinator?.config else { return }
        assetsField.stringValue         = cfg.assetsRoot
        exportsField.stringValue        = cfg.exportsRoot
        notionField.stringValue         = cfg.notionToken
        accountField.stringValue        = cfg.frameioAccountID
        frameioProjectField.stringValue = cfg.frameioRootFolderID

        if AuthManager.shared.hasRefreshToken {
            authLabel.stringValue = "Authenticated"
            authLabel.textColor = .systemGreen
        } else {
            authLabel.stringValue = "Not authenticated"
            authLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func browseAssets()  { browse(field: assetsField) }
    @objc private func browseExports() { browse(field: exportsField) }

    private func browse(field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !field.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: field.stringValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    @objc private func startAuth() {
        AuthManager.shared.startOAuthFlow()
        setStatus("Browser opened — complete login, then return here")
    }

    @objc private func discoverAccountID() {
        guard AuthManager.shared.hasRefreshToken else {
            setStatus("Authenticate Frame.io first, then click Discover")
            return
        }
        discoverBtn.isEnabled = false
        setStatus("Fetching account info…")
        Task {
            do {
                let token = try await AuthManager.shared.validAccessToken()
                let client = FrameioClient()
                let (accountID, _) = try await client.fetchAccountInfo(token: token)
                await MainActor.run {
                    self.accountField.stringValue = accountID
                    self.discoverBtn.isEnabled = true
                    self.setStatus("Account ID found: \(accountID)")
                }
            } catch {
                await MainActor.run {
                    self.discoverBtn.isEnabled = true
                    self.setStatus("Discovery failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func pickFrameioProject(_ sender: NSButton) {
        guard AuthManager.shared.hasRefreshToken else {
            setStatus("Authenticate Frame.io first, then click Pick…")
            return
        }
        pickProjectBtn.isEnabled = false
        setStatus("Verifying token + account…")
        Task {
            var step = "getting token"
            do {
                let token = try await AuthManager.shared.validAccessToken()
                let client = FrameioClient()

                step = "GET /me"
                let (freshAccountID, _) = try await client.fetchAccountInfo(token: token)
                await MainActor.run {
                    self.accountField.stringValue = freshAccountID
                    self.setStatus("Fetching projects for account \(freshAccountID)…")
                }
                client.setAccountID(freshAccountID)

                step = "GET /accounts/\(freshAccountID)/projects"
                let folders = try await client.listRootFolders(token: token)
                await MainActor.run {
                    self.pickProjectBtn.isEnabled = true
                    self.setStatus(folders.isEmpty ? "No projects found in account \(freshAccountID)" : "")
                    guard !folders.isEmpty else { return }
                    let menu = NSMenu()
                    for folder in folders {
                        let item = NSMenuItem(title: folder.name,
                                             action: #selector(self.selectProject(_:)),
                                             keyEquivalent: "")
                        item.target = self
                        item.representedObject = folder
                        menu.addItem(item)
                    }
                    menu.popUp(positioning: nil,
                               at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY),
                               in: sender.superview)
                }
            } catch {
                await MainActor.run {
                    self.pickProjectBtn.isEnabled = true
                    self.setStatus("Pick failed at [\(step)]: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func selectProject(_ item: NSMenuItem) {
        guard let folder = item.representedObject as? FrameioFolder else { return }
        frameioProjectField.stringValue = folder.id
        setStatus("Project set to: \(folder.name)")
    }

    @objc private func save() {
        guard var cfg = coordinator?.config else { return }
        cfg.assetsRoot          = assetsField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.exportsRoot         = exportsField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.notionToken         = notionField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.frameioAccountID    = accountField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.frameioRootFolderID = frameioProjectField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !cfg.assetsRoot.isEmpty, !cfg.exportsRoot.isEmpty else {
            setStatus("Assets and Exports roots are required")
            return
        }

        coordinator?.applyConfig(newConfig: cfg)
        setStatus("Saved. Watcher restarted.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.window?.close()
        }
    }

    private func setStatus(_ msg: String) {
        statusLabel.stringValue = msg
    }

    func windowWillClose(_ notification: Notification) {}
}
