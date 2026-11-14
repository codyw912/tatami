// tatami-bar: an optional bar for tatami that sits over the macOS menu bar.
//
// Left: an optional logo, the workspaces (click one to switch) and the focused window's
// title. Right: menu-bar apps of your choice, the battery and the clock. Hover anywhere
// but a workspace or an icon for a moment and the bar fades out to show the real menu bar
// underneath; move the mouse away and it comes back. Hidden while the focused window is
// native fullscreen.
//
// It talks to tatami through its control socket, as "tatami <command>" does: "events
// --json" for instant redraws and "query ... --json" for the rest. Configuration is read from
// ~/.config/tatami/bar.conf (see bar/README.md); without one it follows the system
// appearance. "tatami-bar check" validates the file; SIGHUP reloads it. "tatami-bar keys"
// (SIGUSR1) shows or hides the key bindings.
import Cocoa
import IOKit.ps

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: Configuration

enum FontDesign: String { case system, rounded, monospaced, serif }

struct BarConfig {
    var background: NSColor = .windowBackgroundColor
    var foreground: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var accent: NSColor = .controlAccentColor
    var accentText: NSColor = .white
    var hairline: NSColor = .separatorColor
    var batteryColor: NSColor? = nil      // foreground when unset
    var clockColor: NSColor? = nil        // foreground when unset
    var logoColor: NSColor? = nil         // accent when unset
    var fontSize: CGFloat = 12.5
    var design: FontDesign = .system
    var logo = ""
    var clockFormat = "EEE d MMM  HH:mm"
    var battery = true
    var title = true
    var hoverReveal = true
    var tray: [String] = []
    var keysStyle = "symbols"
    var keysColors = false
    var keysCtrlColor: NSColor = .systemBlue
    var keysAltColor: NSColor = .systemGreen
    var keysShiftColor: NSColor = .systemOrange
    var keysCmdColor: NSColor = .systemPurple
    var tatami = ""

    func font(_ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let d: NSFontDescriptor.SystemDesign
        switch design {
        case .system: return base
        case .rounded: d = .rounded
        case .monospaced: d = .monospaced
        case .serif: d = .serif
        }
        guard let desc = base.fontDescriptor.withDesign(d) else { return base }
        return NSFont(descriptor: desc, size: fontSize) ?? base
    }

    static var path: String { NSHomeDirectory() + "/.config/tatami/bar.conf" }

    // Line-based like tatami.conf: "<key> <value>", "#" starts a comment. A line with an
    // error is reported and skipped; the rest of the file still applies.
    static func load() -> (BarConfig, [String]) {
        var c = BarConfig()
        var errors: [String] = []
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (c, []) }
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            // A comment is a line starting with "#", or " # ..." after a value: "#f8f3ea" is a colour.
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if let c = line.range(of: #"\s#(\s|$)"#, options: .regularExpression) { line = String(line[..<c.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let key = parts[0]
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if let e = c.set(key, value) { errors.append("\(path):\(n + 1): \(e)") }
        }
        return (c, errors)
    }

    static func color(_ v: String) -> NSColor?? {
        if v == "system" { return .some(nil) }
        var h = v.hasPrefix("#") ? String(v.dropFirst()) : v
        if h.count == 6 { h += "ff" }
        guard h.count == 8, let n = UInt32(h, radix: 16) else { return nil }
        return .some(NSColor(srgbRed: CGFloat((n >> 24) & 0xff) / 255, green: CGFloat((n >> 16) & 0xff) / 255,
                             blue: CGFloat((n >> 8) & 0xff) / 255, alpha: CGFloat(n & 0xff) / 255))
    }

    static func flag(_ v: String) -> Bool? { ["on": true, "off": false, "yes": true, "no": false, "true": true, "false": false][v] }

    mutating func set(_ key: String, _ v: String) -> String? {
        let defaults = BarConfig()
        func col(_ apply: (NSColor?) -> Void) -> String? {
            guard let c = BarConfig.color(v) else { return "\(key): expected #rrggbb, #rrggbbaa or system, got '\(v)'" }
            apply(c); return nil
        }
        func bool(_ apply: (Bool) -> Void) -> String? {
            guard let b = BarConfig.flag(v) else { return "\(key): expected on or off, got '\(v)'" }
            apply(b); return nil
        }
        switch key {
        case "background": return col { background = $0 ?? defaults.background }
        case "foreground": return col { foreground = $0 ?? defaults.foreground }
        case "muted": return col { muted = $0 ?? defaults.muted }
        case "accent": return col { accent = $0 ?? defaults.accent }
        case "accent-text": return col { accentText = $0 ?? defaults.accentText }
        case "hairline": return col { hairline = $0 ?? defaults.hairline }
        case "battery-color": return col { batteryColor = $0 }
        case "clock-color": return col { clockColor = $0 }
        case "logo-color": return col { logoColor = $0 }
        case "font-size":
            guard let s = Double(v), s >= 8, s <= 24 else { return "font-size: expected a number from 8 to 24, got '\(v)'" }
            fontSize = CGFloat(s)
        case "font":
            guard let d = FontDesign(rawValue: v) else { return "font: expected system, rounded, monospaced or serif, got '\(v)'" }
            design = d
        case "logo": logo = v
        case "clock": clockFormat = v
        case "battery": return bool { battery = $0 }
        case "title": return bool { title = $0 }
        case "hover-reveal": return bool { hoverReveal = $0 }
        case "tray":
            guard !v.isEmpty, !v.contains(" ") else { return "tray: expected one bundle identifier or tailscale, got '\(v)'" }
            tray.append(v)
        case "keys-style":
            guard Keys.styles.contains(v) else { return "keys-style: expected symbols, plus, words or mono, got '\(v)'" }
            keysStyle = v
        case "keys-colors": return bool { keysColors = $0 }
        case "keys-ctrl-color": return col { keysCtrlColor = $0 ?? defaults.keysCtrlColor }
        case "keys-alt-color": return col { keysAltColor = $0 ?? defaults.keysAltColor }
        case "keys-shift-color": return col { keysShiftColor = $0 ?? defaults.keysShiftColor }
        case "keys-cmd-color": return col { keysCmdColor = $0 ?? defaults.keysCmdColor }
        case "tatami": tatami = (v as NSString).expandingTildeInPath
        default: return "unknown key '\(key)'"
        }
        return nil
    }
}

