//
// CSTLUTLibraryView.swift
//
// AppKit UI for the creative Rec.709 .cube library.  The inspector view is
// intentionally compact; the browser window owns search, sorting, favorites,
// collections, import, preview-before-commit, and Apply/Cancel.
//
// This is ordinary AppKit code. It does not depend on a private Final Cut Pro
// browser API. FxPlug calls createView(forParameterID:) to embed the compact
// view in the inspector. The button first opens the outer wrapper organizer
// through a standard URL/notification bridge and falls back to this window if
// the host cannot launch it. See README.md for the host-version caveat.
//

import AppKit
import Foundation

final class CSTLUTParameterView: NSView {
    var onCommit: ((CSTLUTSelection) -> Void)?

    private(set) var selection = CSTLUTSelection.none() {
        didSet { updateSummary() }
    }
    private var libraryWindowController: CSTLUTLibraryWindowController?

    private let nameLabel = NSTextField(labelWithString: "LUT Library")
    private let summaryLabel = NSTextField(labelWithString: "No LUT")
    private let openButton = NSButton(title: "LUT Library…", target: nil, action: nil)
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let organizerRequestToken = UUID().uuidString

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setSelection(_ newSelection: CSTLUTSelection) {
        selection = newSelection
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 6
        let buttonWidth: CGFloat = 28
        let rowHeight: CGFloat = 24
        let rowY = max(padding, bounds.height - rowHeight - padding)

        nextButton.frame = NSRect(x: bounds.width - padding - buttonWidth, y: rowY,
                                  width: buttonWidth, height: rowHeight)
        previousButton.frame = NSRect(x: bounds.width - padding - buttonWidth * 2 - 3, y: rowY,
                                      width: buttonWidth, height: rowHeight)
        openButton.frame = NSRect(x: bounds.width - padding - buttonWidth * 2 - 3 - 118 - 4,
                                  y: rowY, width: 118, height: rowHeight)
        nameLabel.frame = NSRect(
            x: padding,
            y: rowY + 2,
            width: max(40, openButton.frame.minX - padding - 6),
            height: 18
        )
        let summaryRight = openButton.frame.minX - 6
        summaryLabel.frame = NSRect(x: padding, y: padding, width: max(40, summaryRight - padding), height: 18)
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor

        nameLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.toolTip = "Choose a creative Rec.709 display LUT."
        summaryLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.toolTip = "Selected LUT. No LUT is a clean bypass."

        for button in [openButton, previousButton, nextButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            addSubview(button)
        }
        addSubview(nameLabel)
        addSubview(summaryLabel)

        openButton.target = self
        openButton.action = #selector(openLibrary(_:))
        openButton.toolTip = "Browse, preview, import, favorite, and organize local .cube LUTs."
        previousButton.target = self
        previousButton.action = #selector(previousLUT(_:))
        previousButton.toolTip = "Select the previous LUT in name order."
        nextButton.target = self
        nextButton.action = #selector(nextLUT(_:))
        nextButton.toolTip = "Select the next LUT in name order."
        updateSummary()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(organizerDidSelect(_:)),
            name: CSTLUTOrganizerBridge.notificationName,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func updateSummary() {
        summaryLabel.stringValue = selection.identifier == 0 ? "No LUT" : selection.displayName
    }

    @objc private func openLibrary(_ sender: Any?) {
        // Prefer the outer wrapper organizer. This keeps NSOpenPanel, the
        // thumbnail grid, and the large browser window out of FCP's viewbridge
        // process. If the installed wrapper cannot be opened, retain a direct
        // AppKit fallback for hosts that do allow child windows from XPC.
        if let url = URL(string: "\(CSTLUTOrganizerBridge.urlScheme)://lut-library?request=\(organizerRequestToken)&selection=\(selection.identifier)"),
           NSWorkspace.shared.open(url) {
            return
        }
        openEmbeddedLibrary(sender)
    }

    @objc private func organizerDidSelect(_ notification: Notification) {
        guard let value = CSTLUTOrganizerBridge.selection(
            from: notification,
            requestToken: organizerRequestToken
        ) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.setSelection(value)
            self?.onCommit?(value)
        }
    }

