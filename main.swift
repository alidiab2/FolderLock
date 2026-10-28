// FolderLock — protect a folder with a password / Touch ID from Finder's right-click menu.
//
// A protected folder keeps an AES-256 encrypted vault (a hidden sparse bundle) inside it.
// Locked: the folder only holds the vault. Unlocked: the files are decrypted into the folder
// and used normally. The app runs in the background and locks the folder again when you
// leave it in Finder, when the screen locks or the Mac sleeps, and moves anything dropped
// onto a locked folder straight into the vault.

import Cocoa
import LocalAuthentication
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

let kMeta = ".folderlock"
let kVault = ".folderlock.sparsebundle"
let kMarker = ".folderlock.locked"
let kLegacyDmg = ".folderlock.dmg"
let kLegacyNote = "🔒 This folder is locked.txt"
let kService = "FolderLock"
let kExtensionID = "local.folderlock.app.findersync"

/// Never treated as the user's files: our own files plus what macOS / Finder put in folders.
let ourNames: Set<String> = [kMeta, kVault, kMarker, kLegacyDmg, kLegacyNote, "Icon\r", ".DS_Store",
                             ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".localized",
                             ".metadata_never_index"]

/// How often the app checks which protected folders are open in Finder. A folder locks after two
/// checks in a row without being open, so about 1–2 seconds after you leave it.
let checkInterval: TimeInterval = 1
let ops = DispatchQueue(label: "folderlock.ops", qos: .userInitiated)

enum FLError: LocalizedError {
    case wrongPassword
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Incorrect password."
        case .msg(let m): return m
        }
    }
}

// MARK: - Shell helpers


@discardableResult
func runTool(_ path: String, _ args: [String], stdin: String? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    try p.run()
    if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)) }
    try? inp.fileHandleForWriting.close()
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        if e.contains("Authentication error") { throw FLError.wrongPassword }
        let lines = e.split(separator: "\n").filter { !$0.contains("deprecated") }.joined(separator: "\n")
        throw FLError.msg(lines.isEmpty ? "\(path) failed (\(p.terminationStatus))" : lines)
    }
    return o
}

func hdiutil(_ args: [String], stdin: String? = nil) throws {
    try runTool("/usr/bin/hdiutil", args, stdin: stdin)
}

// MARK: - Keychain (the folder password, used for automatic re-locking and Touch ID)

func kcQuery(_ id: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: kService,
     kSecAttrAccount as String: id]
}

func kcSave(_ id: String, _ pw: String) {
    SecItemDelete(kcQuery(id) as CFDictionary)
    var q = kcQuery(id)
    q[kSecValueData as String] = Data(pw.utf8)
    q[kSecAttrLabel as String] = "FolderLock folder password"
    SecItemAdd(q as CFDictionary, nil)
}

func kcLoad(_ id: String) -> String? {
    var q = kcQuery(id)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var res: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let d = res as? Data else { return nil }
    return String(data: d, encoding: .utf8)
}

func kcDelete(_ id: String) {
    SecItemDelete(kcQuery(id) as CFDictionary)
}

func biometricsAvailable() -> Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
}

func touchIDAllowed(_ id: String?) -> Bool {
    guard let id else { return false }
    return UserDefaults.standard.object(forKey: "touchid." + id) as? Bool ?? true
}

// MARK: - Vault engine (runs on the `ops` queue)

enum Vault {
    static let fm = FileManager.default

    static func isManaged(_ f: URL) -> Bool { fm.fileExists(atPath: f.appendingPathComponent(kMeta).path) }

    static func isLocked(_ f: URL) -> Bool {
        fm.fileExists(atPath: f.appendingPathComponent(kMarker).path)
            || fm.fileExists(atPath: f.appendingPathComponent(kLegacyDmg).path)
    }

    static func readID(_ f: URL) -> String? {
        guard let s = try? String(contentsOf: f.appendingPathComponent(kMeta), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func savedPassword(_ f: URL) -> String? { readID(f).flatMap(kcLoad) }

    static func userItems(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !ourNames.contains($0) }
    }

    static func uniqueName(_ name: String, in dir: URL) -> String {
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for i in 2... {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(n).path) { return n }
        }
        return name
    }

    static func copy(_ src: URL, _ dst: URL) throws {
        try runTool("/usr/bin/ditto", [src.path, dst.path])
    }