// MARK: Drawing

struct Workspace { let index: Int; let focused: Bool; let label: String }
// A menu-bar app shown in the bar: its icon, an optional status dot and text.
struct TrayItem { let id: String; let icon: NSImage; let dot: NSColor?; let text: String }

final class BarView: NSView {
    var cfg = BarConfig()
    var workspaces: [Workspace] = []
    var title = ""
    var status = ""
    var battery = ""
    var leftLimit: CGFloat = 800
    var boxes: [(NSRect, Int)] = []
    var tray: [TrayItem] = []
    var trayRects: [(NSRect, String)] = []
    var onPick: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onTray: ((String) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    func overBox(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return boxes.first { $0.0.insetBy(dx: -2, dy: -6).contains(p) }?.1
    }
    func overTray(_ event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return trayRects.first { $0.0.insetBy(dx: -4, dy: -6).contains(p) }?.1
    }
    func outside(_ event: NSEvent) -> Bool { overBox(event) == nil && overTray(event) == nil }
    override func mouseEntered(with event: NSEvent) { onHover?(outside(event)) }
    override func mouseMoved(with event: NSEvent) { onHover?(outside(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        if let n = overBox(event) { onPick?(n) } else if let id = overTray(event) { onTray?(id) }
    }

    func midY(_ h: CGFloat) -> CGFloat { ((bounds.height - h) / 2).rounded() }

    override func draw(_ dirty: NSRect) {
        let bold = cfg.font(.bold), text = cfg.font(.medium)
        cfg.background.setFill()
        bounds.fill()
        cfg.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        boxes = []
        let bh: CGFloat = min(bounds.height - 10, 22)
        let by = midY(bh)
        var x: CGFloat = 12
        if !cfg.logo.isEmpty {
            let logo = NSAttributedString(string: cfg.logo, attributes: [.font: bold, .foregroundColor: cfg.logoColor ?? cfg.accent])
            let ls = logo.size()
            logo.draw(at: NSPoint(x: x, y: midY(ls.height)))
            x += ls.width + 12
        }
        for w in workspaces {
            let name = w.label.isEmpty ? "\(w.index)" : "\(w.index):\(w.label)"
            let s = NSAttributedString(string: name, attributes: [
                .font: bold, .foregroundColor: w.focused ? cfg.accentText : cfg.foreground])
            let size = s.size()
            let rect = NSRect(x: x, y: by, width: max(bh + 4, (size.width + 16).rounded()), height: bh)
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            if w.focused {
                cfg.accent.setFill()
                pill.fill()
            } else {
                cfg.muted.setStroke()
                pill.lineWidth = 1.5
                pill.stroke()
            }
            s.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()))
            boxes.append((rect, w.index))
            x = rect.maxX + 5
        }
        x += 12
        if cfg.title {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let t = NSAttributedString(string: title, attributes: [
                .font: text, .foregroundColor: cfg.foreground, .paragraphStyle: para])
            let th = t.size().height
            let maxW = leftLimit - x - 16
            if maxW > 30 {
                t.draw(with: NSRect(x: x, y: midY(th), width: maxW, height: th),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        let r = NSMutableAttributedString()
        if cfg.battery && !battery.isEmpty {
            r.append(NSAttributedString(string: battery, attributes: [.font: text, .foregroundColor: cfg.batteryColor ?? cfg.foreground]))
            if !status.isEmpty { r.append(NSAttributedString(string: "   ·   ", attributes: [.font: text, .foregroundColor: cfg.muted])) }
        }
        r.append(NSAttributedString(string: status, attributes: [.font: bold, .foregroundColor: cfg.clockColor ?? cfg.foreground]))
        let rs = r.size()
        r.draw(at: NSPoint(x: bounds.width - rs.width - 12, y: midY(rs.height)))
        trayRects = []
        var limit = bounds.width - rs.width - 12 - (rs.width > 0 ? 18 : 0)
        for item in tray.reversed() {
            let label = NSAttributedString(string: item.text, attributes: [.font: text, .foregroundColor: cfg.muted])
            let lw = item.text.isEmpty ? 0 : label.size().width + 5
            let dw: CGFloat = item.dot == nil ? 0 : 9
            let w = 16 + dw + lw
            let x0 = limit - w
            let icon = NSRect(x: x0, y: midY(16), width: 16, height: 16)
            item.icon.draw(in: icon)
            if let dot = item.dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: icon.maxX + 3, y: (bounds.height / 2 - 3).rounded(), width: 6, height: 6)).fill()
            }
            if lw > 0 { label.draw(at: NSPoint(x: icon.maxX + dw + 5, y: midY(label.size().height))) }
            trayRects.append((NSRect(x: x0, y: 0, width: w, height: bounds.height), item.id))
            limit = x0 - 14
        }
    }
}

final class ActionItem: NSMenuItem {
    let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { DispatchQueue.global().async { self.run() } }
}

// MARK: Tray

// "tray tailscale" gets its own menu built from the Tailscale CLI, with a status dot and
// the exit node in use. Any other entry is a bundle identifier: its icon, and a click
// presses that app's real menu-bar item (needs the Accessibility permission).
final class Tray {
    static let tailscaleBundles = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
    var icons: [String: NSImage] = [:]
    var tsStatus: [String: Any] = [:]