    private func openEmbeddedLibrary(_ sender: Any?) {
        let controller: CSTLUTLibraryWindowController
        if let existing = libraryWindowController {
            controller = existing
        } else {
            let created = CSTLUTLibraryWindowController(selection: selection) { [weak self] value in
                self?.setSelection(value)
                self?.onCommit?(value)
            }
            libraryWindowController = created
            controller = created
        }
        controller.setSelection(selection)
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func previousLUT(_ sender: Any?) {
        let value = CSTLUTLibraryStore.shared.neighbor(of: selection, offset: -1)
        setSelection(value)
        onCommit?(value)
    }

    @objc private func nextLUT(_ sender: Any?) {
        let value = CSTLUTLibraryStore.shared.neighbor(of: selection, offset: 1)
        setSelection(value)
        onCommit?(value)
    }
}

private final class CSTLUTCardView: NSView {
    let lutIdentifier: UInt64
    let selection: CSTLUTSelection
    var onPreview: ((CSTLUTSelection) -> Void)?
    var onFavorite: (() -> Void)?

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton(title: "☆", target: nil, action: nil)

    init(record: CSTLUTRecord?, frame frameRect: NSRect, onPreview: @escaping (CSTLUTSelection) -> Void) {
        if let record {
            lutIdentifier = record.identifier
            selection = record.selection()
        } else {
            lutIdentifier = 0
            selection = CSTLUTSelection.none()
        }
        self.onPreview = onPreview
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = CSTLUTThumbnail.image(for: nil)
        addSubview(imageView)

        titleLabel.stringValue = selection.displayName
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        favoriteButton.isBordered = false
        favoriteButton.font = NSFont.systemFont(ofSize: 16)
        favoriteButton.toolTip = "Toggle favorite"
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite(_:))
        favoriteButton.isHidden = record == nil
        addSubview(favoriteButton)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("CSTLUTCardView is programmatic") }

    func setThumbnail(_ image: NSImage) { imageView.image = image }

    func setFavorite(_ favorite: Bool) {
        favoriteButton.title = favorite ? "★" : "☆"
        favoriteButton.contentTintColor = favorite ? .systemYellow : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 4
        imageView.frame = NSRect(x: inset, y: 28, width: bounds.width - inset * 2, height: bounds.height - 34)
        titleLabel.frame = NSRect(x: 22, y: 5, width: max(20, bounds.width - 44), height: 18)
        favoriteButton.frame = NSRect(x: bounds.width - 23, y: 2, width: 20, height: 20)
    }

    @objc private func clicked(_ sender: Any?) { onPreview?(selection) }

    @objc private func toggleFavorite(_ sender: Any?) {
        guard lutIdentifier != 0,
              let record = CSTLUTLibraryStore.shared.displayRecords().first(where: { $0.identifier == lutIdentifier }) else {
            return
        }
        CSTLUTLibraryStore.shared.toggleFavorite(record)
        setFavorite(!record.favorite)
        onFavorite?()
    }
}

