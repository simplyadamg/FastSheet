import AppKit
import ServiceManagement
import Carbon.HIToolbox

struct FolderEntry: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let parent: String
    let path: String
}

struct FolderGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var folders: [FolderEntry]
    var hotkeyCode: UInt16?
    var hotkeyModifiers: UInt
    var hotkeyDisplay: String?
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class Store {
    private let key = "folderHistory"
    private let hotlistKey = "folderHotlist"
    private let groupsKey = "folderGroups"
    var entries: [FolderEntry] {
        get { (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([FolderEntry].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    var hotlist: [FolderEntry] {
        get { (UserDefaults.standard.data(forKey: hotlistKey)).flatMap { try? JSONDecoder().decode([FolderEntry].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: hotlistKey) }
    }
    var groups: [FolderGroup] {
        get { (UserDefaults.standard.data(forKey: groupsKey)).flatMap { try? JSONDecoder().decode([FolderGroup].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: groupsKey) }
    }
    func record(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        var all = entries.filter { $0.path != url.path }
        all.insert(FolderEntry(id: url.path, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, parent: url.deletingLastPathComponent().lastPathComponent, path: url.path), at: 0)
        entries = Array(all.prefix(100))
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var status: NSStatusItem!
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastPath = ""
    private var hotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var groupHotKeys: [UUID: EventHotKeyRef] = [:]
    private var hotkeyCode: UInt16 { UInt16(UserDefaults.standard.integer(forKey: "hotkeyCode")) }
    private var hotkeyModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))) }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "▰"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show FinderStack", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Hotkey…", action: #selector(recordHotkey), keyEquivalent: ""))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FinderStack", action: #selector(quit), keyEquivalent: ""))
        status.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollFinder() }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.matches(event) { self.toggle(); return nil }
            if let self, self.openGroupForLocalHotkey(event) { return nil }
            return event
        }
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true { DispatchQueue.main.async { self?.toggle() } }
        }
        installCarbonHotkey()
    }

    private func pollFinder() {
        let script = "tell application \"Finder\" to get POSIX path of (target of front Finder window as alias)"
        guard let apple = NSAppleScript(source: script), let result = apple.executeAndReturnError(nil).stringValue else { return }
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != lastPath else { return }; lastPath = path
        store.record(URL(fileURLWithPath: path))
    }

    @objc private func toggle() {
        if let panel, panel.isVisible { panel.close(); self.panel = nil } else { showPanel() }
    }

    private func showPanel() {
        let controller = PopupController(entries: store.entries, hotlist: store.hotlist, groups: store.groups, onHotlistChanged: { [weak self] items in self?.store.hotlist = items }, onGroupsChanged: { [weak self] items in self?.store.groups = items; self?.installCarbonHotkey() }) { [weak self] paths, isMultiSelection in
            guard let self else { return }
            self.panel?.orderOut(nil); self.panel?.close(); self.panel = nil
            DispatchQueue.main.async {
                if isMultiSelection { self.openFolderLayout(paths) }
                else if let path = paths.first { self.openFolder(path) }
            }
        } onClose: { [weak self] in self?.panel?.close(); self?.panel = nil }
        let p = NSPanel(contentViewController: controller)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.setContentSize(NSSize(width: 900, height: 500)); p.center(); p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); panel = p
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openFolder(_ path: String) {
        guard let screen = screenUnderMouse() else { return }
        arrangeFinderWindowsAndOpen(path, on: screen)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func arrangeFinderWindowsAndOpen(_ path: String, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let width = Int(visible.width / 2)
        let height = Int(visible.height / 2)
        let rightX = Int(visible.maxX) - width
        let upperY = Int(primaryTop - visible.maxY)
        let lowerY = Int(primaryTop - visible.minY) - height
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Finder"
            set existingWindows to every Finder window
            repeat with existingWindow in existingWindows
                try
                    set position of existingWindow to {\(rightX), \(lowerY)}
                    set size of existingWindow to {\(width), \(height)}
                end try
            end repeat
            set selectedFolder to (POSIX file "\(escapedPath)" as alias)
            set selectedWindow to make new Finder window to selectedFolder
            set position of selectedWindow to {\(rightX), \(upperY)}
            set size of selectedWindow to {\(width), \(height)}
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("FinderStack arrangement failed: %@", error) }
    }

    private func openFolderLayout(_ paths: [String]) {
        guard let screen = screenUnderMouse(), paths.count > 1 else { return }
        let visible = screen.visibleFrame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let width = Int(visible.width / 2), height = Int(visible.height / 2)
        let leftX = Int(visible.minX), rightX = Int(visible.maxX) - width
        let upperY = Int(primaryTop - visible.maxY), lowerY = Int(primaryTop - visible.minY) - height
        let frames = [(rightX, upperY), (rightX, lowerY), (leftX, upperY), (leftX, lowerY)]
        var closeError: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to close every Finder window")?.executeAndReturnError(&closeError)
        if let closeError { NSLog("FinderStack could not close Finder windows: %@", closeError) }
        for (index, path) in paths.prefix(4).enumerated() {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let frame = frames[index]
            let command = """
            tell application "Finder"
                set selectedFolder to (POSIX file "\(escaped)" as alias)
                set selectedWindow to make new Finder window to selectedFolder
                set position of selectedWindow to {\(frame.0), \(frame.1)}
                set size of selectedWindow to {\(width), \(height)}
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: command)?.executeAndReturnError(&error)
            if let error { NSLog("FinderStack could not open layout item %d: %@", index + 1, error) }
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [.activateAllWindows])
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard UserDefaults.standard.object(forKey: "hotkeyCode") != nil else { return false }
        return event.keyCode == hotkeyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotkeyModifiers.intersection(.deviceIndependentFlagsMask)
    }

    @objc private func recordHotkey() {
        let alert = NSAlert(); alert.messageText = "Set FinderStack Hotkey"; alert.informativeText = "Click the field, then press the key combination you want to use."; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = HotkeyField(frame: NSRect(x: 0, y: 0, width: 260, height: 28)); field.isEditable = false; field.isSelectable = false; field.stringValue = hotkeyCode == 0 ? "Press a shortcut…" : "Current shortcut: \(hotkeyLabel())"; alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let event = field.event else { return }
        UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkeyCode"); UserDefaults.standard.set(Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue), forKey: "hotkeyModifiers")
        installCarbonHotkey()
    }

    private func hotkeyLabel() -> String { "Configured" }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); item.state = .off } else { try SMAppService.mainApp.register(); item.state = .on } } catch { NSAlert(error: error).runModal() }
    }

    private func installCarbonHotkey() {
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey); self.carbonHotKey = nil }
        if carbonHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, userData in
                guard let event, let userData else { return noErr }
                let owner = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID(); var size = MemoryLayout<EventHotKeyID>.size
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, size, &size, &id)
                DispatchQueue.main.async { owner.handleHotkey(id.id) }
                return noErr
            }
            InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &carbonHandler)
        }
        guard UserDefaults.standard.object(forKey: "hotkeyCode") != nil else { return }
        var id = EventHotKeyID(signature: OSType(0x4653544B), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(hotkeyCode), carbonModifiers(), id, GetApplicationEventTarget(), 0, &ref)
        carbonHotKey = ref
        for (_, ref) in groupHotKeys { UnregisterEventHotKey(ref) }; groupHotKeys.removeAll()
    }

    private func openGroupForLocalHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        guard !UserDefaults.standard.bool(forKey: "groupHotkeysSuspended"), let group = Store().groups.first(where: { $0.hotkeyCode == event.keyCode && $0.hotkeyModifiers == flags }) else { return false }
        let paths = group.folders.map(\.path); if paths.count > 1 { openFolderLayout(paths) } else if let path = paths.first { openFolder(path) }; return true
    }

    private func handleHotkey(_ id: UInt32) { if id == 1 { toggle() } }

    private func carbonModifiers() -> UInt32 {
        let flags = hotkeyModifiers; var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }; if flags.contains(.option) { result |= UInt32(optionKey) }; if flags.contains(.control) { result |= UInt32(controlKey) }; if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

final class HotkeyField: NSTextField {
    var event: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isEditable = false; isSelectable = false; wantsLayer = true; layer?.borderWidth = 1; layer?.borderColor = NSColor.controlAccentColor.cgColor; return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) { self.event = event; stringValue = HotkeyField.modifierLabel(event.modifierFlags) + (event.charactersIgnoringModifiers ?? "").uppercased() }
    static func display(for event: NSEvent) -> String { modifierLabel(event.modifierFlags) + keyLabel(event) }
    private static func modifierLabel(_ flags: NSEvent.ModifierFlags) -> String { var s = ""; if flags.contains(.command) { s += "⌘" }; if flags.contains(.option) { s += "⌥" }; if flags.contains(.control) { s += "⌃" }; if flags.contains(.shift) { s += "⇧" }; return s }
    private static func keyLabel(_ event: NSEvent) -> String { switch event.keyCode { case 36: return "↩"; case 48: return "⇥"; case 49: return "Space"; case 51: return "⌫"; case 53: return "⎋"; case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"; case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"; case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"; default: return (event.charactersIgnoringModifiers ?? "").uppercased() } }
}

final class PopupController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let folderPasteboardType = NSPasteboard.PasteboardType("com.finderstack.folder-path")
    private let groupPasteboardType = NSPasteboard.PasteboardType("com.finderstack.group-id")
    private let entries: [FolderEntry]; private var hotlist: [FolderEntry]; private var groups: [FolderGroup]
    private let onHotlistChanged: ([FolderEntry]) -> Void; private let onGroupsChanged: ([FolderGroup]) -> Void; private let onOpen: ([String], Bool) -> Void; private let onClose: () -> Void
    private let search = NSSearchField(), recentTable = NSTableView(), hotlistTable = NSTableView(), groupTable = NSTableView()
    private let recentScroll = NSScrollView(), hotlistScroll = NSScrollView(), groupScroll = NSScrollView()
    private var filteredRecent: [FolderEntry] = [], filteredHotlist: [FolderEntry] = [], filteredGroups: [FolderGroup] = [], selected: [FolderEntry] = []; private var flagsMonitor: Any?; private var escapeMonitor: Any?
    private var editingGroupID: UUID?
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let groupHeader = NSTextField(labelWithString: "GROUPS")
    private let positionLabels = ["UR", "LR", "UL", "LL"]
    private let positionColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple]
    init(entries: [FolderEntry], hotlist: [FolderEntry], groups: [FolderGroup], onHotlistChanged: @escaping ([FolderEntry]) -> Void, onGroupsChanged: @escaping ([FolderGroup]) -> Void, onOpen: @escaping ([String], Bool) -> Void, onClose: @escaping () -> Void) {
        self.entries = entries; self.hotlist = hotlist; self.groups = groups; self.onHotlistChanged = onHotlistChanged; self.onGroupsChanged = onGroupsChanged; self.onOpen = onOpen; self.onClose = onClose
        filteredRecent = entries; filteredHotlist = hotlist; filteredGroups = groups; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let card = NSVisualEffectView(); card.material = .popover; card.blendingMode = .behindWindow; card.state = .active; card.wantsLayer = true; card.layer?.cornerRadius = 16; card.layer?.masksToBounds = true; view = card
        search.placeholderString = "Search folders"; search.font = .systemFont(ofSize: 16); search.delegate = self; view.addSubview(search)
        configure(hotlistTable, in: hotlistScroll); configure(recentTable, in: recentScroll); configure(groupTable, in: groupScroll)
        let hotLabel = NSTextField(labelWithString: "HOTLIST"); let recentLabel = NSTextField(labelWithString: "RECENT")
        for label in [hotLabel, recentLabel, groupHeader] { label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor; view.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false }
        backButton.target = self; backButton.action = #selector(backToGroups); backButton.isBordered = false; backButton.isHidden = true; view.addSubview(backButton); backButton.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox(); divider.boxType = .separator; view.addSubview(divider)
        for item in [search, hotlistScroll, recentScroll, groupScroll, divider] { item.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            hotLabel.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), hotLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            recentLabel.topAnchor.constraint(equalTo: hotLabel.topAnchor), recentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 306), groupHeader.topAnchor.constraint(equalTo: hotLabel.topAnchor), groupHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 632),
            backButton.centerYAnchor.constraint(equalTo: groupHeader.centerYAnchor), backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 606), backButton.widthAnchor.constraint(equalToConstant: 22), backButton.heightAnchor.constraint(equalToConstant: 20),
            divider.topAnchor.constraint(equalTo: hotLabel.topAnchor), divider.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10), divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 296), divider.widthAnchor.constraint(equalToConstant: 1),
            hotlistScroll.topAnchor.constraint(equalTo: hotLabel.bottomAnchor, constant: 5), hotlistScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), hotlistScroll.widthAnchor.constraint(equalToConstant: 280), hotlistScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            recentScroll.topAnchor.constraint(equalTo: recentLabel.bottomAnchor, constant: 5), recentScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 308), recentScroll.widthAnchor.constraint(equalToConstant: 280), recentScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            groupScroll.topAnchor.constraint(equalTo: groupHeader.bottomAnchor, constant: 5), groupScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 608), groupScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), groupScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }
    private func configure(_ table: NSTableView, in scroll: NSScrollView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.headerView = nil; table.rowHeight = 27; table.intercellSpacing = .zero; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(rowReleased(_:)); table.allowsMultipleSelection = false; table.registerForDraggedTypes([folderPasteboardType, groupPasteboardType]); table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; view.addSubview(scroll)
    }
    override func viewDidAppear() {
        search.becomeFirstResponder()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onClose(); return nil }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            if !event.modifierFlags.contains(.command), !self.selected.isEmpty { let paths = self.selected.map(\.path); self.onOpen(paths, paths.count > 1); return nil }
            return event
        }
    }
    override func viewWillDisappear() { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }; self.escapeMonitor = nil; self.flagsMonitor = nil }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    private func applyFilter() {
        let q = search.stringValue.lowercased(), matches: (FolderEntry) -> Bool = { q.isEmpty || ($0.name + " " + $0.parent).lowercased().contains(q) }
        filteredRecent = entries.filter(matches); filteredHotlist = hotlist.filter(matches); filteredGroups = groups.filter { q.isEmpty || $0.name.lowercased().contains(q) }; recentTable.reloadData(); hotlistTable.reloadData(); groupTable.reloadData()
    }
    private func rows(for table: NSTableView) -> [FolderEntry] { table === hotlistTable ? filteredHotlist : filteredRecent }
    func numberOfRows(in tableView: NSTableView) -> Int { if tableView === groupTable, let id = editingGroupID { return groups.first(where: { $0.id == id })?.folders.count ?? 0 }; return tableView === groupTable ? filteredGroups.count : rows(for: tableView).count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === groupTable {
            if let id = editingGroupID, let group = groups.first(where: { $0.id == id }) {
                let entry = group.folders[row], container = NSView(); let title = NSTextField(labelWithString: "\(positionLabels[row])  \(entry.name)"); title.font = .systemFont(ofSize: 13, weight: .medium); let parent = NSTextField(labelWithString: "— \(entry.parent)"); parent.font = .systemFont(ofSize: 11); parent.textColor = .secondaryLabelColor
                for item in [title, parent] { container.addSubview(item); item.translatesAutoresizingMaskIntoConstraints = false }; NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9), title.centerYAnchor.constraint(equalTo: container.centerYAnchor), parent.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5), parent.centerYAnchor.constraint(equalTo: container.centerYAnchor)]); return container
            }
            let group = filteredGroups[row], container = NSView(); let title = NSTextField(labelWithString: group.name); title.font = .systemFont(ofSize: 13, weight: .medium); let count = NSTextField(labelWithString: "\(group.folders.count)/4"); count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor; let edit = NSButton(title: "Edit", target: self, action: #selector(editGroup(_:))); edit.tag = row; edit.bezelStyle = .inline; edit.font = .systemFont(ofSize: 11); let key = NSButton(title: group.hotkeyDisplay ?? "Key", target: self, action: #selector(groupHotkey(_:))); key.tag = row; key.bezelStyle = .inline; key.font = .systemFont(ofSize: 11); let delete = NSButton(title: "×", target: self, action: #selector(deleteGroup(_:))); delete.tag = row; delete.isBordered = false
            for item in [title, count, edit, key, delete] { container.addSubview(item); item.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9), title.centerYAnchor.constraint(equalTo: container.centerYAnchor), count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6), count.centerYAnchor.constraint(equalTo: container.centerYAnchor), delete.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3), delete.centerYAnchor.constraint(equalTo: container.centerYAnchor), edit.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -2), edit.centerYAnchor.constraint(equalTo: container.centerYAnchor), key.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -2), key.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
            return container
        }
        let entry = rows(for: tableView)[row], container = NSView()
        let title = NSTextField(labelWithString: entry.name); title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let parent = NSTextField(labelWithString: "— \(entry.parent)"); parent.font = .systemFont(ofSize: 11); parent.textColor = .secondaryLabelColor; parent.lineBreakMode = .byTruncatingMiddle
        let action = NSButton(title: tableView === hotlistTable ? "×" : "+", target: self, action: tableView === hotlistTable ? #selector(removeHotlist(_:)) : #selector(addHotlist(_:))); action.tag = row; action.isBordered = false; action.font = .systemFont(ofSize: 16); action.contentTintColor = .secondaryLabelColor
        for item in [title, parent, action] { container.addSubview(item); item.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([action.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7), action.centerYAnchor.constraint(equalTo: container.centerYAnchor), action.widthAnchor.constraint(equalToConstant: 22), title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9), title.centerYAnchor.constraint(equalTo: container.centerYAnchor), parent.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5), parent.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        var trailingAnchor = action.leadingAnchor
        if let position = selected.firstIndex(of: entry) {
            let badge = NSTextField(labelWithString: positionLabels[position]); badge.font = .boldSystemFont(ofSize: 10); badge.textColor = .white; badge.alignment = .center; badge.wantsLayer = true; badge.layer?.backgroundColor = positionColors[position].cgColor; badge.layer?.cornerRadius = 6; container.addSubview(badge); badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([badge.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -3), badge.centerYAnchor.constraint(equalTo: container.centerYAnchor), badge.widthAnchor.constraint(equalToConstant: 27), badge.heightAnchor.constraint(equalToConstant: 18)]); trailingAnchor = badge.leadingAnchor
        }
        parent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5).isActive = true
        return container
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let result = SelectionRowView(); if tableView !== groupTable, let position = selected.firstIndex(of: rows(for: tableView)[row]) { result.selectionColor = positionColors[position].withAlphaComponent(0.22) }; return result }
    @objc private func rowReleased(_ tableView: NSTableView) {
        let row = tableView.clickedRow
        if tableView === groupTable {
            if editingGroupID != nil { return }
            guard row >= 0, filteredGroups.indices.contains(row) else { return }
            if editingGroupID == nil { let paths = filteredGroups[row].folders.map(\.path); onOpen(paths, paths.count > 1) }; tableView.deselectAll(nil); return
        }
        guard row >= 0, rows(for: tableView).indices.contains(row) else { return }
        let entry = rows(for: tableView)[row]
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { if let index = selected.firstIndex(of: entry) { selected.remove(at: index) } else if selected.count < 4 { selected.append(entry) }; recentTable.reloadData(); hotlistTable.reloadData() }
        else { onOpen([entry.path], false) }
        tableView.deselectAll(nil)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === groupTable, editingGroupID == nil, filteredGroups.indices.contains(row) { let item = NSPasteboardItem(); item.setString(filteredGroups[row].id.uuidString, forType: groupPasteboardType); return item }
        let path: String?
        if tableView === groupTable, let id = editingGroupID { path = groups.first(where: { $0.id == id })?.folders[safe: row]?.path }
        else { path = rows(for: tableView).indices.contains(row) ? rows(for: tableView)[row].path : nil }
        guard let path else { return nil }; let item = NSPasteboardItem(); item.setString(path, forType: folderPasteboardType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if tableView === groupTable, editingGroupID == nil, info.draggingPasteboard.string(forType: groupPasteboardType) != nil { tableView.setDropRow(row, dropOperation: .above); return .move }
        guard tableView === hotlistTable || tableView === groupTable, info.draggingPasteboard.string(forType: folderPasteboardType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above); return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === groupTable, editingGroupID == nil, let idString = info.draggingPasteboard.string(forType: groupPasteboardType), let id = UUID(uuidString: idString), let source = groups.firstIndex(where: { $0.id == id }) {
            let group = groups.remove(at: source); let target = min(row, groups.count); groups.insert(group, at: target); onGroupsChanged(groups); applyFilter(); return true
        }
        guard let path = info.draggingPasteboard.string(forType: folderPasteboardType), let entry = hotlist.first(where: { $0.path == path }) ?? entries.first(where: { $0.path == path }) else { return false }
        if tableView === groupTable {
            if let id = editingGroupID { guard var group = groups.first(where: { $0.id == id }), row <= group.folders.count else { return false }; group.folders.removeAll { $0.path == path }; group.folders.insert(entry, at: min(row, group.folders.count)); groups = groups.map { $0.id == id ? group : $0 }; onGroupsChanged(groups); groupTable.reloadData(); return true }
            if filteredGroups.indices.contains(row) { var group = filteredGroups[row]; guard group.folders.count < 4, !group.folders.contains(where: { $0.path == path }) else { NSSound.beep(); return false }; group.folders.append(entry); groups = groups.map { $0.id == group.id ? group : $0 }; onGroupsChanged(groups); applyFilter(); return true }
            let alert = NSAlert(); alert.messageText = "Name New Group"; alert.informativeText = "Choose a name for this folder group."; let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); alert.accessoryView = field; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field; UserDefaults.standard.set(true, forKey: "groupHotkeysSuspended"); defer { UserDefaults.standard.set(false, forKey: "groupHotkeysSuspended") }; guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }; groups.append(FolderGroup(id: UUID(), name: field.stringValue, folders: [entry], hotkeyCode: nil, hotkeyModifiers: 0, hotkeyDisplay: nil)); onGroupsChanged(groups); applyFilter(); return true
        }
        let targetPath = filteredHotlist.indices.contains(row) ? filteredHotlist[row].path : nil
        hotlist.removeAll { $0.path == path }
        let insertion = targetPath.flatMap { target in hotlist.firstIndex(where: { $0.path == target }) } ?? hotlist.endIndex
        hotlist.insert(entry, at: insertion); onHotlistChanged(hotlist); applyFilter(); hotlistTable.deselectAll(nil); return true
    }
    @objc private func addHotlist(_ sender: NSButton) { guard filteredRecent.indices.contains(sender.tag) else { return }; let entry = filteredRecent[sender.tag]; if !hotlist.contains(where: { $0.path == entry.path }) { hotlist.append(entry); onHotlistChanged(hotlist); applyFilter() } }
    @objc private func removeHotlist(_ sender: NSButton) { guard filteredHotlist.indices.contains(sender.tag) else { return }; let entry = filteredHotlist[sender.tag]; hotlist.removeAll { $0.path == entry.path }; selected.removeAll { $0.path == entry.path }; onHotlistChanged(hotlist); applyFilter() }
    @objc private func editGroup(_ sender: NSButton) { guard filteredGroups.indices.contains(sender.tag) else { return }; openGroupEditor(filteredGroups[sender.tag]) }
    @objc private func deleteGroup(_ sender: NSButton) { guard filteredGroups.indices.contains(sender.tag) else { return }; let group = filteredGroups[sender.tag]; let alert = NSAlert(); alert.messageText = "Delete \(group.name)?"; alert.informativeText = "The folders will remain in Recent and Hotlist."; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }; groups.removeAll { $0.id == group.id }; onGroupsChanged(groups); applyFilter() }
    @objc private func groupHotkey(_ sender: NSButton) { guard filteredGroups.indices.contains(sender.tag) else { return }; let group = filteredGroups[sender.tag]; let alert = NSAlert(); alert.messageText = "Set Hotkey for \(group.name)"; alert.informativeText = "Press the shortcut you want to open this group."; let field = HotkeyField(frame: NSRect(x: 0, y: 0, width: 260, height: 28)); field.isEditable = false; field.isSelectable = false; field.stringValue = "Press a shortcut…"; alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field; UserDefaults.standard.set(true, forKey: "groupHotkeysSuspended"); defer { UserDefaults.standard.set(false, forKey: "groupHotkeysSuspended") }; guard alert.runModal() == .alertFirstButtonReturn, let event = field.event else { return }; let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue; let mainConflict = UserDefaults.standard.object(forKey: "hotkeyCode") != nil && UInt16(UserDefaults.standard.integer(forKey: "hotkeyCode")) == event.keyCode && UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers")) == modifiers; let groupConflict = groups.contains { $0.id != group.id && $0.hotkeyCode == event.keyCode && $0.hotkeyModifiers == modifiers }; guard !mainConflict && !groupConflict else { NSAlert(error: NSError(domain: "FinderStack", code: 1, userInfo: [NSLocalizedDescriptionKey: "That shortcut is already assigned to FinderStack or another group."])).runModal(); return }; groups = groups.map { var item = $0; if item.id == group.id { item.hotkeyCode = event.keyCode; item.hotkeyModifiers = modifiers; item.hotkeyDisplay = HotkeyField.display(for: event) }; return item }; onGroupsChanged(groups); applyFilter() }
    private func openGroupEditor(_ group: FolderGroup) { editingGroupID = group.id; backButton.isHidden = false; groupHeader.stringValue = "\(group.name)  \(group.hotkeyDisplay ?? "")"; groupTable.reloadData() }
    @objc private func backToGroups() { editingGroupID = nil; backButton.isHidden = true; groupHeader.stringValue = "GROUPS"; groupTable.reloadData() }
}

final class SelectionRowView: NSTableRowView {
    var selectionColor: NSColor?
    override func drawBackground(in dirtyRect: NSRect) { super.drawBackground(in: dirtyRect); guard let selectionColor else { return }; selectionColor.setFill(); bounds.insetBy(dx: 4, dy: 1).fill() }
}

let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