    lazy var tsCLI: String? = {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func bundle(_ id: String) -> String {
        if id != "tailscale" { return id }
        return Tray.tailscaleBundles.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? Tray.tailscaleBundles[0]
    }

    func icon(_ id: String) -> NSImage {
        let b = bundle(id)
        if let i = icons[b] { return i }
        var i = NSImage(size: NSSize(width: 16, height: 16))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { i = NSWorkspace.shared.icon(forFile: url.path) }
        icons[b] = i
        return i
    }

    func extrasItem(_ bundle: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let b = bar else { return nil }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        return (kids as? [AXUIElement])?.first
    }

    func pressReal(_ bundle: String, then: @escaping () -> Void) {
        if let item = extrasItem(bundle) {
            // Pressing a menu-bar item can block until its menu closes: keep it off the main thread.
            DispatchQueue.global().async {
                _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                DispatchQueue.main.async(execute: then)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func tsRun(_ args: [String]) -> Data {
        guard let cli = tsCLI else { return Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        // The app's binary is the GUI unless told to act as the CLI.
        p.environment = ["TAILSCALE_BE_CLI": "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    // Called off the main thread.
    func tailscaleState(_ cfg: BarConfig) -> (NSColor?, String) {
        guard let d = (try? JSONSerialization.jsonObject(with: tsRun(["status", "--json"]))) as? [String: Any] else {
            tsStatus = [:]
            return (cfg.muted, "")
        }
        tsStatus = d
        let peers = (d["Peer"] as? [String: [String: Any]] ?? [:]).values
        let exit = peers.first { $0["ExitNode"] as? Bool ?? false }?["HostName"] as? String ?? ""
        if d["BackendState"] as? String != "Running" { return (cfg.muted, "off") }
        return (NSColor.systemGreen, exit.isEmpty ? "" : "↗ \(exit)")
    }

    func tailscaleMenu(in view: NSView, at rect: NSRect, refresh: @escaping () -> Void) {
        let d = tsStatus
        let running = d["BackendState"] as? String == "Running"
        let me = d["Self"] as? [String: Any] ?? [:]
        let ip = (me["TailscaleIPs"] as? [String])?.first ?? ""
        let tailnet = (d["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? ""
        let peers = Array((d["Peer"] as? [String: [String: Any]] ?? [:]).values)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: running ? "Connected · \(tailnet)" : "Disconnected", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(ActionItem(running ? "Disconnect" : "Connect") {
            _ = self.tsRun([running ? "down" : "up"]); DispatchQueue.main.async(execute: refresh)
        })
        menu.addItem(.separator())
        if !ip.isEmpty {
            menu.addItem(ActionItem("This device: \(me["HostName"] as? String ?? "") (\(ip))") {
                DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string) }
            })
        }
        let exits = peers.filter { $0["ExitNodeOption"] as? Bool ?? false }
            .sorted { ($0["HostName"] as? String ?? "") < ($1["HostName"] as? String ?? "") }
        let current = peers.first { $0["ExitNode"] as? Bool ?? false }
        let exitMenu = NSMenu()
        exitMenu.autoenablesItems = false
        let none = ActionItem("None") { _ = self.tsRun(["set", "--exit-node="]); DispatchQueue.main.async(execute: refresh) }
        none.state = current == nil ? .on : .off
        exitMenu.addItem(none)
        if !exits.isEmpty { exitMenu.addItem(.separator()) }
        for e in exits {
            let name = e["HostName"] as? String ?? "?"
            let target = (e["TailscaleIPs"] as? [String])?.first ?? name
            let item = ActionItem(name + ((e["Online"] as? Bool ?? false) ? "" : "  (offline)")) {
                _ = self.tsRun(["set", "--exit-node=\(target)"]); DispatchQueue.main.async(execute: refresh)
            }
            item.state = (e["ExitNode"] as? Bool ?? false) ? .on : .off
            exitMenu.addItem(item)
        }
        let exitItem = NSMenuItem(title: "Exit node" + (current.map { ": \($0["HostName"] as? String ?? "")" } ?? ""), action: nil, keyEquivalent: "")
        exitItem.submenu = exitMenu
        menu.addItem(exitItem)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Admin console") { NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/machines")!) })
        menu.addItem(ActionItem("Tailscale's own menu…") { DispatchQueue.main.async { self.pressReal(self.bundle("tailscale"), then: refresh) } })
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: -4), in: view)
    }
}

// MARK: The bar

final class Bar: NSObject, NSApplicationDelegate {
    var cfg = BarConfig()
    var tatami = ""
    var panel: NSPanel!
    var view: BarView!
    let tray = Tray()
    var pending = false
    var hoverHidden = false
    var fullscreenHidden = false
    var hoverTimer: Timer?
    var barHeight: CGFloat = 32
    var screenTop: CGFloat = 0
    var hup: DispatchSourceSignal?
    var usr1: DispatchSourceSignal?
    var keysPanel: KeysPanel?
    var keysPrevious: NSRunningApplication?

