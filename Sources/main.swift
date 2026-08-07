import Cocoa
import Darwin
import ServiceManagement

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

// A session row as a custom view so a flexible spacer can pin the timer to the true trailing
// edge (a plain menu-item title can't cross the menu's reserved shortcut/submenu-arrow column).
// Layout: [icon] name  <spacer>  timer.
final class SessionRowView: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    private let pad: CGFloat = 14, iconSize: CGFloat = 16, rowH: CGFloat = 24
    private let highlightView = NSVisualEffectView()  // system selection material = exact native highlight
    private var hovered = false
    private var iconBaseTint: NSColor?       // tint when not hovered (template icons); white on hover
    private var nameText = "", branchText = ""

    init(id: String, width: CGFloat) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        iconView.frame = NSRect(x: pad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.frame = iconView.frame
        spinner.autoresizingMask = [.maxXMargin]
        spinner.isHidden = true
        addSubview(spinner)
        nameField.font = .menuFont(ofSize: 0)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: pad + iconSize + 8, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2, weight: .regular)
        timerField.textColor = .secondaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon: NSImage?, iconTint: NSColor?, spinning: Bool, name: String, branch: String, timer: String?,
                   trailingInset: CGFloat, timerGap: CGFloat) {
        let w = bounds.width
        iconView.image = icon
        iconBaseTint = iconTint
        iconView.contentTintColor = hovered ? .white : iconTint
        if spinning {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
        }
        nameText = name; branchText = branch
        renderName()
        let trailingEdge = w - trailingInset
        if let timer = timer {
            timerField.isHidden = false
            timerField.stringValue = timer
            // Fit the column to the text (mono font, right edge anchored at the pill): a fixed-width
            // column reserved ~50pt of blank space that pixel-truncated the name · branch next to it.
            let font = timerField.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let tw = ceil(timer.size(withAttributes: [.font: font]).width) + 2
            // The timer font is 2pt smaller than the name font; equal-height boxes at the same y center
            // the text, which leaves the smaller font's baseline higher and the digits visibly floating
            // next to the name. Offset the frame so the two baselines coincide.
            let nf = nameField.font ?? NSFont.menuFont(ofSize: 0)
            let baseline = { (f: NSFont) in (16 - (f.ascender - f.descender)) / 2 - f.descender }
            let dy = baseline(nf) - baseline(font)
            timerField.frame = NSRect(x: trailingEdge - tw, y: (rowH - 16) / 2 + dy, width: tw, height: 16)
        } else { timerField.isHidden = true }
        // Name stretches to whatever the timer leaves free (branch text made the fixed 160 tight);
        // pixel truncation via the paragraph style handles overflow.
        let nameRight = timer != nil ? timerField.frame.minX : trailingEdge
        nameField.frame.size.width = max(40, nameRight - timerGap - nameField.frame.minX)
    }
    // name in the label color, " · branch" dimmed — mirrored on hover, where setting textColor
    // can't restyle an attributed string.
    private func renderName() {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Barely-overflowing text otherwise gets its tracking silently condensed to fit ("default
        // tightening"), so the same name renders visibly squished on a row whose timer narrows the
        // field. Constant tracking on every row; overflow shows an honest ellipsis instead.
        para.allowsDefaultTighteningForTruncation = false
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: nameText, attributes: [
            .font: font, .paragraphStyle: para,
            .foregroundColor: hovered ? NSColor.white : .labelColor,
        ])
        if !branchText.isEmpty {
            text.append(NSAttributedString(string: " · " + branchText, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: hovered ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor,
            ]))
        }
        nameField.attributedStringValue = text
    }
    // Custom views don't get the menu's automatic hover highlight, so draw it ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        hovered = h
        highlightView.isHidden = !h
        renderName()
        timerField.textColor = h ? .white : .secondaryLabelColor
        iconView.contentTintColor = h ? .white : iconBaseTint
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/state.d")
    let codexDesktopBundleID = "com.openai.codex"

    var pollTimer: Timer?
    var stateWatcher: DispatchSourceFileSystemObject?
    var pendingStateRefresh: DispatchWorkItem?
    var terminationObserver: NSObjectProtocol?
    var workspaceObservers: [NSObjectProtocol] = []
    var nextHealthWrite: TimeInterval = 0
    var desktopRunning = false
    let desktopMonitor = DesktopSessionMonitor()
    let remoteMonitor = RemoteSessionMonitor()
    let taskRegistryMonitor = DesktopTaskRegistryMonitor()

    struct Session {
        var id: String, state: String, label: String, project: String
        var cwd: String         // session working directory; "" on pre-upgrade files
        var entrypoint: String  // used to exclude stale state from older CLI-capable builds
        var indexedTitle: Bool
        var threadSource: String
        var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                                // conversation seeds started=false and stays out of the dropdown.
        var startedAt: Double, ts: Double
        var eff: String = ""   // effective state, recomputed once per tick in evaluate()
        var branch: String = ""      // git branch (or short SHA when detached); "" outside a repo
        var displayName: String = "" // project, parent-qualified when two live sessions share a name

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.cwd = o["cwd"] as? String ?? ""
            self.entrypoint = o["surface"] as? String ?? o["entrypoint"] as? String ?? ""
            self.indexedTitle = o["indexedTitle"] as? Bool ?? false
            self.threadSource = o["threadSource"] as? String ?? ""
            self.started = o["started"] as? Bool ?? false
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    var previousState: [String: String] = [:]
    var turnStart: [String: Double] = [:]
    var thinkingWordBySession: [String: String] = [:]
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var renderedDotKey = "unset"
    var renderedTitle = "\u{0}"
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    var showThinkingWords = true
    var showTimer = false
    var soundThreshold: Double = 0.1
    var launchAtLogin = true
    let thinkingWords = [
        "Boondoggling", "Booping", "Bootstrapping", "Brewing", "Burrowing",
        "Calculating", "Churning", "Coalescing", "Cogitating", "Combobulating",
        "Composing", "Computing", "Cooking", "Crafting", "Creating", "Crunching",
        "Crystallizing", "Cultivating", "Deciphering", "Percolating", "Perusing",
        "Pollinating", "Pondering", "Pontificating", "Ruminating", "Scampering",
        "Schlepping", "Synthesizing", "Tempering", "Thinking", "Tinkering",
        "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting"
    ]
    lazy var completionSound: NSSound? = {
        guard let path = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        sound.volume = 0.7
        return sound
    }()

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "showThinkingWords") != nil { showThinkingWords = d.bool(forKey: "showThinkingWords") }
        if d.object(forKey: "soundThreshold") != nil { soundThreshold = d.double(forKey: "soundThreshold") }
        if d.object(forKey: "launchAtLogin") != nil { launchAtLogin = d.bool(forKey: "launchAtLogin") }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", labelStartedAt: 0)
        observeCodexDesktop()
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        startStateWatcher()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.remoteMonitor.stop()
            self.pendingStateRefresh?.cancel()
            self.stateWatcher?.cancel()
            for observer in self.workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            self.workspaceObservers.removeAll()
        }
        tick()
        syncLaunchAtLogin()
    }

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: menu

    // The poll timer runs in .common mode, so it keeps firing while the menu tracks; we use that
    // to live-update the per-session elapsed clocks. menuNeedsUpdate rebuilds the rows on each open.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sessionMenuItems.removeAll()
    }

    // The session SET only changes on reopen (NSMenu can't add/remove rows reliably mid-track).
    func refreshOpenMenuRows() {
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            configureSessionRow(v, s, eff: eff)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sessionMenuItems.removeAll()
        let now = Date().timeIntervalSince1970
        // A task appears only after real activity. Keep every active task, followed by at most five
        // tasks completed in the last 15 minutes. Opened-but-never-run conversations never appear.
        let eligible = sessions.values.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            return (s.threadSource == "user" || s.threadSource == "registry") && s.indexedTitle
                && (s.started || eff == "permission" || StatusPolicy.isWorking(eff))
        }
        let active = eligible.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            return eff == "permission" || StatusPolicy.isWorking(eff)
        }.sorted { $0.ts > $1.ts }
        let recent = eligible.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            return eff != "permission" && !StatusPolicy.isWorking(eff)
                && now - s.ts <= StatusPolicy.recentSessionRetention
        }.sorted { $0.ts > $1.ts }.prefix(StatusPolicy.maximumRecentSessions)
        if !active.isEmpty {
            menu.addItem(header("Active tasks"))
            addSessionRows(active, to: menu, now: now)
        }
        if !recent.isEmpty {
            menu.addItem(header("Recently completed"))
            addSessionRows(Array(recent), to: menu, now: now)
        }

        if !active.isEmpty || !recent.isEmpty {
            menu.addItem(.separator())
        } else if desktopRunning {
            menu.addItem(header("Codex"))
            let open = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))
        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Thinking words", isOn: showThinkingWords) { [weak self] on in
            self?.showThinkingWords = on
            UserDefaults.standard.set(on, forKey: "showThinkingWords")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Launch at login", isOn: launchAtLogin) { [weak self] on in
            self?.setLaunchAtLogin(on)
        })
        let soundItem = NSMenuItem(title: "Completion Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for (seconds, title) in [(0.0, "Off"), (0.1, "Every turn"), (60.0, "1 min+"), (300.0, "5 min+"), (900.0, "15 min+")] {
            let item = NSMenuItem(title: title, action: #selector(chooseSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            item.state = soundThreshold == seconds ? .on : .off
            soundMenu.addItem(item)
        }
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func addSessionRows(_ rows: [Session], to menu: NSMenu, now: TimeInterval) {
        for s in rows {
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let view = SessionRowView(id: s.id, width: CGFloat(uiConfig()["boxWidth"] ?? 300))
            view.onClick = { [weak self] in menu.cancelTracking(); self?.openCodex() }
            configureSessionRow(view, s, eff: eff)
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            sessionMenuItems.append((item, s.id))
        }
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, qualifier: String? = nil, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        let labelFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        // Optional trailing qualifier ("5 min+") pinned just left of the toggle, in the SAME font/size/color
        // and right-alignment as the session-row timer, so the two read as the same kind of trailing note.
        if let qualifier = qualifier {
            let qW: CGFloat = 74, gap: CGFloat = 8
            let q = NSTextField(labelWithString: qualifier)
            q.font = NSFont.monospacedSystemFont(ofSize: labelFont.pointSize - 2, weight: .regular)
            q.textColor = .secondaryLabelColor
            q.alignment = .right
            q.frame = NSRect(x: toggleX - gap - qW, y: (height - 16) / 2, width: qW, height: 16)
            q.autoresizingMask = [.minXMargin]
            row.addSubview(q)
        }

        let item = NSMenuItem()
        item.view = row
        return item
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff  // cached by evaluate() each tick
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed.
        var line = truncated(sessionName(s))
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if StatusPolicy.shouldShowSessionTimer(showTimer: showTimer, state: eff, startedAt: s.startedAt) {
            line += "  " + elapsed(max(0, Int(now - s.startedAt)))
        }
        return line
    }

    // Live layout knobs read fresh from ~/.codex/statusbar/uiconfig.json each render, so numeric
    // tweaks (timer column, pill offset, gap) take effect on the next menu open with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        // Generous cap: the row's pixel truncation does the real limiting now that the name field
        // sizes to the free space; this only guards against pathological strings.
        let nameMax = Int(cfg["nameMax"] ?? 30)
        let showSessionTimer = StatusPolicy.shouldShowSessionTimer(
            showTimer: showTimer, state: eff, startedAt: s.startedAt
        )
        let resting = !(eff == "permission" || StatusPolicy.isWorking(eff))  // the dim caret
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    spinning: StatusPolicy.isWorking(eff),
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    branch: truncated(s.branch, max: 22, keep: 20),
                    timer: showSessionTimer ? elapsed(max(0, Int(now - s.startedAt))) : nil,
                    trailingInset: 12,
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
        // Truncated rows stay inspectable: full name, branch, and path on hover.
        var tip = sessionName(s)
        if !s.branch.isEmpty { tip += " · " + s.branch }
        if !s.cwd.isEmpty { tip += "\n" + s.cwd }
        v.toolTip = tip
    }

    func statusText(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission":       return "Awaiting permission"
        case "thinking", "tool", "subagent": return (thinkingWordBySession[s.id] ?? "Thinking") + "…"
        default:                 return s.state == "done" ? "Done" : "Idle"
        }
    }

    func sessionName(_ s: Session) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        return s.project.isEmpty ? "session" : s.project
    }

    func sessionSymbol(_ s: Session, eff: String) -> NSImage? {
        switch eff {
        case "permission":       return symbolImage("exclamationmark.circle.fill", tint: amber)
        case "thinking", "tool", "subagent": return nil
        default:                 return restingCaret   // done/idle merged: dim "ready for input" caret
        }
    }

    // The shell-style prompt caret (U+276F) is dimmed and centered in
    // a square that matches the spinner gutter so the resting rows align with the working ones.
    lazy var restingCaret: NSImage? = {
        let glyph = "\u{276F}" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let side: CGFloat = 15
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let g = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (side - g.width) / 2, y: (side - g.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true   // tint via contentTintColor: dim (tertiary) normally, white on hover
        return img
    }()

    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        s.count > max ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / subagent / idle (done collapses to idle).
    func priority(of eff: String) -> Int {
        StatusPolicy.priority(of: eff)
    }

    // Compact elapsed time: "1m 1s" / "43s".
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func chooseSound(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        soundThreshold = number.doubleValue
        UserDefaults.standard.set(soundThreshold, forKey: "soundThreshold")
    }

    @objc func openCodex() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: state polling

    func tick() {
        desktopMonitor.poll()
        remoteMonitor.poll(enabled: desktopRunning)
        taskRegistryMonitor.poll(enabled: desktopRunning)
        refreshSessionState()
        writeRuntimeHealth()
    }

    func refreshSessionState() {
        reloadSessions()
        evaluate()
        if menuIsOpen { refreshOpenMenuRows() }
    }

    // State producers write atomically into state.d. Observe those writes so the visible status
    // updates promptly without scanning the directory five times per second while nothing changes.
    func startStateWatcher() {
        guard stateWatcher == nil else { return }
        let descriptor = Darwin.open(stateDir, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            guard let self, let watcher = self.stateWatcher else { return }
            let events = watcher.data
            if events.contains(.delete) || events.contains(.rename) {
                watcher.cancel()
                self.stateWatcher = nil
                try? FileManager.default.createDirectory(atPath: self.stateDir, withIntermediateDirectories: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startStateWatcher()
                }
            }
            self.scheduleStateRefresh()
        }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        watcher.resume()
        stateWatcher = watcher
    }

    func scheduleStateRefresh() {
        pendingStateRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            self?.pendingStateRefresh = nil
            self?.refreshSessionState()
        }
        pendingStateRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: refresh)
    }

    // A menu-only app has no ordinary window for external UI automation to inspect. Publish a
    // small, non-sensitive heartbeat so diagnostics can distinguish a live, visible NSStatusItem
    // from a stray process that never finished creating its menu-bar surface.
    func writeRuntimeHealth(now: TimeInterval = Date().timeIntervalSince1970) {
        guard now >= nextHealthWrite else { return }
        nextHealthWrite = now + 5
        let health: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "version": currentVersion,
            "updatedAt": now,
            "statusItemVisible": statusItem.isVisible,
            "buttonAvailable": statusItem.button != nil,
            "menuAttached": statusItem.menu != nil,
            "codexDesktopRunning": desktopRunning,
            // syncLaunchAtLogin and the toggle already reconcile SMAppService. Avoid another XPC
            // round trip every heartbeat merely to serialize the same status.
            "loginItemStatus": launchAtLogin ? "enabled" : "disabled",
        ]
        let root = (stateDir as NSString).deletingLastPathComponent
        guard let data = try? JSONSerialization.data(withJSONObject: health, options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent("runtime.json"))
        try? data.write(to: url, options: .atomic)
    }

    // The .json session files currently in state.d/ (ignores the .tmp files mid-write).
    func stateFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasSuffix(".json") }
    }

    // Refresh `sessions` from state.d/, re-parsing only files whose mtime changed (writes are
    // atomic renames, so a content update bumps mtime and is never read torn).
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if fileMTimes[f] == m { continue }
            fileMTimes[f] = m
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (f as NSString).deletingPathExtension
            let s = Session(json: o, id: id)
            if s.entrypoint == "codex-desktop" {
                sessions[id] = s
            } else {
                sessions[id] = nil
            }
        }
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        var shouldChime = false

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            s.eff = effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            let desktopExpired = s.eff == "idle"
                && now - s.ts > StatusPolicy.recentSessionRetention
            if desktopExpired {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; previousState[id] = nil
                turnStart[id] = nil; thinkingWordBySession[id] = nil
                continue
            }
            sessions[id] = s
            let prior = previousState[id] ?? ""
            if StatusPolicy.isWorking(s.state), s.startedAt > 0 {
                turnStart[id] = s.startedAt
                if !StatusPolicy.isWorking(prior) {
                    thinkingWordBySession[id] = thinkingWords.randomElement() ?? "Thinking"
                }
            }
            if soundThreshold > 0, s.state == "done", prior != "done" {
                if let started = turnStart[id], started > 0, now - started >= soundThreshold {
                    shouldChime = true
                }
            }
            if s.state == "done" { turnStart[id] = 0 }
            previousState[id] = s.state
        }
        for id in Array(previousState.keys) where sessions[id] == nil {
            previousState[id] = nil; turnStart[id] = nil; thinkingWordBySession[id] = nil
        }
        if shouldChime { completionSound?.play() }

        // Same-named projects (two clones/worktrees of one repo) get a parent-folder qualifier
        // ("work/myrepo" vs "tmp/myrepo") so their rows stay tellable apart. Runs after the reap so
        // dead sessions can't force a qualifier onto a now-unique name.
        // Only non-empty cwds count as colliding locations: a pre-upgrade/warmup file without cwd is
        // location-unknown, and counting its "" as a distinct place forced a bogus qualifier onto a
        // genuinely unique row.
        var cwdsByProject: [String: Set<String>] = [:]
        for s in sessions.values where !s.project.isEmpty && !s.cwd.isEmpty { cwdsByProject[s.project, default: []].insert(s.cwd) }
        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            if !s.cwd.isEmpty, (cwdsByProject[s.project]?.count ?? 0) > 1 {
                let parent = (((s.cwd as NSString).deletingLastPathComponent) as NSString).lastPathComponent
                s.displayName = parent.isEmpty ? s.project : parent + "/" + s.project
            } else {
                s.displayName = s.project
            }
            sessions[id] = s
        }

        // Surface the single highest-priority session (permission > working > …); ties broken by
        // recency, so within a tier the most recently active session wins.
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // names repo + surface + state on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), labelStartedAt: 0, dotColor: amber)
        case "thinking", "tool", "subagent":
            render(label: statusText(lead, eff: lead.eff), labelStartedAt: lead.startedAt)
        case "done":
            render(label: statusText(lead, eff: lead.eff), labelStartedAt: 0)
        default:
            renderResting()
        }
    }

    func renderResting() {
        render(label: "", labelStartedAt: 0)
    }

    // Per-session effective state with an age cap so a missed event cannot animate forever.
    func effectiveState(_ s: Session, now: Double) -> String {
        return StatusPolicy.effectiveState(rawState: s.state, age: max(0, now - s.ts))
    }

    // Query LaunchServices once, then follow workspace lifecycle notifications. The previous tick
    // path enumerated all running apps twice every 200 ms even though Codex's state rarely changes.
    func observeCodexDesktop() {
        desktopRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: codexDesktopBundleID
        ).isEmpty
        let center = NSWorkspace.shared.notificationCenter
        for (name, running) in [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.codexDesktopBundleID else { return }
                self.desktopRunning = running
                if running { self.tick() }
            }
            workspaceObservers.append(observer)
        }
    }

    func syncLaunchAtLogin() {
        setLaunchAtLogin(launchAtLogin, persist: false)
    }

    func setLaunchAtLogin(_ enabled: Bool, persist: Bool = true) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            if persist { UserDefaults.standard.set(enabled, forKey: "launchAtLogin") }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if persist { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
        }
    }

    // MARK: render

    func render(label: String, labelStartedAt: Double, dotColor: NSColor? = nil) {
        guard let button = statusItem.button else { return }
        activeBase = label
        startedAt = labelStartedAt
        let dotKey = dotColor == nil ? "none" : "permission"
        if renderedDotKey != dotKey {
            // The resting mark is a template image, so AppKit automatically matches the
            // other menu-bar icons in both light and dark appearances. Permission state
            // is composited separately so its amber badge can remain colored.
            button.contentTintColor = nil
            button.image = statusIcon(dotColor: dotColor)
            renderedDotKey = dotKey
            if button.image == nil { button.image = fallbackIcon() }
        }
        applyTitle()
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = showThinkingWords ? activeBase : ""
        if showTimer, startedAt > 0 {
            text += "  " + elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt)))
        }
        guard text != renderedTitle else { return }
        renderedTitle = text
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    lazy var fallbackMark: NSImage = {
        return NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Codex")
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }()

    lazy var claudeSparkMark: NSImage? = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:))

    func statusIcon(dotColor: NSColor?) -> NSImage {
        let frame = claudeSparkIcon()
        guard let dotColor else { return frame }
        return dotIcon(base: frame, color: dotColor)
    }

    func claudeSparkIcon() -> NSImage {
        let side: CGFloat = 20
        guard let mask = claudeSparkMark else { return fallbackIcon() }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    func fallbackIcon() -> NSImage {
        let side: CGFloat = 20
        let inset = max(1, side * 0.05)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.fallbackMark.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    func dotIcon(base: NSImage, color: NSColor) -> NSImage {
        let s: CGFloat = 20
        let d = max(4, (s * 0.3).rounded())
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: s - d, y: 0, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