private final class CSTThumbnailCancellation {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class CSTLUTGridView: NSView {
    var records: [CSTLUTRecord] = [] { didSet { rebuild() } }
    var onPreview: ((CSTLUTSelection) -> Void)?
    var onFavorite: (() -> Void)?
    private(set) var cards: [UInt64: CSTLUTCardView] = [:]
    private var thumbnailWorkItems: [DispatchWorkItem] = []
    private var thumbnailCancellations: [CSTThumbnailCancellation] = []
    private var rebuildGeneration = 0
    private let thumbnailSemaphore = DispatchSemaphore(value: 2)

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let columns = max(1, Int(bounds.width / 182))
        let cardWidth = max(120, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
        let cardHeight: CGFloat = 126
        for (index, card) in subviews.compactMap({ $0 as? CSTLUTCardView }).enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = NSRect(x: CGFloat(column) * (cardWidth + 8), y: CGFloat(row) * (cardHeight + 8),
                                width: cardWidth, height: cardHeight)
        }
        let rows = (subviews.count + columns - 1) / columns
        var documentFrame = frame
        documentFrame.size.height = max(1, CGFloat(rows) * (cardHeight + 8))
        frame = documentFrame
    }

    private func rebuild() {
        // Cancel queued thumbnail work when search/filter/sort changes. A
        // work item already inside the bounded parser may finish, but the
        // generation check below prevents stale UI work from being installed.
        rebuildGeneration += 1
        let generation = rebuildGeneration
        thumbnailWorkItems.forEach { $0.cancel() }
        thumbnailCancellations.forEach { $0.cancel() }
        thumbnailWorkItems.removeAll()
        thumbnailCancellations.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()

        // A bounded visible set keeps a weak Intel GPU and a normal inspector
        // responsive. Search and sort happen before this cap, so a user can
        // still reach any LUT without allocating hundreds of thumbnails.
        let visible = Array(records.prefix(100))
        let noneCard = CSTLUTCardView(record: nil, frame: .zero) { [weak self] value in
            self?.onPreview?(value)
        }
        addSubview(noneCard)
        cards[0] = noneCard

        for record in visible {
            let card = CSTLUTCardView(record: record, frame: .zero) { [weak self] value in
                self?.onPreview?(value)
            }
            card.setFavorite(record.favorite)
            card.onFavorite = { [weak self] in self?.onFavorite?() }
            addSubview(card)
            cards[record.identifier] = card

            // Parsing occurs off the main thread. AppKit thumbnail drawing is
            // returned to the main queue, and is limited to the visible cap.
            let cancellation = CSTThumbnailCancellation()
            thumbnailCancellations.append(cancellation)
            let workItem = DispatchWorkItem { [weak self, weak card] in
                guard !cancellation.isCancelled else { return }
                self?.thumbnailSemaphore.wait()
                defer { self?.thumbnailSemaphore.signal() }
                guard !cancellation.isCancelled else { return }
                let parsed = try? CSTLUTLibraryStore.shared.parsedLUT(for: record.selection())
                DispatchQueue.main.async {
                    guard let self, let card,
                          !cancellation.isCancelled,
                          self.rebuildGeneration == generation,
                          self.cards[record.identifier] === card else { return }
                    card.setThumbnail(CSTLUTThumbnail.image(for: parsed ?? nil))
                }
            }
            thumbnailWorkItems.append(workItem)
            DispatchQueue.global(qos: .utility).async(execute: workItem)
        }
        needsLayout = true
    }
}

final class CSTLUTLibraryWindowController: NSWindowController, NSWindowDelegate {
    private let commit: (CSTLUTSelection) -> Void
    private var pendingSelection: CSTLUTSelection
    private var selectedRecord: CSTLUTRecord?
    private var importInProgress = false
    private var previewGeneration = 0

    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let filterPopup = NSPopUpButton()
    private let collectionPopup = NSPopUpButton()
    private let grid = CSTLUTGridView()
    private let previewImageView = NSImageView()
    private let selectedLabel = NSTextField(labelWithString: "No LUT")
    private let statusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let addToCollectionButton = NSButton(title: "Add to Collection", target: nil, action: nil)

    init(selection: CSTLUTSelection, commit: @escaping (CSTLUTSelection) -> Void) {
        self.pendingSelection = selection
        self.commit = commit
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CST Grade — LUT Library"
        window.minSize = NSSize(width: 620, height: 420)
        super.init(window: window)
        window.delegate = self
        configure()
        setSelection(selection)
    }