    func loadConfig() {
        let (c, errors) = BarConfig.load()
        for e in errors { log(e) }
        cfg = c
        let candidates = [cfg.tatami, NSHomeDirectory() + "/.local/bin/tatami",
                          (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/tatami",
                          "/opt/homebrew/bin/tatami", "/usr/local/bin/tatami"]
        tatami = candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[1]
        view?.cfg = cfg
        view?.needsDisplay = true
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        view = BarView()
        loadConfig()
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = view
        view.onPick = { n in self.show(n); DispatchQueue.global().async { _ = self.ask("workspace \(n)") } }
        view.onHover = { outside in self.hover(outside) }
        view.onTray = { id in self.pressTray(id) }
        layout()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in self.layout() }
        // Light and dark mode: the default colours are the system's dynamic ones.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in self.view.needsDisplay = true }
        signal(SIGHUP, SIG_IGN)
        hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup?.setEventHandler { self.loadConfig(); self.updateStatus(); self.updateTray(); self.refresh() }
        hup?.resume()
        // "tatami-bar keys": show or hide the key bindings.
        signal(SIGUSR1, SIG_IGN)
        usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1?.setEventHandler { self.toggleKeys() }
        usr1?.resume()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, self.keysPanel?.isVisible == true else { return event }  // Esc
            self.closeKeys(restore: true)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in self.closeKeys(restore: false) }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.updateStatus() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.updateTray() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.schedule() }
        updateStatus()
        updateTray()
        refresh()
        Thread { self.follow() }.start()
    }