    static func removeItems(_ names: [String], in dir: URL) throws {
        for n in names where fm.fileExists(atPath: dir.appendingPathComponent(n).path) {
            try fm.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    static func withMounted<T>(_ image: URL, _ pw: String, readOnly: Bool, _ body: (URL) throws -> T) throws -> T {
        let mnt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FolderLock-\(UUID().uuidString)")
        try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
        do {
            // No -quiet here: we need hdiutil's "Authentication error" to detect a wrong password.
            try hdiutil(["attach", "-nobrowse", "-noautoopen", "-owners", "on"] + (readOnly ? ["-readonly"] : [])
                        + ["-mountpoint", mnt.path, "-stdinpass", image.path], stdin: pw)
        } catch {
            rmdir(mnt.path)
            throw error
        }
        defer {
            try? hdiutil(["detach", "-quiet", "-force", mnt.path])
            rmdir(mnt.path)
        }
        return try body(mnt)
    }

    static func setIcon(_ f: URL, locked: Bool) {
        let icon = locked ? lockedIcon() : nil
        let apply = { _ = NSWorkspace.shared.setIcon(icon, forFile: f.path, options: []) }
        Thread.isMainThread ? apply() : DispatchQueue.main.sync(execute: apply)
    }

    /// Encrypts the folder's contents into its vault and removes the readable copies.
    /// `newPassword` starts a fresh vault (used when the password is set or changed).
    static func lock(_ f: URL, id: String, password: String, newPassword: Bool, progress: (String) -> Void) throws {
        guard !isLocked(f) else { return }
        try (id + "\n").write(to: f.appendingPathComponent(kMeta), atomically: true, encoding: .utf8)
        let vault = f.appendingPathComponent(kVault)
        if newPassword, fm.fileExists(atPath: vault.path) { try fm.removeItem(at: vault) }
        if !fm.fileExists(atPath: vault.path) {
            progress("Creating secure storage…")
            try hdiutil(["create", "-quiet", "-size", "500g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                         "-volname", "FolderLock", "-encryption", "AES-256", "-stdinpass", vault.path], stdin: password)
        }

        progress("Encrypting…")
        let items = userItems(f)
        try withMounted(vault, password, readOnly: false) { mnt in
            try removeItems(userItems(mnt), in: mnt)
            // Keep Spotlight out of the vault: indexing it would slow down every lock and unlock.
            fm.createFile(atPath: mnt.appendingPathComponent(".metadata_never_index").path, contents: nil)
            for n in items { try copy(f.appendingPathComponent(n), mnt.appendingPathComponent(n)) }
            // Make sure everything really is in the vault before deleting anything.
            let missing = Set(items).subtracting(userItems(mnt))
            guard missing.isEmpty else {
                throw FLError.msg("Verification failed — nothing was deleted. Missing: \(missing.joined(separator: ", "))")
            }
        }

        progress("Securing…")
        try removeItems(items + [".DS_Store", kLegacyNote], in: f)
        fm.createFile(atPath: f.appendingPathComponent(kMarker).path, contents: nil)
        setIcon(f, locked: true)
    }

    /// Decrypts the vault back into the folder.
    static func unlock(_ f: URL, password: String, progress: (String) -> Void) throws {
        let legacy = f.appendingPathComponent(kLegacyDmg)
        let isLegacy = fm.fileExists(atPath: legacy.path)
        guard isLegacy || fm.fileExists(atPath: f.appendingPathComponent(kMarker).path) else { return }

        progress("Decrypting…")
        try withMounted(isLegacy ? legacy : f.appendingPathComponent(kVault), password, readOnly: true) { mnt in
            setIcon(f, locked: false)
            try? fm.removeItem(at: f.appendingPathComponent(kLegacyNote))
            for n in userItems(mnt) {
                try copy(mnt.appendingPathComponent(n), f.appendingPathComponent(uniqueName(n, in: f)))
            }
        }
        if isLegacy { try fm.removeItem(at: legacy) }
        try? fm.removeItem(at: f.appendingPathComponent(kMarker))
    }

    /// Moves files that were dropped into a locked folder into its vault. Returns their names.
    static func absorb(_ f: URL, password: String) throws -> [String] {
        let vault = f.appendingPathComponent(kVault)
        guard isLocked(f), fm.fileExists(atPath: vault.path) else { return [] }
        let items = userItems(f)
        guard !items.isEmpty else { return [] }
        try withMounted(vault, password, readOnly: false) { mnt in
            for n in items {
                try copy(f.appendingPathComponent(n), mnt.appendingPathComponent(uniqueName(n, in: mnt)))
            }
        }
        try removeItems(items + [".DS_Store"], in: f)
        return items
    }

    /// Stops protecting an unlocked folder; its files stay as they are.
    static func removeLock(_ f: URL) throws {
        guard !isLocked(f) else { throw FLError.msg("Unlock the folder first.") }
        let id = readID(f)
        try removeItems([kVault, kMeta, kMarker], in: f)
        setIcon(f, locked: false)
        if let id { kcDelete(id) }
    }

    /// Sum of sizes and counts of the given items, to tell when a copy into the folder has finished.
    static func snapshot(_ f: URL, _ items: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for n in items {
            let u = f.appendingPathComponent(n)
            var total = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let c as URL in e { total += ((try? c.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + 1 }
            }
            out[n] = total
        }
        return out
    }

    /// True if another app has a file inside the folder open (so locking now could lose its work).
    static func inUse(_ f: URL) -> Bool {
        guard let out = try? runTool("/usr/sbin/lsof", ["-F", "c", "+D", f.path]) else { return false }
        let ignored = ["mds", "mds_stores", "mdworker", "mdworker_shared", "Finder", "QuickLookUIService",
                       "fseventsd", "FolderLock", "revisiond", "bird", "fileproviderd", "lsof"]
        return out.split(separator: "\n").contains { line in
            line.hasPrefix("c") && !ignored.contains(String(line.dropFirst()))
        }
    }
}

// MARK: - Icons

func lockedIcon() -> NSImage {
    let size = NSSize(width: 512, height: 512)
    return NSImage(size: size, flipped: false) { rect in
        NSWorkspace.shared.icon(for: UTType.folder).draw(in: rect)
        let cfg = NSImage.SymbolConfiguration(pointSize: 170, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            let s = sym.size
            sym.draw(in: NSRect(x: (size.width - s.width) / 2, y: 200 - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

// MARK: - Dialog (lock / unlock / remove lock)

final class LockModel: ObservableObject {
    enum Mode { case lock, unlock, remove }

    let mode: Mode
    let folder: URL
    let saved: String?
    let canTouchID: Bool
    var close: () -> Void = {}
    var onSuccess: () -> Void = {}

    @Published var password = ""
    @Published var confirm = ""
    @Published var useTouchID = true
    @Published var error: String?
    @Published var busy = false
    @Published var status = ""
    @Published var shakes = 0

    init(mode: Mode, folder: URL) {
        self.mode = mode
        self.folder = folder
        saved = Vault.savedPassword(folder)
        canTouchID = biometricsAvailable() && (mode == .lock || (saved != nil && touchIDAllowed(Vault.readID(folder))))
    }

    var name: String { folder.lastPathComponent }

    func fail(_ msg: String) {
        error = msg
        withAnimation(.default) { shakes += 1 }
    }

    func submit() {
        guard !busy else { return }
        switch mode {
        case .lock: lock()
        case .unlock: unlock(password)
        case .remove: remove(password)
        }
    }

    /// Runs `work` on the ops queue with the spinner showing; closes the dialog on success.
    func run(_ work: @escaping (@escaping (String) -> Void) throws -> Void) {
        busy = true
        error = nil
        ops.async {
            do {
                try work { s in DispatchQueue.main.async { self.status = s } }
                DispatchQueue.main.async {
                    self.onSuccess()
                    self.close()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.password = ""
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    func lock() {
        guard !password.isEmpty else { return fail("Enter a password.") }
        guard password == confirm else { return fail("Passwords don't match.") }
        let pw = password, touch = useTouchID, f = folder
        let id = Vault.readID(f) ?? UUID().uuidString
        run { progress in
            try Vault.lock(f, id: id, password: pw, newPassword: true, progress: progress)
            kcSave(id, pw)
            UserDefaults.standard.set(touch, forKey: "touchid." + id)
        }
    }

    func unlock(_ pw: String) {
        guard !pw.isEmpty else { return fail("Enter the password.") }
        let f = folder
        run { progress in
            try Vault.unlock(f, password: pw, progress: progress)
            // Keep the password so the folder can lock itself again later.
            if let id = Vault.readID(f) { kcSave(id, pw) }
        }
    }

    func remove(_ pw: String) {
        guard !pw.isEmpty else { return fail("Enter the password.") }
        if let saved, pw != saved { password = ""; return fail("Incorrect password.") }
        let f = folder
        run { _ in try Vault.removeLock(f) }
    }

    func touchID() {
        guard let saved, canTouchID, !busy else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        let reason = mode == .remove ? "remove the lock from “\(name)”" : "unlock “\(name)”"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                guard ok else { return }
                self.mode == .remove ? self.run { _ in try Vault.removeLock(self.folder) } : self.unlock(saved)
            }
        }
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct LockView: View {
    @ObservedObject var m: LockModel
    @FocusState private var focused: Bool

    var icon: NSImage {
        m.mode == .unlock ? lockedIcon() : NSWorkspace.shared.icon(forFile: m.folder.path)
    }

    var title: String {
        switch m.mode {
        case .lock: return "Lock “\(m.name)”"
        case .unlock: return "“\(m.name)” is Locked"
        case .remove: return "Remove Lock from “\(m.name)”?"
        }
    }

    var subtitle: String {
        let how = m.canTouchID ? "Use Touch ID or enter the password" : "Enter the password"
        switch m.mode {
        case .lock: return "It locks again by itself when you leave it. If you forget the password, the contents can't be recovered."
        case .unlock: return how + " to open it."
        case .remove: return "The folder will no longer be protected. " + how + " to confirm."
        }
    }

    var actionTitle: String {
        switch m.mode {
        case .lock: return "Lock"
        case .unlock: return "Unlock"
        case .remove: return "Remove Lock"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 72, height: 72)

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if m.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(m.status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(height: 28)
            } else {
                fields
            }

            if let e = m.error, !m.busy {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button { m.close() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button { m.submit() } label: { Text(actionTitle).frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .disabled(m.busy)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: 290)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
            if m.mode != .lock { m.touchID() }
        }
    }

    @ViewBuilder var fields: some View {
        VStack(spacing: 8) {
            if m.mode == .lock {
                SecureField("Password", text: $m.password)
                    .focused($focused)
                SecureField("Verify", text: $m.confirm)
                    .onSubmit { m.submit() }
                if m.canTouchID {
                    Toggle("Unlock with Touch ID", isOn: $m.useTouchID)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            } else {
                SecureField("Password", text: $m.password)
                    .focused($focused)
                    .onSubmit { m.submit() }
                if m.canTouchID {
                    Button { m.touchID() } label: { Label("Use Touch ID", systemImage: "touchid") }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .modifier(Shake(animatableData: CGFloat(m.shakes)))
    }
}

// MARK: - Welcome window (shown when the app is opened from Applications)

final class HomeModel: ObservableObject {
    @Published var extensionOn = false
    @Published var loginItemOn = false

    init() { refresh() }

    func refresh() {
        let out = (try? runTool("/usr/bin/pluginkit", ["-m", "-i", kExtensionID])) ?? ""
        extensionOn = out.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        loginItemOn = SMAppService.mainApp.status == .enabled
    }

    func enableExtension() {
        _ = try? runTool("/usr/bin/pluginkit", ["-e", "use", "-i", kExtensionID])
        refresh()
        if !extensionOn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
        }
    }

    func enableLoginItem() {
        try? SMAppService.mainApp.register()
        refresh()
        if !loginItemOn { SMAppService.openSystemSettingsLoginItems() }
    }
}

struct HomeView: View {
    @ObservedObject var m: HomeModel
    let choose: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            VStack(spacing: 6) {
                Text("FolderLock").font(.system(size: 17, weight: .semibold))
                Text("Right-click any folder in Finder and choose **Lock Folder**. Open it to unlock — it locks again when you leave. Anything you drop onto a locked folder is locked too.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                status(m.extensionOn, "Finder extension", m.enableExtension)
                status(m.loginItemOn, "Runs in the background", m.enableLoginItem)
            }
            HStack(spacing: 10) {
                Button { choose() } label: { Text("Choose Folder…").frame(maxWidth: .infinity) }
                Button { done() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: 320)
        .onAppear { m.refresh() }
    }

    func status(_ on: Bool, _ label: String, _ fix: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(label + (on ? " is on" : " is off")).font(.system(size: 12))
            if !on { Button("Turn On", action: fix).buttonStyle(.link).font(.system(size: 12)) }
        }
    }
}

func makePanel<V: View>(_ view: V) -> NSPanel {
    let host = NSHostingController(rootView: view)
    host.sizingOptions = [.preferredContentSize]
    let panel = NSPanel(contentViewController: host)
    panel.styleMask = [.titled, .fullSizeContentView]
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.center()
    return panel
}

// MARK: - Background controller

final class Controller: NSObject, NSApplicationDelegate {
    var windows: [String: NSPanel] = [:]
    /// Folders (or subfolders) of each protected folder that the Finder extension says are on screen.
    /// Only a fallback for when Finder can't be asked directly; its open/close events aren't reliable.
    var observed: [String: Set<String>] = [:]
    /// Consecutive checks in which an unlocked folder wasn't open in any Finder window.
    var idleChecks: [String: Int] = [:]
    /// Folders that were open in Finder when the screen locked, to ask for again afterwards.
    var openAtScreenLock: [URL] = []
    var monitor: Timer?
    var checking = false
    /// Locked folders we already showed the unlock window for while they're open in Finder.
    var promptedThisVisit: Set<String> = []
    let finderQueue = DispatchQueue(label: "folderlock.finder")
    var absorbJobs: [String: DispatchWorkItem] = [:]
    var watchers: [String: DispatchSourceFileSystemObject] = [:]
    var busy: Set<String> = []
    var handledRequest = false
    var loginLaunch = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ n: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        loginLaunch = ev == nil
            || ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let icns = Bundle.main.image(forResource: "AppIcon") { NSApp.applicationIconImage = icns }
        _ = try? runTool("/usr/bin/pluginkit", ["-e", "use", "-i", kExtensionID])
        try? SMAppService.mainApp.register()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(lockEverything), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockEverything),
                                                          name: NSWorkspace.willSleepNotification, object: nil)

        // Locked folders get watched for dropped files; unlocked ones are locked by the monitor
        // as soon as they aren't open in Finder.
        protectedFolders().filter(Vault.isLocked).forEach(watch)
        monitor = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkOpenFolders()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !self.handledRequest && !self.loginLaunch { self.showHome() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome()
        return true
    }

    // MARK: Registry of protected folders (bookmarks follow the folder if it's moved or renamed)

    func register(_ f: URL) {
        guard let id = Vault.readID(f), let bm = try? f.bookmarkData() else { return }
        var all = UserDefaults.standard.dictionary(forKey: "folders") as? [String: Data] ?? [:]
        all[id] = bm
        UserDefaults.standard.set(all, forKey: "folders")
    }

    func protectedFolders() -> [URL] {
        var all = UserDefaults.standard.dictionary(forKey: "folders") as? [String: Data] ?? [:]
        var out: [URL] = []
        var changed = false
        for (id, bm) in all {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale), Vault.readID(u) == id {
                out.append(u)
                if stale, let fresh = try? u.bookmarkData() { all[id] = fresh; changed = true }
            } else {
                all[id] = nil
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(all, forKey: "folders") }
        return out
    }

    // MARK: Requests from the Finder extension

    func application(_ application: NSApplication, open urls: [URL]) {
        handledRequest = true
        for url in urls {
            guard url.scheme == "folderlock",
                  let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let path = q.first(where: { $0.name == "path" })?.value else { continue }
            let f = URL(fileURLWithPath: path)
            let dir = q.first(where: { $0.name == "dir" })?.value ?? path
            switch url.host {
            case "enter":
                observed[path, default: []].insert(dir)
            case "leave":
                observed[path]?.remove(dir)
            case "open":
                // A locked folder was opened in Finder: ask for the password.
                observed[path, default: []].insert(dir)
                // Skip only right after you locked it yourself from inside the folder.
                let lockedAt = UserDefaults.standard.double(forKey: "lockedAt:" + path)
                if Vault.isLocked(f) && Date().timeIntervalSince1970 - lockedAt > 3 {
                    promptedThisVisit.insert(path)
                    show(.unlock, f, openAfter: false)
                } else {
                    promptedThisVisit.insert(path)
                }
            case "unlock":
                if Vault.isLocked(f) { show(.unlock, f, openAfter: true) }
            case "lock":
                if Vault.isManaged(f) && Vault.savedPassword(f) != nil {
                    relock(f, manual: true)
                } else if !Vault.isLocked(f) {
                    show(.lock, f, openAfter: false)
                }
            case "remove":
                if Vault.isManaged(f) && !Vault.isLocked(f) { show(.remove, f, openAfter: false) }
            default:
                break
            }
        }
    }

    // MARK: Locking again automatically

    /// The folders shown in Finder windows, or nil if Finder can't be asked (no permission).
    func finderTargets(_ done: @escaping ([String]?) -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else {
            return done([])
        }
        finderQueue.async {
            let src = """
            tell application "Finder"
                set out to {}
                repeat with i from 1 to (count of Finder windows)
                    try
                        set end of out to POSIX path of (target of Finder window i as alias)
                    end try
                end repeat
                return out
            end tell
            """
            var err: NSDictionary?
            let res = NSAppleScript(source: src)?.executeAndReturnError(&err)
            var paths: [String]?
            if let res, err == nil {
                paths = res.numberOfItems > 0 ? (1...res.numberOfItems).compactMap { res.atIndex($0)?.stringValue } : []
            }
            DispatchQueue.main.async { done(paths) }
        }
    }

    func isShown(_ f: URL, in targets: [String]) -> Bool {
        let root = f.resolvingSymlinksInPath().path
        return targets.contains { t in
            let p = URL(fileURLWithPath: t).resolvingSymlinksInPath().path
            return p == root || p.hasPrefix(root + "/")
        }
    }

    /// Runs every second: an unlocked folder that hasn't been open in Finder for two checks in a row
    /// gets locked again, and a locked folder open in Finder gets the unlock window (once per visit).
    func checkOpenFolders() {
        guard !checking else { return }
        let folders = protectedFolders()
        guard !folders.isEmpty else { idleChecks = [:]; return }
        checking = true
        finderTargets { [weak self] targets in
            guard let self else { return }
            self.checking = false
            for f in folders where Vault.isLocked(f) {
                let path = f.path
                if self.isShown(f, in: targets ?? []) {
                    if !self.promptedThisVisit.contains(path) && !self.busy.contains(path) {
                        self.promptedThisVisit.insert(path)
                        self.show(.unlock, f, openAfter: false)
                    }
                } else {
                    self.promptedThisVisit.remove(path)
                }
            }
            for f in folders where !Vault.isLocked(f) {
                let path = f.path
                self.promptedThisVisit.remove(path)
                let shown = targets.map { self.isShown(f, in: $0) } ?? !(self.observed[path] ?? []).isEmpty
                if shown || self.windows[path] != nil || self.busy.contains(path) {
                    self.idleChecks[path] = 0
                    continue
                }
                self.idleChecks[path, default: 0] += 1
                if self.idleChecks[path]! >= 2 {
                    self.idleChecks[path] = 0
                    self.relock(f)
                }
            }
        }
    }

    /// Locks with the saved password, without any window. Waits if another app has a file in it open.
    /// `manual` is "Lock Now" from the menu; otherwise it's an automatic lock after you left the folder.
    func relock(_ f: URL, manual: Bool = false) {
        let path = f.path
        guard !busy.contains(path), Vault.isManaged(f), !Vault.isLocked(f),
              let id = Vault.readID(f), let pw = kcLoad(id) else { return }
        busy.insert(path)
        ops.async {
            if Vault.inUse(f) {
                DispatchQueue.main.async {
                    self.busy.remove(path)
                    // Try again in about half a minute.
                    self.idleChecks[path] = -Int(30 / checkInterval)
                }
                return
            }
            let ok = (try? Vault.lock(f, id: id, password: pw, newPassword: false) { _ in }) != nil
            DispatchQueue.main.async {
                self.busy.remove(path)
                guard ok else { return }
                self.register(f)
                self.watch(f)
                if manual {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lockedAt:" + path)
                    NSSound(named: "Pop")?.play()
                } else {
                    // If you came back to the folder while it was being locked, ask for the password now.
                    self.finderTargets { targets in
                        if self.isShown(f, in: targets ?? []) {
                            self.promptedThisVisit.insert(path)
                            self.show(.unlock, f, openAfter: false)
                        }
                    }
                }
            }
        }
    }

    @objc func lockEverything() {
        let unlocked = protectedFolders().filter { !Vault.isLocked($0) }
        guard !unlocked.isEmpty else { return }
        finderTargets { [weak self] targets in
            guard let self else { return }
            self.openAtScreenLock = unlocked.filter { self.isShown($0, in: targets ?? []) }
            unlocked.forEach { self.relock($0) }
        }
    }

    /// After the screen unlocks, ask again for folders that got locked while they were open in Finder.
    @objc func screenUnlocked() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for f in self.openAtScreenLock where Vault.isLocked(f) {
                self.show(.unlock, f, openAfter: false)
            }
            self.openAtScreenLock = []
        }
    }

    // MARK: Drop-to-lock: watch locked folders for new files

    func watch(_ f: URL) {
        let path = f.path
        guard watchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.rename) || src.data.contains(.delete) {
                // The folder moved or was deleted: re-find it through its bookmark.
                self.unwatch(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.protectedFolders().filter(Vault.isLocked).forEach(self.watch)
                }
            } else {
                self.scheduleAbsorb(f)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[path] = src
        scheduleAbsorb(f)
    }

    func unwatch(_ path: String) {
        watchers.removeValue(forKey: path)?.cancel()
        absorbJobs.removeValue(forKey: path)?.cancel()
    }

    func scheduleAbsorb(_ f: URL) {
        let path = f.path
        absorbJobs[path]?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.busy.contains(path), Vault.isLocked(f),
                  !Vault.userItems(f).isEmpty, let pw = Vault.savedPassword(f) else { return }
            self.busy.insert(path)
            ops.async {
                // Wait until the copy into the folder has finished.
                var last = Vault.snapshot(f, Vault.userItems(f))
                for _ in 0..<120 {
                    Thread.sleep(forTimeInterval: 1)
                    let now = Vault.snapshot(f, Vault.userItems(f))
                    if now == last { break }
                    last = now
                }
                let added = (try? Vault.absorb(f, password: pw)) ?? []
                DispatchQueue.main.async {
                    self.busy.remove(path)
                    if !added.isEmpty { self.notify(added, f) }
                }
            }
        }
        absorbJobs[path] = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: job)
    }

    func notify(_ items: [String], _ f: URL) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Locked in “\(f.lastPathComponent)”"
            content.body = items.count == 1 ? "“\(items[0])” was added and locked." : "\(items.count) items were added and locked."
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Windows

    func show(_ mode: LockModel.Mode, _ f: URL, openAfter: Bool) {
        let key = f.path
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        guard !busy.contains(key) else { return }

        let model = LockModel(mode: mode, folder: f)
        let panel = makePanel(LockView(m: model))
        if mode == .unlock { unwatch(key) }
        model.onSuccess = { [weak self] in
            guard let self else { return }
            switch mode {
            case .lock:
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lockedAt:" + key)
                self.register(f)
                self.watch(f)
            case .unlock:
                self.register(f)
                if openAfter { NSWorkspace.shared.open(f) }
                self.idleChecks[key] = 0
            case .remove:
                break
            }
            NSSound(named: "Pop")?.play()
        }
        model.close = { [weak self] in
            panel.close()
            self?.windows[key] = nil
            if mode == .unlock && Vault.isLocked(f) { self?.watch(f) }
        }
        windows[key] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func showHome() {
        let key = "home"
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        var panel: NSPanel!
        let finish = { [weak self] in
            panel.close()
            self?.windows[key] = nil
        }
        panel = makePanel(HomeView(m: HomeModel(), choose: { [weak self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.prompt = "Choose"
            guard p.runModal() == .OK, let url = p.url else { return }
            finish()
            self?.show(Vault.isLocked(url) ? .unlock : .lock, url, openAfter: true)
        }, done: finish))
        panel.level = .normal
        windows[key] = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.count == 3, ["--lock", "--unlock", "--absorb"].contains(args[1]) {
    // Headless mode for scripting/testing: password from $FOLDERLOCK_PASSWORD.
    guard let pw = ProcessInfo.processInfo.environment["FOLDERLOCK_PASSWORD"] else {
        print("set FOLDERLOCK_PASSWORD"); exit(2)
    }
    let f = URL(fileURLWithPath: args[2])
    _ = NSApplication.shared
    var failure: Error?
    var finished = false
    ops.async {
        do {
            switch args[1] {
            case "--lock": try Vault.lock(f, id: Vault.readID(f) ?? UUID().uuidString, password: pw, newPassword: false) { print($0) }
            case "--unlock": try Vault.unlock(f, password: pw) { print($0) }
            default: print("absorbed:", try Vault.absorb(f, password: pw))
            }
        } catch { failure = error }
        DispatchQueue.main.async { finished = true }
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let failure { print("error: \(failure.localizedDescription)"); exit(1) }
    print("done")
    exit(0)
}

let app = NSApplication.shared
let delegate = Controller()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