    required init?(coder: NSCoder) { fatalError("CSTLUTLibraryWindowController is programmatic") }

    func setSelection(_ selection: CSTLUTSelection) {
        pendingSelection = selection
        selectedRecord = CSTLUTLibraryStore.shared.displayRecords().first(where: { $0.identifier == selection.identifier })
        updatePreview()
        refreshGrid()
    }

    override func showWindow(_ sender: Any?) {
        refreshGrid()
        super.showWindow(sender)
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        searchField.placeholderString = "Search LUTs"
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        content.addSubview(searchField)

        sortPopup.addItems(withTitles: ["Sort: Name", "Sort: Recent Added"])
        sortPopup.target = self
        sortPopup.action = #selector(filterChanged(_:))
        content.addSubview(sortPopup)

        filterPopup.addItems(withTitles: ["All LUTs", "Favorites", "Recents"])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged(_:))
        content.addSubview(filterPopup)
        rebuildCollectionMenu()
        collectionPopup.target = self
        collectionPopup.action = #selector(filterChanged(_:))
        content.addSubview(collectionPopup)

        let importButton = NSButton(title: "Import LUT…", target: self, action: #selector(importLUT(_:)))
        let folderButton = NSButton(title: "Import Folder…", target: self, action: #selector(importFolder(_:)))
        let collectionButton = NSButton(title: "New Collection…", target: self, action: #selector(newCollection(_:)))
        for button in [importButton, folderButton, collectionButton] {
            button.bezelStyle = .rounded
            content.addSubview(button)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.documentView = grid
        content.addSubview(scrollView)

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.image = CSTLUTThumbnail.image(for: nil)
        content.addSubview(previewImageView)
        selectedLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        selectedLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(selectedLabel)
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        addToCollectionButton.bezelStyle = .rounded
        addToCollectionButton.target = self
        addToCollectionButton.action = #selector(addToCollection(_:))
        content.addSubview(addToCollectionButton)

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        content.addSubview(applyButton)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        content.addSubview(cancelButton)

        grid.onPreview = { [weak self] selection in self?.preview(selection) }
        grid.onFavorite = { [weak self] in self?.refreshGrid() }

        let defaults = UserDefaults.standard
        searchField.stringValue = defaults.string(forKey: "CSTGrade.lastSearch") ?? ""
        sortPopup.selectItem(at: min(max(defaults.integer(forKey: "CSTGrade.lastSort"), 0), 1))
        filterPopup.selectItem(at: min(max(defaults.integer(forKey: "CSTGrade.lastFilter"), 0), 2))
        layoutControls()
    }

    func windowDidResize(_ notification: Notification) {
        layoutControls()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        layoutControls()
    }

    private func layoutControls() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let height = content.bounds.height
        let padding: CGFloat = 12
        let controlHeight: CGFloat = 25
        searchField.frame = NSRect(x: padding, y: height - padding - controlHeight, width: 190, height: controlHeight)
        sortPopup.frame = NSRect(x: 210, y: searchField.frame.minY, width: 120, height: controlHeight)
        filterPopup.frame = NSRect(x: 338, y: searchField.frame.minY, width: 112, height: controlHeight)
        collectionPopup.frame = NSRect(x: 460, y: searchField.frame.minY, width: 150, height: controlHeight)

        let topButtonY = searchField.frame.minY - controlHeight - 6
        let importButton = content.subviews.first(where: { ($0 as? NSButton)?.title == "Import LUT…" })
        let folderButton = content.subviews.first(where: { ($0 as? NSButton)?.title == "Import Folder…" })
        let collectionButton = content.subviews.first(where: { ($0 as? NSButton)?.title == "New Collection…" })
        importButton?.frame = NSRect(x: padding, y: topButtonY, width: 110, height: controlHeight)
        folderButton?.frame = NSRect(x: padding + 116, y: topButtonY, width: 125, height: controlHeight)
        collectionButton?.frame = NSRect(x: padding + 247, y: topButtonY, width: 140, height: controlHeight)

        let bottomHeight: CGFloat = 112
        let scrollTop = topButtonY - 8
        let scrollWidth = width - padding * 2
        let scrollView = content.subviews.compactMap { $0 as? NSScrollView }.first
        scrollView?.frame = NSRect(x: padding, y: bottomHeight + padding, width: scrollWidth, height: max(80, scrollTop - bottomHeight - padding))
        if let scrollView {
            var gridFrame = grid.frame
            gridFrame.size.width = max(1, scrollView.contentView.bounds.width)
            grid.frame = gridFrame
            grid.needsLayout = true
        }

        previewImageView.frame = NSRect(x: padding, y: padding + 28, width: 220, height: 78)
        selectedLabel.frame = NSRect(x: 244, y: padding + 72, width: max(100, width - 440), height: 20)
        statusLabel.frame = NSRect(x: 244, y: padding + 48, width: max(100, width - 440), height: 20)
        addToCollectionButton.frame = NSRect(x: 244, y: padding + 15, width: 145, height: controlHeight)
        cancelButton.frame = NSRect(x: width - padding - 170, y: padding + 15, width: 78, height: controlHeight)
        applyButton.frame = NSRect(x: width - padding - 84, y: padding + 15, width: 84, height: controlHeight)
    }

    private func refreshGrid() {
        guard !importInProgress else { return }
        UserDefaults.standard.set(searchField.stringValue, forKey: "CSTGrade.lastSearch")
        UserDefaults.standard.set(sortPopup.indexOfSelectedItem, forKey: "CSTGrade.lastSort")
        UserDefaults.standard.set(filterPopup.indexOfSelectedItem, forKey: "CSTGrade.lastFilter")
        UserDefaults.standard.set(collectionPopup.titleOfSelectedItem, forKey: "CSTGrade.lastCollection")
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered = CSTLUTLibraryStore.shared.displayRecords()
        if filterPopup.indexOfSelectedItem == 1 {
            filtered = filtered.filter(\.favorite)
        } else if filterPopup.indexOfSelectedItem == 2 {
            filtered = filtered.filter { $0.lastUsedAt != nil }
        }
        if collectionPopup.indexOfSelectedItem == 1 {
            filtered = filtered.filter(\.favorite)
        } else if collectionPopup.indexOfSelectedItem > 1,
           let title = collectionPopup.titleOfSelectedItem {
            filtered = filtered.filter { $0.collections.contains(title) }
        }
        if !query.isEmpty {
            filtered = filtered.filter { $0.displayName.lowercased().contains(query) }
        }
        if sortPopup.indexOfSelectedItem == 1 {
            filtered.sort {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.identifier < $1.identifier
            }
        } else {
            filtered.sort {
                let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.identifier < $1.identifier
            }
        }
        grid.records = filtered
        layoutControls()
    }

    private func rebuildCollectionMenu() {
        collectionPopup.removeAllItems()
        collectionPopup.addItem(withTitle: "Collection: All")
        collectionPopup.addItem(withTitle: "Collection: Favorites")
        for name in CSTLUTLibraryStore.shared.collectionNames() {
            collectionPopup.addItem(withTitle: name)
        }
        if let last = UserDefaults.standard.string(forKey: "CSTGrade.lastCollection"),
           collectionPopup.itemTitles.contains(last) {
            collectionPopup.selectItem(withTitle: last)
        } else {
            collectionPopup.selectItem(at: 0)
        }
    }

    private func preview(_ selection: CSTLUTSelection) {
        pendingSelection = selection
        selectedRecord = CSTLUTLibraryStore.shared.displayRecords().first(where: { $0.identifier == selection.identifier })
        updatePreview()
    }

    private func updatePreview() {
        previewGeneration += 1
        let generation = previewGeneration
        selectedLabel.stringValue = pendingSelection.identifier == 0 ? "No LUT (clean bypass)" : pendingSelection.displayName
        let selection = pendingSelection
        guard selection.identifier != 0 else {
            statusLabel.stringValue = "Reference chart preview; click Apply to commit"
            previewImageView.image = CSTLUTThumbnail.image(for: nil)
            addToCollectionButton.isEnabled = false
            applyButton.isEnabled = true
            return
        }

        statusLabel.stringValue = "Loading reference chart…"
        previewImageView.image = CSTLUTThumbnail.image(for: nil)
        applyButton.isEnabled = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let parsed = try CSTLUTLibraryStore.shared.parsedLUT(for: selection)
                DispatchQueue.main.async {
                    guard let self,
                          self.previewGeneration == generation,
                          self.pendingSelection.identifier == selection.identifier else { return }
                    self.statusLabel.stringValue = "Reference chart preview; click Apply to commit"
                    self.previewImageView.image = CSTLUTThumbnail.image(for: parsed)
                    self.applyButton.isEnabled = parsed != nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          self.previewGeneration == generation,
                          self.pendingSelection.identifier == selection.identifier else { return }
                    self.statusLabel.stringValue = "Unavailable: \(error.localizedDescription)"
                    self.previewImageView.image = CSTLUTThumbnail.image(for: nil)
                    self.applyButton.isEnabled = false
                }
            }
        }
        addToCollectionButton.isEnabled = selectedRecord != nil
    }