    func layout() {
        guard let s = NSScreen.screens.first else { return }
        var h = s.frame.maxY - s.visibleFrame.maxY
        if h < 20 { h = 32 }
        barHeight = h
        screenTop = s.frame.maxY
        panel.setFrame(NSRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h), display: true)
        view.leftLimit = s.auxiliaryTopLeftArea?.width ?? s.frame.width * 0.5
        view.needsDisplay = true
    }

    func apply() {
        let hide = hoverHidden || fullscreenHidden
        panel.alphaValue = hide ? 0 : 1
        panel.ignoresMouseEvents = hide
    }

    func hover(_ outside: Bool) {
        guard cfg.hoverReveal else { return }
        if !outside { hoverTimer?.invalidate(); hoverTimer = nil; return }
        if hoverTimer != nil || hoverHidden { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            self.hoverTimer = nil
            self.hoverHidden = true
            self.apply()
        }
    }

    func tick() {
        guard hoverHidden else { return }
        if NSEvent.mouseLocation.y < screenTop - barHeight - 6 {
            hoverHidden = false
            apply()
        }
    }

    func updateTray() {
        let cfg = self.cfg
        DispatchQueue.global().async {
            let ts = cfg.tray.contains("tailscale") ? self.tray.tailscaleState(cfg) : (nil, "")
            DispatchQueue.main.async {
                self.view.tray = cfg.tray.map { id in
                    id == "tailscale" ? TrayItem(id: id, icon: self.tray.icon(id), dot: ts.0, text: ts.1)
                                      : TrayItem(id: id, icon: self.tray.icon(id), dot: nil, text: "")
                }
                self.view.needsDisplay = true
            }
        }
    }

    func pressTray(_ id: String) {
        if id == "tailscale", let r = view.trayRects.first(where: { $0.1 == id })?.0 {
            tray.tailscaleMenu(in: view, at: r) { self.updateTray() }
            return
        }
        tray.pressReal(tray.bundle(id)) { self.updateTray() }
    }

    func battery() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "" }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return "\(charging ? "⚡︎ " : "")\(cap)%"
        }
        return ""
    }

    func updateStatus() {
        let f = DateFormatter()
        f.dateFormat = cfg.clockFormat
        view.battery = battery()
        view.status = cfg.clockFormat.isEmpty ? "" : f.string(from: Date())
        view.needsDisplay = true
    }

    // tatami's control socket, the one "tatami <command>" uses: the request goes out, the
    // reply comes back until the socket closes. A few milliseconds, against tens of
    // milliseconds to start a process, and nothing runs on the main thread.
    static let socketPath = "/tmp/tatami-\(getuid()).sock"

    func connect(_ request: String, follow: Bool) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Bar.socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.prefix(buf.count - 1).enumerated() { buf[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bytes = Array(request.utf8)
        if connected != 0 || write(fd, bytes, bytes.count) != bytes.count { close(fd); return nil }
        if follow {
            var forever = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, tvSize)
        }
        return fd
    }

    func ask(_ request: String) -> Data? {
        guard let fd = connect(request, follow: false) else { return nil }
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        if data.isEmpty || data.starts(with: Array("error".utf8)) { return nil }
        return data
    }

    func json(_ request: String) -> [String: Any]? {
        guard let d = ask(request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // Follows "events --json" on the socket and redraws on every event; reconnects if
    // tatami goes away.
    func follow() {
        while true {
            if let fd = connect("events --json", follow: true) {
                schedule()
                var buffer = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    buffer.append(buf, count: n)
                    var events: [[String: Any]] = []
                    while let nl = buffer.firstIndex(of: 0x0a) {
                        let line = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer = buffer.subdata(in: (nl + 1)..<buffer.endIndex)
                        if let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { events.append(e) }
                    }
                    if events.isEmpty { continue }
                    DispatchQueue.main.async { for e in events { self.handle(e) } }
                    schedule()
                }
                close(fd)
            }
            schedule()
            usleep(500_000)
        }
    }

    // One fetch at a time, off the main thread; events that arrive during a fetch are
    // folded into the next one, so a burst of them costs two fetches, not one each.
    let fetchQueue = DispatchQueue(label: "tatami-bar.fetch", qos: .userInteractive)

    func schedule() {
        DispatchQueue.main.async {
            if self.pending { return }
            self.pending = true
            self.fetchQueue.async {
                DispatchQueue.main.sync { self.pending = false }
                let snapshot = self.fetch()
                DispatchQueue.main.async { self.render(snapshot) }
            }
        }
    }

    func refresh() { schedule() }

    // Draw the new workspace at once from the event itself; the fetch fills in the rest.
    // A focus change is drawn from the windows the last fetch saw, before tatami has
    // finished moving focus and can answer a query.
    func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "workspace_changed":
            if let n = event["workspace"] as? Int { show(n) }
        case "focus_changed":
            guard let id = event["window"] as? Int, let w = known[id] else { return }
            view.title = w.title
            fullscreenHidden = w.fullscreen
            apply()
            view.display()
        default:
            break
        }
    }

    func show(_ n: Int) {
        var list = view.workspaces.map { Workspace(index: $0.index, focused: $0.index == n, label: $0.label) }
        if !list.contains(where: { $0.index == n }) {
            list.append(Workspace(index: n, focused: true, label: ""))
            list.sort { $0.index < $1.index }
        }
        view.workspaces = list
        view.display()
    }

    struct Shown { var title: String; var fullscreen: Bool }
    struct Snapshot { var workspaces: [Workspace]; var title: String; var fullscreen: Bool; var windows: [Int: Shown] }
    var known: [Int: Shown] = [:]

    func fetch() -> Snapshot? {
        guard let ws = json("query workspaces --json")?["workspaces"] as? [[String: Any]] else { return nil }
        let workspaces = ws.map {
            Workspace(index: $0["index"] as? Int ?? 0, focused: $0["focused"] as? Bool ?? false,
                      label: $0["label"] as? String ?? "")
        }.sorted { $0.index < $1.index }
        var title = ""
        var fullscreen = false
        var shown: [Int: Shown] = [:]
        for w in json("query windows --json")?["windows"] as? [[String: Any]] ?? [] {
            let app = w["app"] as? String ?? ""
            let t = w["title"] as? String ?? ""
            let one = Shown(title: t.isEmpty ? app : (t.contains(app) ? t : "\(app) — \(t)"),
                            fullscreen: w["fullscreen"] as? Bool ?? false)
            if let id = w["id"] as? Int { shown[id] = one }
            if w["focused"] as? Bool ?? false { title = one.title; fullscreen = one.fullscreen }
        }
        return Snapshot(workspaces: workspaces, title: title, fullscreen: fullscreen, windows: shown)
    }

    func render(_ snapshot: Snapshot?) {
        guard let s = snapshot else {
            view.workspaces = []
            view.title = "tatami is not running"
            fullscreenHidden = false
            apply()
            view.needsDisplay = true
            return
        }
        known = s.windows
        view.workspaces = s.workspaces
        view.title = s.title
        fullscreenHidden = s.fullscreen
        apply()
        view.display()
    }
}

// MARK: Keys

// "tatami-bar keys" (SIGUSR1 to the running bar) shows every key binding tatami has loaded,
// in a panel in the middle of the screen; Esc, the same command again or a click elsewhere
// closes it. The bindings come from "query bindings --json" on the socket, so the sheet
// matches what is loaded; the sections are the comment above each group of bindings in
// tatami.conf, up to the first " (". keys-style picks how a chord's modifiers are written,
// and keys-colors gives each modifier its own colour.
struct KeyRow { let mods: [String]; let key: String; let text: String; let code: Bool }
struct KeyCard { let title: String; var rows: [KeyRow]; var wide = false }

