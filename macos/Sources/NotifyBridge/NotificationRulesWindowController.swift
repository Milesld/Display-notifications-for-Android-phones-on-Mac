import AppKit
import NotifyBridgeCore

private final class SourceModeButton: NSPopUpButton {
    var sourcePackage = ""
    var sourceApp = ""
}

/// A small settings window listing every phone app that has sent a
/// notification. Each row switches that source between a banner and a silent
/// Notification Center entry.
final class NotificationRulesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "全部恢复为弹窗", target: nil, action: nil)
    private var tableHeightConstraint: NSLayoutConstraint!
    private var sources: [NotificationSource] = []
    private var catalogObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "按 App 设置通知"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildContent()
        catalogObserver = NotificationCenter.default.addObserver(
            forName: NotificationCatalog.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            // Every notification updates lastSeen. Rebuilding the rows on each
            // one would move controls under the pointer while the user is
            // choosing, so only refresh when the set of apps actually changes.
            let updated = NotificationCatalog.sources()
            let currentPackages = Set(self.sources.map(\.package))
            let updatedPackages = Set(updated.map(\.package))
            guard currentPackages != updatedPackages else { return }
            self.reload()
        }
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let catalogObserver {
            NotificationCenter.default.removeObserver(catalogObserver)
        }
    }

    /// Shows the window and brings it to the front. The app is a menu-bar
    /// accessory, so it must activate explicitly before the window can become
    /// key.
    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }

        let header = NSTextField(wrappingLabelWithString: "这些 App 都曾发来通知。把不重要的 App 改成「静默」后，它的通知仍会出现在通知中心，但不会弹横幅、不会响铃。设置只影响之后收到的通知。")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.preferredMaxLayoutWidth = 528

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        tableHeightConstraint = tableView.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            tableHeightConstraint,
        ])

        emptyLabel.stringValue = "升级后还没有收到过手机通知。\n收到第一条通知后，对应的 App 会自动出现在这里。"
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(wrappingLabelWithString: "提示：专注模式下，需要把「通知桥」加入该专注模式的允许通知，否则所有通知都只会进入通知中心；设为「静默」的 App 即使被允许，也不会弹横幅或响铃。")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.preferredMaxLayoutWidth = 528

        resetButton.target = self
        resetButton.action = #selector(resetAll)
        resetButton.bezelStyle = .rounded

        let doneButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded

        let listContainer = NSView()
        listContainer.addSubview(scrollView)
        listContainer.addSubview(emptyLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -24),
        ])

        for view in [header, listContainer, footer, resetButton, doneButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            listContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            listContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            listContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            footer.topAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            resetButton.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 12),
            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            doneButton.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func reload() {
        sources = NotificationCatalog.sources()
        tableView.reloadData()
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        tableHeightConstraint.constant = max(rowHeight * CGFloat(sources.count), 1)
        scrollView.isHidden = sources.isEmpty
        emptyLabel.isHidden = !sources.isEmpty
        resetButton.isEnabled = NotificationPreferences.hasRules
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sources.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sources.indices.contains(row) else { return nil }
        let source = sources[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight))

        let name = NSTextField(labelWithString: source.app)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: source.package)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(labels)

        let popup = SourceModeButton(frame: .zero, pullsDown: false)
        popup.sourcePackage = source.package
        popup.sourceApp = source.app
        popup.addItems(withTitles: ["弹窗", "静默"])
        let isSilent = NotificationPreferences.mode(package: source.package, app: source.app) == .silent
        popup.selectItem(at: isSilent ? 1 : 0)
        popup.target = self
        popup.action = #selector(modeChanged(_:))
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(popup)

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -12),
            popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 94),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    @objc private func modeChanged(_ sender: SourceModeButton) {
        let mode: NotificationDeliveryMode = sender.indexOfSelectedItem == 1 ? .silent : .banner
        NotificationPreferences.setMode(mode, package: sender.sourcePackage, app: sender.sourceApp)
        resetButton.isEnabled = NotificationPreferences.hasRules
        AppLogger.info("Notification rule set: pkg=\(sender.sourcePackage) mode=\(mode.rawValue)")
    }

    @objc private func resetAll() {
        guard NotificationPreferences.hasRules else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "全部恢复为弹窗？"
        alert.informativeText = "所有 App 的通知都会重新弹横幅并播放声音。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NotificationPreferences.reset()
        tableView.reloadData()
        resetButton.isEnabled = false
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