    @objc private func filterChanged(_ sender: Any?) { refreshGrid() }

    @objc private func importLUT(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["cube"]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.importURLs(panel.urls, recursive: false)
        }
    }

    @objc private func importFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.urls.first else { return }
            self.importURLs([url], recursive: true)
        }
    }

    private func importURLs(_ urls: [URL], recursive: Bool) {
        guard !importInProgress else { return }
        importInProgress = true
        statusLabel.stringValue = "Importing .cube files…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var added = 0
            var skipped: [String] = []
            var errors: [String] = []
            for url in urls {
                let result = CSTLUTLibraryStore.shared.importURL(url, recursive: recursive)
                added += result.added
                skipped.append(contentsOf: result.skipped)
                errors.append(contentsOf: result.errors)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importInProgress = false
                self.rebuildCollectionMenu()
                self.refreshGrid()
                if errors.isEmpty {
                    self.statusLabel.stringValue = "Imported \(added); skipped \(skipped.count) duplicate(s)"
                } else {
                    self.statusLabel.stringValue = "Imported \(added); \(errors.count) file(s) rejected"
                    let details = errors.prefix(10).joined(separator: "\n")
                    let remainder = errors.count > 10 ? "\n…and \(errors.count - 10) more." : ""
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Some LUTs could not be imported"
                    alert.informativeText = details + remainder
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func newCollection(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New LUT Collection"
        alert.informativeText = "Give the collection a short name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        CSTLUTLibraryStore.shared.createCollection(named: name)
        rebuildCollectionMenu()
        collectionPopup.selectItem(withTitle: name)
        refreshGrid()
    }

    @objc private func addToCollection(_ sender: Any?) {
        guard let record = selectedRecord,
              collectionPopup.indexOfSelectedItem > 1,
              let name = collectionPopup.titleOfSelectedItem else {
            statusLabel.stringValue = "Choose a collection first"
            return
        }
        CSTLUTLibraryStore.shared.add(record, toCollection: name)
        statusLabel.stringValue = "Added to \(name)"
        refreshGrid()
    }

    @objc private func apply(_ sender: Any?) {
        CSTLUTLibraryStore.shared.markUsed(pendingSelection)
        commit(pendingSelection)
        close()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        // Closing the window is equivalent to Cancel. The compact inspector
        // value has not changed until Apply calls the commit closure.
    }
}