enum Keys {
    static let styles = ["symbols", "plus", "words", "mono"]
    static let order = ["ctrl", "alt", "shift", "cmd"]
    static let symbols = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
    static let keyNames: [String: String] = [
        "return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "esc": "⎋",
        "backspace": "⌫", "delete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "grave": "`", "backtick": "`", "home": "Home", "end": "End",
        "pageup": "PgUp", "pagedown": "PgDn",
    ]
    // Outside the symbols style, keys that a keyboard without Mac legends names in words.
    static let keyWords: [String: String] = [
        "return": "Return", "enter": "Return", "tab": "Tab", "escape": "Esc", "esc": "Esc",
        "backspace": "Backspace", "delete": "Delete",
    ]
    static let directions = ["west": "left", "east": "right", "north": "up", "south": "down"]
    // A command and what it does; $1 is the first group, $d its direction in words.
    static let meanings: [(String, String)] = [
        ("workspace (\\d+)", "Go to workspace $1"),
        ("workspace recent", "Previous workspace (back and forth)"),
        ("workspace prev", "Previous workspace"),
        ("workspace next", "Next workspace"),
        ("send (\\d+)", "Move window to workspace $1"),
        ("send prev", "Move window to the previous workspace"),
        ("send next", "Move window to the next workspace"),
        ("focus (west|east|north|south)", "Focus $d"),
        ("swap (west|east|north|south)", "Swap window $d"),
        ("warp (west|east|north|south)", "Move window $d"),
        ("focus-monitor next", "Focus next monitor"),
        ("focus-monitor recent", "Focus previous monitor"),
        ("toggle zoom-fullscreen", "Fill the screen (toggle)"),
        ("toggle zoom-parent", "Fill its half of the split (toggle)"),
        ("toggle float", "Float or tile the window"),
        ("toggle accordion", "Stack the workspace's windows (toggle)"),
        ("toggle split", "Flip the split direction"),
        ("resize width -(\\d+)", "Narrower by $1 px"),
        ("resize width (\\d+)", "Wider by $1 px"),
        ("resize height -(\\d+)", "Shorter by $1 px"),
        ("resize height (\\d+)", "Taller by $1 px"),
        ("balance", "Even out every split"),
        ("reload", "Reload tatami.conf"),
        ("retile", "Rebuild the layout"),
        ("exec .*tatami-bar keys.*", "This cheat sheet"),
    ]
    static let commands: [(String, String)] = [
        ("tatami reload", "Read tatami.conf again"),
        ("tatami query windows", "Every window, its workspace and mode"),
        ("tatami query bindings", "Every key binding, as loaded"),
        ("tatami quit", "Bring parked windows back and stop"),
        ("tatami rescue", "Bring parked windows back without a running tatami"),
        ("tatami help", "Every command"),
        ("pkill -HUP tatami-bar", "Reload bar.conf"),
    ]

    static var configPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        return base + "/tatami/tatami.conf"
    }

    // "ctrl-alt-shift-h": the modifiers in ctrl, alt, shift, cmd order, and the key's name.
    static func chord(_ s: String, style: String) -> ([String], String) {
        var parts = s.split(separator: "-").map(String.init)
        let key = parts.popLast() ?? ""
        let mods = parts.map { $0 == "option" ? "alt" : $0 }
            .sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
        var name = keyNames[key] ?? (key.count == 1 ? key.uppercased() : key)
        if style != "symbols", let word = keyWords[key] { name = word }
        return (mods, name)
    }

    static func meaning(_ command: String) -> String? {
        for (pattern, text) in meanings {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { continue }
            var out = text
            if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: command) {
                let group = String(command[r])
                out = out.replacingOccurrences(of: "$1", with: group)
                out = out.replacingOccurrences(of: "$d", with: directions[group] ?? group)
            }
            return out
        }
        return nil
    }

    // The title of the comment line that opens each group of bindings, by chord.
    static func sections(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        var title = "Other"
        var blank = true
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { blank = true; continue }
            if line.hasPrefix("#") {
                if blank {
                    let body = line.drop { $0 == "#" || $0 == " " }
                    title = String(body.components(separatedBy: " (")[0])
                }
                blank = false
                continue
            }
            blank = false
            let words = line.split(separator: " ").map(String.init)
            guard words.first == "bind", words.count > 2 else { continue }
            let chord = words[1].hasPrefix("mode:") ? words[2] : words[1]
            found[chord] = title
        }
        return found
    }

    static func cards(_ bindings: [[String: Any]], style: String) -> [KeyCard] {
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let titles = sections(config)
        var cards: [KeyCard] = []
        for b in bindings {
            guard let keys = b["keys"] as? String, let command = b["command"] as? String else { continue }
            let mode = b["mode"] as? String ?? "main"
            let title = mode == "main" ? titles[keys] ?? "Other" : "Mode: \(mode)"
            let (mods, key) = chord(keys, style: style)
            let text = meaning(command)
            let row = KeyRow(mods: mods, key: key, text: text ?? command, code: text == nil)
            if let i = cards.firstIndex(where: { $0.title == title }) {
                cards[i].rows = fold(cards[i].rows, row, command)
            } else {
                cards.append(KeyCard(title: title, rows: [row]))
            }
        }
        cards.append(KeyCard(title: "Command line",
                             rows: commands.map { KeyRow(mods: [], key: $0.0, text: $0.1, code: true) },
                             wide: true))
        return cards
    }

    // Folds "workspace 2" on ctrl-alt-2 into the row of "workspace 1" on ctrl-alt-1 above it:
    // "1–2", "Go to workspace 1–2".
    static func fold(_ rows: [KeyRow], _ row: KeyRow, _ command: String) -> [KeyRow] {
        guard let last = rows.last, last.mods == row.mods, let n = Int(row.key), last.text.hasSuffix(last.key),
              command.hasPrefix("workspace ") || command.hasPrefix("send "),
              let first = last.key.split(separator: "–").first.map(String.init),
              let end = Int(last.key.split(separator: "–").last ?? ""), end + 1 == n else {
            return rows + [row]
        }
        let range = "\(first)–\(n)"
        let text = String(last.text.dropLast(last.key.count)) + range
        return Array(rows.dropLast()) + [KeyRow(mods: row.mods, key: range, text: text, code: false)]
    }
}

