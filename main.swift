import AppKit
import Foundation

let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmuxterm")
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/cmux-touchbar")

// Read only process IDs, parent IDs and executable names; never arguments or environment.
func processParents() -> [Int32: (Int32, String)]? {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,ppid=,comm="]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
    var parents: [Int32: (Int32, String)] = [:]
    for line in text.split(separator: "\n") {
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        if fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) {
            parents[pid] = (parent, String(fields[2]))
        }
    }
    return parents
}

func liveCmuxSurfaces() -> Set<String>? {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
    task.arguments = ["tree", "--all", "--json", "--id-format", "uuids"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return cmuxSurfaceIDs(from: data)
}
func cmuxSurfaceIDs(from data: Data) -> Set<String>? {
    guard let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = tree["windows"] as? [[String: Any]] else { return nil }
    var surfaces = Set<String>()
    for window in windows {
        for workspace in window["workspaces"] as? [[String: Any]] ?? [] {
            for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                    if let id = surface["id"] as? String { surfaces.insert(id.lowercased()) }
                }
            }
        }
    }
    return surfaces
}

func belongsToCmux(_ pid: Int32, _ parents: [Int32: (Int32, String)]) -> Bool {
    var current = pid
    var visited = Set<Int32>()
    while current > 1 && !visited.contains(current) {
        visited.insert(current)
        guard let (parent, executable) = parents[current] else { return false }
        if executable == "/Applications/cmux.app/Contents/MacOS/cmux" { return true }
        current = parent
    }
    return false
}
func hasLiveAgentProcess(_ pid: Int32, _ parents: [Int32: (Int32, String)]?) -> Bool? {
    guard let parents else { return nil }
    return pid > 0 && parents[pid] != nil
}
func shouldKeepHookSession(_ session: [String: Any], _ liveSurfaces: Set<String>) -> Bool {
    guard let surface = session["surfaceId"] as? String else { return false }
    return liveSurfaces.contains(surface.lowercased())
}
func agentState(_ state: String, processIsLive: Bool?) -> String {
    guard let processIsLive else { return state }
    return processIsLive || state == "idle" || state == "done" ? state : "idle"
}
func activeCodexSurfaces() -> Set<String> {
    let leaseDir = stateDir.appendingPathComponent("codex-monitor-leases")
    var surfaces = Set<String>()
    for url in (try? FileManager.default.contentsOfDirectory(at: leaseDir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let lease = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let surface = lease["surfaceId"] as? String else { continue }
        surfaces.insert(surface)
    }
    return surfaces
}

struct AgentState: Codable {
    var agent: String
    var state: String
    var surface: String
    var workspace: String
    var updated: Double
}
let labels = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode"]
let staleRunningSeconds: TimeInterval = 60
let preferences = UserDefaults.standard
let settingsChanged = Notification.Name("local.jwtan.cmux-touchbar.settingsChanged")
let usage = "Usage: cmux-touchbar [--status | --set-display-mode always|follow | --set-max-sessions N | --self-test]"
func statusCardCornerRadius(forHeight height: CGFloat) -> CGFloat {
    min(10, height * 0.4)
}
func maxAlignedCardOffset(contentWidth: CGFloat, viewportWidth: CGFloat, cardStride: CGFloat) -> CGFloat {
    guard cardStride > 0 else { return 0 }
    let maxOffset = max(0, contentWidth - viewportWidth)
    return floor(maxOffset / cardStride) * cardStride
}
func alignedCardOffset(_ proposedOffset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat, cardStride: CGFloat) -> CGFloat {
    guard cardStride > 0 else { return 0 }
    let maxOffset = maxAlignedCardOffset(contentWidth: contentWidth, viewportWidth: viewportWidth, cardStride: cardStride)
    return min(max(0, (proposedOffset / cardStride).rounded() * cardStride), maxOffset)
}
func displayModeSelection(alwaysShow: Bool) -> (always: Bool, follow: Bool) {
    (always: alwaysShow, follow: !alwaysShow)
}
func updateDisplayModeMenu(alwaysShow: Bool, alwaysItem: NSMenuItem?, followItem: NSMenuItem?) {
    let selection = displayModeSelection(alwaysShow: alwaysShow)
    alwaysItem?.state = selection.always ? .on : .off
    followItem?.state = selection.follow ? .on : .off
}
func configureStatusCardLayer(_ layer: CALayer, forHeight height: CGFloat) {
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.cornerRadius = statusCardCornerRadius(forHeight: height)
}
func codexHookState(_ hook: String) -> String? {
    switch hook {
    case "Stop":
        return "done"
    // Aside can deliver the turn lifecycle through tool hooks while the
    // terminal session record still reports idle. Treat active Codex hooks
    // as running until the Stop hook arrives.
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "SubagentStart", "SubagentStop":
        return "running"
    default:
        return nil
    }
}
func sessionTitles(_ states: [AgentState]) -> [(AgentState, String)] {
    let sorted = states.sorted { ($0.agent, $0.surface) < ($1.agent, $1.surface) }
    let counts = Dictionary(grouping: sorted, by: { $0.agent }).mapValues { $0.count }
    var indexes: [String: Int] = [:]
    return sorted.map { record in
        indexes[record.agent, default: 0] += 1
        let label = labels[record.agent] ?? record.agent.capitalized
        let suffix = counts[record.agent, default: 0] > 1 ? " \(indexes[record.agent]!)" : ""
        let state = ["running": "Running", "needsInput": "Input", "idle": "Idle", "done": "Done"][record.state] ?? "Unknown"
        return (record, "\(label)\(suffix) · \(state)")
    }
}
func shouldPresent(always: Bool, cmuxActive: Bool, hasSessions: Bool) -> Bool {
    always || cmuxActive
}
struct CodexEventState {
    var state: String
    var updated: Double
    var surface: String
    var workspace: String
    var pid: Int32
}
func shouldKeepCodexEvent(_ event: CodexEventState, _ liveSurfaces: Set<String>, now: Date = Date()) -> Bool {
    liveSurfaces.contains(event.surface.lowercased()) &&
        event.updated > 0 && now.timeIntervalSince1970 - event.updated < 600
}
func recentCodexHookStates() -> [String: CodexEventState] {
    let url = stateDir.appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: url),
          let text = String(data: Data(data.suffix(512 * 1024)), encoding: .utf8) else { return [:] }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var latest: [String: CodexEventState] = [:]
    for line in text.split(separator: "\n") {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = raw["payload"] as? [String: Any],
              let hook = payload["hook_event_name"] as? String,
              let state = codexHookState(hook),
              let encodedSession = payload["session_id"] as? String,
              let encoded = encodedSession.split(separator: ":").last,
              let decoded = Data(base64Encoded: String(encoded)),
              let sessionId = String(data: decoded, encoding: .utf8) else { continue }
        let surface = (payload["surface_id"] as? String) ?? (raw["surface_id"] as? String) ?? ""
        let workspace = (payload["workspace_id"] as? String) ?? (raw["workspace_id"] as? String) ?? ""
        let pid = (payload["_ppid"] as? NSNumber).map { Int32($0.intValue) } ?? 0
        guard !surface.isEmpty else { continue }
        let updated = (raw["occurred_at"] as? String).flatMap { formatter.date(from: $0)?.timeIntervalSince1970 } ?? 0
        latest[sessionId] = CodexEventState(state: state, updated: updated, surface: surface, workspace: workspace, pid: pid)
    }
    return latest
}
func liveStates(liveSurfaceQuery: () -> Set<String>? = liveCmuxSurfaces) -> (Bool, [AgentState]) {
    guard let liveSurfaces = liveSurfaceQuery() else { return (false, []) }
    let parents = processParents()
    let codexEvents = recentCodexHookStates()
    let leasedCodexSurfaces = activeCodexSurfaces()
    var latest: [String: AgentState] = [:]
    for url in (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasSuffix("-hook-sessions.json") {
        guard let data = try? Data(contentsOf: url), let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let agent = String(url.lastPathComponent.dropLast("-hook-sessions.json".count))
        let sessionMap = store["sessions"] as? [String: Any] ?? [:]
        for rawSession in sessionMap.values {
            guard let session = rawSession as? [String: Any] else { continue }
            guard let surface = session["surfaceId"] as? String,
                  let workspace = session["workspaceId"] as? String else { continue }
            let pid = (session["pid"] as? NSNumber).map { Int32($0.intValue) } ?? 0
            // The cmux surface determines whether the tab exists. The agent process only
            // determines whether an active-looking state should be shown as Idle.
            guard shouldKeepHookSession(session, liveSurfaces) else { continue }
            let runtimeStatus = session["runtimeStatus"] as? String ?? ""
            let lifecycle = session["agentLifecycle"] as? String ?? ""
            let rawState: String
            if runtimeStatus == "running" || lifecycle == "running" {
                rawState = "running"
            } else if agent == "codex" {
                rawState = runtimeStatus.isEmpty ? (lifecycle.isEmpty ? "idle" : lifecycle) : runtimeStatus
            } else {
                rawState = lifecycle.isEmpty ? (runtimeStatus.isEmpty ? "unknown" : runtimeStatus) : lifecycle
            }
            let sessionUpdated = session["updatedAt"] as? Double ?? 0
            let sessionId = session["sessionId"] as? String ?? ""
            let eventState = agent == "codex" ? codexEvents[sessionId] : nil
            let state: String
            if agent == "codex", eventState?.state == "running", rawState != "running", !leasedCodexSurfaces.contains(surface) {
                state = rawState
            } else {
                state = eventState?.state ?? rawState
            }
            let updated = eventState?.updated ?? sessionUpdated
            let pidLive = hasLiveAgentProcess(pid, parents)
            let staleRunning = (state == "running" || state == "needsInput") && updated > 0 && Date().timeIntervalSince1970 - updated >= staleRunningSeconds
            let liveState = staleRunning ? "idle" : agentState(state, processIsLive: pidLive)
            let agedState = liveState == "done" && updated > 0 && Date().timeIntervalSince1970 - updated >= CodexLifecycle.completedDisplaySeconds ? "idle" : liveState
            let record = AgentState(agent: agent, state: agedState, surface: surface, workspace: workspace, updated: updated)
            if record.updated >= (latest[surface]?.updated ?? 0) { latest[surface] = record }
        }
    }
    // A Codex hook-session record can be briefly missing (notably when resumed
    // through Aside). Recover its identity from recent events only while its
    // surface is still open in cmux.
    for event in codexEvents.values where !event.surface.isEmpty && leasedCodexSurfaces.contains(event.surface) {
        guard shouldKeepCodexEvent(event, liveSurfaces) else { continue }
        let staleRunning = (event.state == "running" || event.state == "needsInput") && event.updated > 0 && Date().timeIntervalSince1970 - event.updated >= staleRunningSeconds
        let liveState = staleRunning ? "idle" : agentState(event.state, processIsLive: hasLiveAgentProcess(event.pid, parents))
        let agedState = liveState == "done" && event.updated > 0 && Date().timeIntervalSince1970 - event.updated >= CodexLifecycle.completedDisplaySeconds ? "idle" : liveState
        let record = AgentState(agent: "codex", state: agedState, surface: event.surface, workspace: event.workspace, updated: event.updated)
        if record.updated >= (latest[event.surface]?.updated ?? 0) { latest[event.surface] = record }
    }
    let configuredLimit = preferences.object(forKey: "maxSessions") as? Int ?? 3
    let limit = max(1, configuredLimit)
    let currentTabs = latest.values.sorted { $0.updated > $1.updated }.prefix(limit)
    return (true, Array(currentTabs))
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    let stripIdentifier = "cmux-agent-strip"
    let statusCardWidth: CGFloat = 160
    let stripItemHeight: CGFloat = 28
    let stripViewportWidth: CGFloat = 680
    let stripCardSpacing: CGFloat = 8
    let stripCardInset: CGFloat = 8
    let stripControlWidth: CGFloat = 26
    let stripControlSpacing: CGFloat = 4
    var stripCardStride: CGFloat { statusCardWidth + stripCardSpacing }
    var stripContainerWidth: CGFloat { stripViewportWidth + 2 * stripControlWidth + 2 * stripControlSpacing }
    var bar = NSTouchBar()
    var items: [String: NSButton] = [:]
    var stripScrollView: NSScrollView?
    var stripStack: NSStackView?
    var previousButton: NSButton?
    var nextButton: NSButton?
    var stripPanStartOffset: CGFloat = 0
    var timer: Timer?
    var presented = false
    var fetching = false
    var states: [AgentState] = []
    var connected = false
    var identifiers: [String] = []
    var statusItem: NSStatusItem?
    var alwaysMenuItem: NSMenuItem?
    var followMenuItem: NSMenuItem?
    var doneBlinkTimers: [String: Timer] = [:]
    var doneBlinkUpdates: [String: Double] = [:]
    let codexIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "codex", withExtension: "svg"), let icon = NSImage(contentsOf: url) else { return nil }
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = true
        return icon
    }()
    let claudeIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "claude", withExtension: "svg"), let icon = NSImage(contentsOf: url) else { return nil }
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = false
        return icon
    }()
    let cmuxIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = false
        return icon
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBarItem()
        bar.delegate = self
        bar.defaultItemIdentifiers = []
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activation), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reloadSettings), name: settingsChanged, object: nil)
        reloadSettings()
        refresh()
    }
    @objc func showCmux() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/cmux.app"))
    }
    func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = cmuxIcon
            button.image?.size = NSSize(width: 16, height: 16)
            button.toolTip = "cmux Touch Bar"
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open cmux", action: #selector(showCmux), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let always = NSMenuItem(title: "Always show Touch Bar", action: #selector(setAlways), keyEquivalent: "")
        always.target = self
        menu.addItem(always)
        let follow = NSMenuItem(title: "Follow cmux", action: #selector(setFollow), keyEquivalent: "")
        follow.target = self
        menu.addItem(follow)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit cmux Touch Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        alwaysMenuItem = always
        followMenuItem = follow
    }
    @objc func setAlways() { preferences.set(true, forKey: "alwaysShow"); reloadSettings() }
    @objc func setFollow() { preferences.set(false, forKey: "alwaysShow"); reloadSettings() }
    @objc func reloadSettings() {
        let alwaysShow = preferences.bool(forKey: "alwaysShow")
        updateDisplayModeMenu(alwaysShow: alwaysShow, alwaysItem: alwaysMenuItem, followItem: followMenuItem)
        statusItem?.button?.toolTip = alwaysShow ? "cmux Touch Bar · Always" : "cmux Touch Bar · Follow cmux"
        activation()
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func wake() { presented = false; activation(); refresh() }
    @objc func activation() {
        let cmuxActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app"
        let active = shouldPresent(always: preferences.bool(forKey: "alwaysShow"),
            cmuxActive: cmuxActive,
            hasSessions: !states.isEmpty && connected)
        if active && !presented { presented = ShowAgentBar(bar) }
        if !active && presented { HideAgentBar(bar); presented = false }
        writeStatus()
    }
    func applicationWillTerminate(_ notification: Notification) {
        doneBlinkTimers.values.forEach { $0.invalidate() }
        HideAgentBar(bar)
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        guard identifier.rawValue == stripIdentifier else { return item }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = stripCardSpacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: stripCardInset, bottom: 0, right: stripCardInset)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleStripPan(_:)))
        pan.allowedTouchTypes = .direct
        scroll.addGestureRecognizer(pan)

        let previous = NSButton(title: "‹", target: self, action: #selector(scrollStrip(_:)))
        previous.identifier = NSUserInterfaceItemIdentifier("previous")
        previous.font = .systemFont(ofSize: 18, weight: .medium)
        previous.toolTip = "Scroll to earlier agent tabs"
        previous.translatesAutoresizingMaskIntoConstraints = false
        let next = NSButton(title: "›", target: self, action: #selector(scrollStrip(_:)))
        next.identifier = NSUserInterfaceItemIdentifier("next")
        next.font = .systemFont(ofSize: 18, weight: .medium)
        next.toolTip = "Scroll to more agent tabs"
        next.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [previous, scroll, next])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = stripControlSpacing
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)
        scroll.widthAnchor.constraint(equalToConstant: stripViewportWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: stripItemHeight).isActive = true
        previous.widthAnchor.constraint(equalToConstant: stripControlWidth).isActive = true
        next.widthAnchor.constraint(equalToConstant: stripControlWidth).isActive = true
        container.widthAnchor.constraint(equalToConstant: stripContainerWidth).isActive = true
        container.heightAnchor.constraint(equalToConstant: stripItemHeight).isActive = true

        item.view = container
        stripStack = stack
        stripScrollView = scroll
        previousButton = previous
        nextButton = next
        updateButtons()
        return item
    }
    @objc func activateCmux(_ sender: NSButton) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first {
            app.activate(options: [])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/cmux.app"))
        }
        let surface = sender.identifier?.rawValue ?? ""
        guard !surface.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
            task.arguments = ["focus-panel", "--panel", surface]
            task.environment = ProcessInfo.processInfo.environment.merging([
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                "CMUX_SOCKET_MODE": "automation"
            ]) { _, newer in newer }
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
    }
    func refresh() {
        activation()
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let (connected, states) = liveStates()
            DispatchQueue.main.async {
                self.fetching = false
                self.applyLiveStateSnapshot(connected, states)
            }
        }
    }
    func applyLiveStateSnapshot(_ connected: Bool, _ states: [AgentState]) {
        guard connected else { return }
        self.connected = true
        self.states = states
        rebuildItems()
    }
    func rebuildItems() {
        let newIdentifiers = [stripIdentifier]
        if newIdentifiers != identifiers {
            if presented { HideAgentBar(bar); presented = false }
            identifiers = newIdentifiers
            items.removeAll()
            stripStack = nil
            stripScrollView = nil
            previousButton = nil
            nextButton = nil
            bar = NSTouchBar()
            bar.delegate = self
            bar.defaultItemIdentifiers = identifiers.map { NSTouchBarItem.Identifier($0) }
        }
        updateButtons()
        activation()
    }
    func updateButtons() {
        guard let stack = stripStack, let scroll = stripScrollView else { return }
        let oldOffset = scroll.contentView.bounds.origin.x
        let titledStates = sessionTitles(states)
        let liveSurfaces = Set(titledStates.map { $0.0.surface })
        for surface in Array(items.keys) where !liveSurfaces.contains(surface) {
            if let button = items.removeValue(forKey: surface) {
                stack.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            doneBlinkTimers[surface]?.invalidate()
            doneBlinkTimers.removeValue(forKey: surface)
            doneBlinkUpdates.removeValue(forKey: surface)
        }
        for (record, title) in titledStates {
            let button: NSButton
            if let existing = items[record.surface] {
                button = existing
            } else {
                button = NSButton(title: title, target: self, action: #selector(activateCmux(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(record.surface)
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.bezelStyle = .rounded
                button.wantsLayer = true
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: statusCardWidth).isActive = true
                button.heightAnchor.constraint(equalToConstant: stripItemHeight).isActive = true
                if let layer = button.layer { configureStatusCardLayer(layer, forHeight: button.bounds.height) }
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                stack.addArrangedSubview(button)
                items[record.surface] = button
            }
            button.title = title
            button.image = record.agent == "codex" ? codexIcon : (record.agent == "claude" ? claudeIcon : nil)
            button.imagePosition = .imageLeading
            button.bezelColor = ["needsInput": NSColor.systemOrange, "running": .systemBlue, "idle": .darkGray, "done": .systemGreen][record.state] ?? .darkGray
            if record.state == "done" {
                if doneBlinkUpdates[record.surface] != record.updated {
                    startDoneBlink(for: record.surface, button: button, updated: record.updated)
                }
            } else {
                doneBlinkTimers[record.surface]?.invalidate()
                doneBlinkTimers.removeValue(forKey: record.surface)
                doneBlinkUpdates.removeValue(forKey: record.surface)
                button.alphaValue = 1
            }
        }
        stack.layoutSubtreeIfNeeded()
        for button in items.values {
            if let layer = button.layer { configureStatusCardLayer(layer, forHeight: button.bounds.height) }
        }
        let fitting = stack.fittingSize
        let viewportWidth = scroll.contentView.bounds.width > 0 ? scroll.contentView.bounds.width : stripViewportWidth
        let contentWidth = max(fitting.width, viewportWidth)
        stack.setFrameSize(NSSize(width: contentWidth, height: stripItemHeight))
        let offset = alignedCardOffset(oldOffset, contentWidth: contentWidth, viewportWidth: viewportWidth, cardStride: stripCardStride)
        scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateScrollControls()
    }
    @objc func scrollStrip(_ sender: NSButton) {
        guard let scroll = stripScrollView else { return }
        let viewportWidth = scroll.contentView.bounds.width
        let direction: CGFloat = sender.identifier?.rawValue == "next" ? 1 : -1
        let offset = alignedCardOffset(scroll.contentView.bounds.origin.x + direction * viewportWidth * 0.8,
            contentWidth: stripStack?.frame.width ?? 0, viewportWidth: viewportWidth, cardStride: stripCardStride)
        scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateScrollControls()
    }
    @objc func handleStripPan(_ recognizer: NSPanGestureRecognizer) {
        guard let scroll = stripScrollView else { return }
        switch recognizer.state {
        case .began:
            stripPanStartOffset = scroll.contentView.bounds.origin.x
        case .changed:
            let translation = recognizer.translation(in: scroll).x
            let maxOffset = max(0, (stripStack?.frame.width ?? 0) - scroll.contentView.bounds.width)
            let offset = min(max(0, stripPanStartOffset - translation), maxOffset)
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            updateScrollControls()
        case .ended, .cancelled, .failed:
            let viewportWidth = scroll.contentView.bounds.width
            let offset = alignedCardOffset(scroll.contentView.bounds.origin.x,
                contentWidth: stripStack?.frame.width ?? 0, viewportWidth: viewportWidth, cardStride: stripCardStride)
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            updateScrollControls()
        default:
            break
        }
    }
    func updateScrollControls() {
        guard let scroll = stripScrollView else { return }
        let offset = scroll.contentView.bounds.origin.x
        let maxOffset = maxAlignedCardOffset(contentWidth: stripStack?.frame.width ?? 0,
            viewportWidth: scroll.contentView.bounds.width, cardStride: stripCardStride)
        previousButton?.isEnabled = offset > 1
        nextButton?.isEnabled = offset < maxOffset - 1
    }
    func startDoneBlink(for surface: String, button: NSButton, updated: Double) {
        doneBlinkTimers[surface]?.invalidate()
        doneBlinkUpdates[surface] = updated
        button.alphaValue = 1
        var frame = 0
        let totalFrames = 90 // Three smooth breathing cycles at 60 fps.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak button] timer in
            guard let button else { timer.invalidate(); return }
            frame += 1
            if frame >= totalFrames {
                timer.invalidate()
                button.alphaValue = 1
                self?.doneBlinkTimers.removeValue(forKey: surface)
            } else {
                let angle = Double(frame) / Double(totalFrames) * Double.pi * 6
                button.alphaValue = 0.30 + 0.70 * (0.5 + 0.5 * cos(angle))
            }
        }
        doneBlinkTimers[surface] = timer
    }
    func writeStatus() {
        let status: [String: Any] = ["connected": connected, "presented": presented, "alwaysShow": preferences.bool(forKey: "alwaysShow"),
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "buttons": items.mapValues { $0.title }, "updated": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}

// Value: protects=query failures retain cards, successful empty snapshots clear them, and invalid or expired events are rejected; fails_when=snapshot semantics or surface filters change; why_new=prior checks lacked visible retention, recovery, malformed JSON and expiry boundary; seam=liveSurfaceQuery (non-test callers: 2, via rg -n 'liveStates\\(' main.swift); no_claim=cmux socket failures and physical Touch Bar presentation remain manual
if CommandLine.arguments.contains("--self-test") {
    assert(statusCardCornerRadius(forHeight: 28) == 10, "Status-card radius must stay below a full pill at the strip height")
    assert(abs(statusCardCornerRadius(forHeight: 20) - 8) < 0.001, "Status-card radius must scale with button height")
    assert(maxAlignedCardOffset(contentWidth: 848, viewportWidth: 680, cardStride: 168) == 168,
        "A five-card strip must scroll by complete-card offsets")
    assert(alignedCardOffset(544, contentWidth: 1_344, viewportWidth: 680, cardStride: 168) == 504,
        "A partial swipe must snap to the nearest card boundary")
    assert(alignedCardOffset(600, contentWidth: 1_344, viewportWidth: 680, cardStride: 168) == 504,
        "The last visible card must remain fully aligned at the end of the strip")
    let alwaysSelection = displayModeSelection(alwaysShow: true)
    assert(alwaysSelection.always && !alwaysSelection.follow,
        "The active Always display mode must have the menu checkmark")
    let followSelection = displayModeSelection(alwaysShow: false)
    assert(!followSelection.always && followSelection.follow,
        "The active Follow cmux display mode must have the menu checkmark")
    func record(_ agent: String, _ surface: String, _ state: String) -> AgentState {
        AgentState(agent: agent, state: state, surface: surface, workspace: "test", updated: 0)
    }
    let statusCardLayer = CALayer()
    configureStatusCardLayer(statusCardLayer, forHeight: 28)
    assert(statusCardLayer.cornerCurve == .continuous, "Status cards must use continuous rounded corners")
    assert(statusCardLayer.masksToBounds, "Status cards must clip to their rounded corners")
    assert(statusCardLayer.cornerRadius == 10, "Full-height status cards must keep rounded-rectangle ends")
    configureStatusCardLayer(statusCardLayer, forHeight: 20)
    assert(statusCardLayer.cornerRadius == 8, "Resized status cards must recalculate their proportional radius")
    let statusCardButton = NSButton(title: "Codex · Idle", target: nil, action: nil)
    statusCardButton.wantsLayer = true
    assert(statusCardButton.layer != nil, "Status buttons must provide the backing layer used for rounded ends")
    if let buttonLayer = statusCardButton.layer {
        configureStatusCardLayer(buttonLayer, forHeight: 28)
        assert(buttonLayer.cornerRadius == 10 && buttonLayer.masksToBounds, "AppKit status buttons must apply the rounded card layer")
    }
    let testProcessTree: [Int32: (Int32, String)] = [42: (1, "codex")]
    let testLiveSurfaces: Set<String> = ["live-surface"]
    let unavailableSnapshot = liveStates(liveSurfaceQuery: { nil })
    assert(!unavailableSnapshot.0 && unavailableSnapshot.1.isEmpty,
        "A failed cmux surface query must be reported as unavailable, not as an empty live tree")
    let queryDelegate = AppDelegate()
    queryDelegate.connected = true
    queryDelegate.states = [record("codex", "live-surface", "running")]
    let queryStack = NSStackView()
    let queryScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 28))
    queryScroll.documentView = queryStack
    queryDelegate.stripStack = queryStack
    queryDelegate.stripScrollView = queryScroll
    queryDelegate.identifiers = [queryDelegate.stripIdentifier]
    let retainedButton = NSButton(title: "Codex · Running", target: nil, action: nil)
    queryStack.addArrangedSubview(retainedButton)
    queryDelegate.items = ["live-surface": retainedButton]
    queryDelegate.applyLiveStateSnapshot(unavailableSnapshot.0, unavailableSnapshot.1)
    assert(queryDelegate.connected && queryDelegate.states.map(\.surface) == ["live-surface"] && queryDelegate.items["live-surface"] === retainedButton && queryStack.arrangedSubviews.contains(retainedButton),
        "A failed cmux surface query must retain the last known status and Touch Bar button")
    queryDelegate.applyLiveStateSnapshot(true, [])
    assert(queryDelegate.connected && queryDelegate.states.isEmpty && queryDelegate.items.isEmpty && !queryStack.arrangedSubviews.contains(retainedButton) && retainedButton.superview == nil,
        "A successful empty cmux snapshot must remove the now-closed status button")
    let uiDelegate = AppDelegate()
    let uiStack = NSStackView()
    uiStack.orientation = .horizontal
    let uiScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 28))
    uiScroll.documentView = uiStack
    uiDelegate.stripStack = uiStack
    uiDelegate.stripScrollView = uiScroll
    let liveButton = NSButton(title: "Codex · Idle", target: nil, action: nil)
    let closedButton = NSButton(title: "Codex · Running", target: nil, action: nil)
    uiStack.addArrangedSubview(liveButton)
    uiStack.addArrangedSubview(closedButton)
    uiDelegate.items = ["live-surface": liveButton, "closed-surface": closedButton]
    uiDelegate.states = [AgentState(agent: "codex", state: "idle", surface: "live-surface", workspace: "test", updated: 1)]
    uiDelegate.updateButtons()
    assert(uiDelegate.items["live-surface"] === liveButton && uiStack.arrangedSubviews.contains(liveButton),
        "Refreshing after a tab closes must retain the still-open tab button")
    assert(uiDelegate.items["closed-surface"] == nil && !uiStack.arrangedSubviews.contains(closedButton) && closedButton.superview == nil,
        "Refreshing after a tab closes must remove its stale Touch Bar button")
    // Value: protects=new cards use documented 160x28 dimensions across agent states; fails_when=constraints drift or differ by state; why_new=prior UI test used only preexisting buttons; seam=none; no_claim=physical Touch Bar rendering
    let sizeDelegate = AppDelegate()
    let sizeStack = NSStackView()
    sizeStack.orientation = .horizontal
    sizeStack.spacing = sizeDelegate.stripCardSpacing
    sizeStack.edgeInsets = NSEdgeInsets(top: 0, left: sizeDelegate.stripCardInset, bottom: 0, right: sizeDelegate.stripCardInset)
    let sizeScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sizeDelegate.stripViewportWidth, height: 28))
    sizeScroll.documentView = sizeStack
    sizeDelegate.stripStack = sizeStack
    sizeDelegate.stripScrollView = sizeScroll
    sizeDelegate.states = [
        AgentState(agent: "codex", state: "idle", surface: "size-codex-idle", workspace: "test", updated: 1),
        AgentState(agent: "codex", state: "running", surface: "size-codex-running", workspace: "test", updated: 1),
        AgentState(agent: "claude", state: "needsInput", surface: "size-claude-input", workspace: "test", updated: 1),
        AgentState(agent: "opencode", state: "idle", surface: "size-opencode-idle", workspace: "test", updated: 1)
    ]
    sizeDelegate.updateButtons()
    sizeStack.layoutSubtreeIfNeeded()
    assert(sizeDelegate.stripContainerWidth == 740 && sizeScroll.frame.width == sizeDelegate.stripViewportWidth,
        "The Touch Bar item must preserve its complete control and card viewport widths")
    assert(sizeDelegate.items.count == 4 && sizeDelegate.items.values.allSatisfy { button in
        !button.translatesAutoresizingMaskIntoConstraints &&
        button.constraints.contains { $0.isActive && $0.firstAttribute == .width && $0.constant == sizeDelegate.statusCardWidth } &&
        button.constraints.contains { $0.isActive && $0.firstAttribute == .height && $0.constant == sizeDelegate.stripItemHeight }
    },
        "Every agent status card must use the same fixed width and height")
    assert(sizeDelegate.items.values.allSatisfy { $0.frame.width == 160 && $0.frame.height == 28 },
        "Laid-out agent status buttons must have identical 160-by-28-point bounds")
    let expectedCardOrigins: [CGFloat] = [8, 176, 344, 512]
    let orderedCardFrames = ["size-codex-idle", "size-codex-running", "size-claude-input", "size-opencode-idle"]
        .compactMap { sizeDelegate.items[$0]?.frame }
    assert(orderedCardFrames.count == 4 && zip(orderedCardFrames, expectedCardOrigins).allSatisfy { abs($0.minX - $1) < 0.1 },
        "Status cards must start at equal card strides so the first card is never clipped by the strip")
    assert(orderedCardFrames.allSatisfy { $0.minX >= 0 && $0.maxX <= sizeScroll.contentView.bounds.width },
        "The visible Touch Bar viewport must not crop any of the four aligned status cards")
    assert(sizeDelegate.statusCardWidth == 160 && sizeDelegate.stripItemHeight == 28,
        "Status cards must keep the documented 160-by-28-point size")
    let testTree = Data(#"{"windows":[{"workspaces":[{"panes":[{"surfaces":[{"id":"LIVE-SURFACE"}]}]}]}]}"#.utf8)
    assert(cmuxSurfaceIDs(from: testTree) == testLiveSurfaces, "The cmux tree parser must collect and normalize live surface UUIDs")
    assert(cmuxSurfaceIDs(from: Data("{}".utf8)) == nil, "A tree without a windows array must be rejected")
    assert(cmuxSurfaceIDs(from: Data("not json".utf8)) == nil, "Malformed cmux tree JSON must be rejected")
    assert(shouldKeepHookSession(["surfaceId": "live-surface", "pid": NSNumber(value: 42)], testLiveSurfaces),
        "An agent on a live cmux surface must keep its status tab visible")
    assert(!shouldKeepHookSession(["surfaceId": "closed-surface", "pid": NSNumber(value: 42), "updatedAt": Date().timeIntervalSince1970], testLiveSurfaces),
        "A cached status must disappear when its cmux surface closes, even if the agent process remains alive")
    assert(shouldKeepHookSession(["surfaceId": "live-surface", "pid": NSNumber(value: 43)], testLiveSurfaces),
        "A stopped agent must remain identifiable while its cmux surface is open")
    assert(agentState("running", processIsLive: false) == "idle", "A missing agent process must not leave a live tab showing Running")
    assert(agentState("needsInput", processIsLive: false) == "idle", "A missing agent process must not leave a live tab showing Input")
    assert(agentState("done", processIsLive: false) == "done", "Completion remains visible for its configured display window")
    assert(agentState("running", processIsLive: nil) == "running", "A temporary process-list failure must not mark an active agent Idle")
    let testEvent = CodexEventState(state: "running", updated: 1_000, surface: "closed-surface", workspace: "test", pid: 42)
    assert(!shouldKeepCodexEvent(testEvent, testLiveSurfaces, now: Date(timeIntervalSince1970: 1_001)),
        "A recent Codex event must not restore a closed surface from the event fallback")
    let liveTestEvent = CodexEventState(state: "running", updated: 1_000, surface: "live-surface", workspace: "test", pid: 42)
    assert(shouldKeepCodexEvent(liveTestEvent, testLiveSurfaces, now: Date(timeIntervalSince1970: 1_001)),
        "A recent Codex event must remain available for a live surface")
    let expiredTestEvent = CodexEventState(state: "running", updated: 1_000, surface: "live-surface", workspace: "test", pid: 42)
    assert(!shouldKeepCodexEvent(expiredTestEvent, testLiveSurfaces, now: Date(timeIntervalSince1970: 1_600)),
        "A Codex event at the ten-minute boundary must not restore a status")
    let stoppedEvent = CodexEventState(state: "running", updated: 1_000, surface: "live-surface", workspace: "test", pid: 43)
    assert(shouldKeepCodexEvent(stoppedEvent, testLiveSurfaces, now: Date(timeIntervalSince1970: 1_001)) && agentState(stoppedEvent.state, processIsLive: hasLiveAgentProcess(stoppedEvent.pid, testProcessTree)) == "idle",
        "A Codex event must retain tab identity but show Idle when its process has exited")
    var lifecycle = CodexLifecycle()
    func event(_ type: String, _ turn: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": type, "turn_id": turn]])
    }
    lifecycle.consume(event("task_complete", "old"))
    assert(lifecycle.state == "done")
    lifecycle.consume(event("task_started", "new"))
    assert(lifecycle.state == "running", "Regression: old Idle must not override a new task")
    lifecycle.consume(event("task_complete", "old"))
    assert(lifecycle.state == "running", "An old turn completing must not stop a newer turn")
    lifecycle.consume(event("task_complete", "new"))
    assert(lifecycle.state == "done")
    assert(lifecycle.currentState(now: Date().addingTimeInterval(9)) == "done")
    assert(lifecycle.currentState(now: Date().addingTimeInterval(11)) == "idle")
    assert(codexHookState("PreToolUse") == "running", "Aside tool hooks must keep Codex Running")
    assert(codexHookState("PostToolUse") == "running", "Aside post-tool hooks must keep Codex Running")
    assert(codexHookState("Stop") == "done", "Stop must keep the completion state")
    lifecycle.consume(event("task_started", "next"))
    lifecycle.consume(event("turn_aborted", "next"))
    assert(lifecycle.state == "done")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let reader = CodexLogReader()
    try! (event("task_complete", "old") + Data([10])).write(to: fixture)
    assert(reader.state(at: fixture.path) == "done")
    let writer = try! FileHandle(forWritingTo: fixture)
    try! writer.seekToEnd()
    try! writer.write(contentsOf: event("task_started", "new"))
    assert(reader.state(at: fixture.path) == "done", "Partial JSON lines must wait for completion")
    try! writer.write(contentsOf: Data([10]))
    assert(reader.state(at: fixture.path) == "running")
    try! writer.close()
    try! Data().write(to: fixture)
    assert(reader.state(at: fixture.path) == "unknown", "Truncated files must reset state")
    try! FileManager.default.removeItem(at: fixture)
    assert(Bundle.main.url(forResource: "codex", withExtension: "svg").flatMap { NSImage(contentsOf: $0) } != nil, "Codex logo must load")
    assert(Bundle.main.url(forResource: "claude", withExtension: "svg").flatMap { NSImage(contentsOf: $0) } != nil, "Claude logo must load")
    assert(sessionTitles([]).isEmpty)
    assert(sessionTitles([record("codex", "a", "running")]).map { $0.1 } == ["Codex · Running"])
    assert(sessionTitles([record("codex", "b", "idle"), record("codex", "a", "needsInput")]).map { $0.1 } == ["Codex 1 · Input", "Codex 2 · Idle"])
    assert(sessionTitles([record("opencode", "c", "running"), record("codex", "a", "idle")]).count == 2)
    assert(sessionTitles([record("claude", "c", "idle"), record("opencode", "o", "running"), record("grok", "g", "needsInput")]).map { $0.1 } == ["Claude · Idle", "Grok · Input", "OpenCode · Running"])
    for always in [false, true] {
        for active in [false, true] {
            assert(shouldPresent(always: always, cmuxActive: active, hasSessions: false) == (always || active))
            assert(shouldPresent(always: always, cmuxActive: active, hasSessions: true) == (always || active))
        }
    }
    print("PASS: closed-tab button removal; status-card button layers; cmux surface parsing and filtering; process-exit status; Codex lifecycle and display modes")
} else if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(usage)
    print("Defaults: display mode follow, max sessions 3")
} else if let index = CommandLine.arguments.firstIndex(of: "--set-display-mode"), CommandLine.arguments.count > index + 1 {
    let mode = CommandLine.arguments[index + 1]
    guard ["always", "follow"].contains(mode) else { fputs("Invalid display mode: \(mode). Use always or follow.\n", stderr); exit(2) }
    preferences.set(mode == "always", forKey: "alwaysShow")
    preferences.synchronize()
    DistributedNotificationCenter.default().postNotificationName(settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
} else if let index = CommandLine.arguments.firstIndex(of: "--set-max-sessions"), CommandLine.arguments.count > index + 1,
          let limit = Int(CommandLine.arguments[index + 1]), limit > 0 {
    preferences.set(limit, forKey: "maxSessions")
    preferences.synchronize()
    DistributedNotificationCenter.default().postNotificationName(settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
} else if CommandLine.arguments.contains("--status") {
    let (connected, states) = liveStates()
    let data = try! JSONEncoder().encode(states)
    print("connected=\(connected)")
    print(String(data: data, encoding: .utf8)!)
} else {
    let unknown = CommandLine.arguments.dropFirst().joined(separator: " ")
    if !unknown.isEmpty { fputs("Unknown argument(s): \(unknown)\n\(usage)\n", stderr); exit(2) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