final class KeysPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Draws the cards, top down, in up to three columns: each card goes to the shortest column,
// the command line across the bottom.
final class KeysView: NSView {
    var cfg = BarConfig()
    var cards: [KeyCard] = []
    var hint: (mods: [String], key: String)?
    override var isFlipped: Bool { true }

    let pad: CGFloat = 24, gap: CGFloat = 16, inset: CGFloat = 13

    var body: NSFont { cfg.font(.medium) }
    var keyFont: NSFont { cfg.font(.bold) }
    var chipFont: NSFont { NSFont.monospacedSystemFont(ofSize: cfg.fontSize - 1.5, weight: .semibold) }
    var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: cfg.fontSize - 0.5, weight: .regular) }

    func color(_ mod: String) -> NSColor {
        guard cfg.keysColors else { return cfg.muted }
        switch mod {
        case "ctrl": return cfg.keysCtrlColor
        case "alt": return cfg.keysAltColor
        case "shift": return cfg.keysShiftColor
        default: return cfg.keysCmdColor
        }
    }

    func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    // The pieces of a chord, left to right: plain text, or a chip (rounded box) of text.
    func pieces(_ mods: [String], _ key: String) -> [(NSAttributedString, chip: Bool)] {
        var out: [(NSAttributedString, chip: Bool)] = []
        switch cfg.keysStyle {
        case "symbols":
            let s = NSMutableAttributedString()
            for m in mods { s.append(text(Keys.symbols[m] ?? m, keyFont, color(m))) }
            if !mods.isEmpty { out.append((s, false)) }
        case "plus":
            let s = NSMutableAttributedString()
            for m in mods {
                s.append(text(m.prefix(1).uppercased() + m.dropFirst(), body, color(m)))
                s.append(text("+", body, cfg.muted))
            }
            if !mods.isEmpty { out.append((s, false)) }
        case "words":
            if !mods.isEmpty {
                let s = NSMutableAttributedString()
                for (i, m) in mods.enumerated() { s.append(text((i > 0 ? " " : "") + m, body, color(m))) }
                out.append((s, false))
            }
        default:
            for m in mods { out.append((text(m, chipFont, color(m)), true)) }
        }
        out.append((text(key, keyFont, cfg.foreground), true))
        return out
    }

    func chordWidth(_ mods: [String], _ key: String) -> CGFloat {
        pieces(mods, key).reduce(CGFloat(0)) { $0 + $1.0.size().width + ($1.chip ? 10 : 0) + 5 } - 5
    }

    // Draws a chord ending at right, centred on y. Returns nothing; chordWidth sizes it.
    func drawChord(_ mods: [String], _ key: String, right: CGFloat, midY: CGFloat) {
        var x = right - chordWidth(mods, key)
        let parts = pieces(mods, key)
        for (i, (s, chip)) in parts.enumerated() {
            let size = s.size()
            if chip {
                let last = i == parts.count - 1
                let box = NSRect(x: x, y: midY - size.height / 2 - 1, width: size.width + 10, height: size.height + 2)
                cfg.foreground.withAlphaComponent(last ? 0.16 : 0.08).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                s.draw(at: NSPoint(x: x + 5, y: midY - size.height / 2))
                x += box.width + 5
            } else {
                s.draw(at: NSPoint(x: x, y: midY - size.height / 2))
                x += size.width + 5
            }
        }
    }

    // Lays out every card in a frame of this width, and draws them when draw is set.
    // Returns the height the cards need.
    @discardableResult
    func render(width: CGFloat, draw: Bool) -> CGFloat {
        let title = text("tatami", cfg.font(.bold).withSize(cfg.fontSize + 5), cfg.accent)
        if draw { title.draw(at: NSPoint(x: pad, y: pad)) }
        if draw, let h = hint {
            var x = pad + title.size().width + 12
            let lead = text("Esc or", body, cfg.muted)
            let mid = pad + title.size().height / 2
            lead.draw(at: NSPoint(x: x, y: mid - lead.size().height / 2))
            x += lead.size().width + 6
            let w = chordWidth(h.mods, h.key)
            drawChord(h.mods, h.key, right: x + w, midY: mid)
            text("closes", body, cfg.muted).draw(at: NSPoint(x: x + w + 6, y: mid - lead.size().height / 2))
        }
        let top = pad + title.size().height + 14
        let n = width >= 900 ? 3 : 2
        let colW = (width - 2 * pad - CGFloat(n - 1) * gap) / CGFloat(n)
        var heights = [CGFloat](repeating: top, count: n)
        for card in cards where !card.wide {
            let col = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let x = pad + CGFloat(col) * (colW + gap)
            heights[col] += cardHeight(card, x: x, y: heights[col], width: colW, draw: draw) + gap
        }
        var y = heights.max() ?? top
        for card in cards where card.wide {
            y += cardHeight(card, x: pad, y: y, width: width - 2 * pad, draw: draw) + gap
        }
        return y - gap + pad
    }

    func cardHeight(_ card: KeyCard, x: CGFloat, y: CGFloat, width: CGFloat, draw: Bool) -> CGFloat {
        let head = text(card.title.uppercased(), cfg.font(.bold).withSize(cfg.fontSize - 1.5), cfg.accent)
        var cy = y + inset + head.size().height + 8
        let keyW = card.rows.map { row -> CGFloat in
            card.wide ? text(row.key, codeFont, cfg.foreground).size().width : chordWidth(row.mods, row.key)
        }.max() ?? 0
        let textX = x + inset + keyW + 14
        let textW = x + width - inset - textX
        var rows: [(KeyRow, CGFloat, CGFloat)] = []
        for row in card.rows {
            let s = text(row.text, row.code && !card.wide ? codeFont : body, cfg.foreground)
            let h = max(s.boundingRect(with: NSSize(width: textW, height: 1000), options: [.usesLineFragmentOrigin]).height,
                        body.ascender - body.descender + 4)
            rows.append((row, cy, h))
            cy += h + 5
        }
        let height = cy - 5 + inset - y
        guard draw else { return height }
        cfg.foreground.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 10, yRadius: 10).fill()
        head.draw(at: NSPoint(x: x + inset, y: y + inset))
        for (row, ry, h) in rows {
            let lineMid = ry + (body.ascender - body.descender) / 2 + 2
            if card.wide {
                text(row.key, codeFont, cfg.accent).draw(at: NSPoint(x: x + inset, y: ry + 2))
            } else {
                drawChord(row.mods, row.key, right: x + inset + keyW, midY: lineMid)
            }
            let s = text(row.text, row.code && !card.wide ? codeFont : body, cfg.foreground)
            s.draw(with: NSRect(x: textX, y: ry + 2, width: textW, height: h), options: [.usesLineFragmentOrigin])
        }
        return height
    }

    override func draw(_ dirty: NSRect) {
        // Opaque, even when the bar's background lets the menu bar show through.
        cfg.background.withAlphaComponent(1).setFill()
        bounds.fill()
        render(width: bounds.width, draw: true)
    }
}

extension Bar {
    func toggleKeys() {
        if let p = keysPanel, p.isVisible { closeKeys(restore: true); return }
        let cfg = self.cfg
        DispatchQueue.global().async {
            let bindings = self.json("query bindings --json")?["bindings"] as? [[String: Any]] ?? []
            DispatchQueue.main.async { self.showKeys(bindings, cfg) }
        }
    }

    func showKeys(_ bindings: [[String: Any]], _ cfg: BarConfig) {
        let view = KeysView()
        view.cfg = cfg
        view.cards = Keys.cards(bindings, style: cfg.keysStyle)
        if let own = bindings.first(where: { ($0["command"] as? String ?? "").contains("tatami-bar keys") }),
           let k = own["keys"] as? String {
            view.hint = Keys.chord(k, style: cfg.keysStyle)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let width = min(1080, area.width - 80)
        let height = min(view.render(width: width, draw: false), area.height - 80)
        let frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        let panel = keysPanel ?? KeysPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        panel.contentView = view
        panel.setFrame(frame, display: true)
        keysPanel = panel
        keysPrevious = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // restore gives focus back to the app that had it; a click elsewhere has moved it already.
    func closeKeys(restore: Bool) {
        guard let p = keysPanel, p.isVisible else { return }
        p.orderOut(nil)
        if restore { keysPrevious?.activate() }
        keysPrevious = nil
    }
}

if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "check":
        let (_, errors) = BarConfig.load()
        for e in errors { print(e) }
        print(errors.isEmpty ? "\(BarConfig.path): ok" : "\(errors.count) error(s); those lines are skipped")
        exit(errors.isEmpty ? 0 : 1)
    case "keys":
        // The running bar shows or hides the sheet. This process is a tatami-bar too.
        signal(SIGUSR1, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-USR1", "-x", "tatami-bar"]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { print("tatami-bar is not running") }
        exit(p.terminationStatus == 0 ? 0 : 1)
    default:
        print("usage: tatami-bar [check | keys]\n  reads \(BarConfig.path); kill -HUP reloads it\n  keys shows or hides the key bindings")
        exit(CommandLine.arguments[1] == "help" || CommandLine.arguments[1] == "--help" ? 0 : 2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.delegate = bar
app.run()
