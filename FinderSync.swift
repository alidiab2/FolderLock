// Finder extension: adds Lock / Unlock items to the right-click menu, and tells the app when a
// protected folder is opened or left in Finder (so it can prompt to unlock, or lock it again).

import Cocoa
import FinderSync

@objc(FinderSync)
class FinderSync: FIFinderSync {
    let fm = FileManager.default

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    func isManaged(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent(".folderlock").path)
    }

    func isLocked(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent(".folderlock.locked").path)
            || fm.fileExists(atPath: url.appendingPathComponent(".folderlock.dmg").path)
    }

    func isFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    /// The protected folder that contains `url` (or is `url`), if any.
    func protectedRoot(_ url: URL) -> URL? {
        var u = url.standardizedFileURL
        while u.path != "/" {
            if isManaged(u) || isLocked(u) { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Folder open / close

    override func beginObservingDirectory(at url: URL) {
        guard let root = protectedRoot(url) else { return }
        if isLocked(root) && root.path == url.standardizedFileURL.path {
            request("open", root, auto: true)
        } else {
            request("enter", root, dir: url)
        }
    }

    override func endObservingDirectory(at url: URL) {
        guard let root = protectedRoot(url) else { return }
        request("leave", root, dir: url)
    }

    // MARK: Context menu

    func targets(_ kind: FIMenuKind) -> [URL] {
        let c = FIFinderSyncController.default()
        switch kind {
        case .contextualMenuForItems: return (c.selectedItemURLs() ?? []).filter(isFolder)
        case .contextualMenuForContainer: return c.targetedURL().map { [$0] } ?? []
        default: return []
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let folders = targets(menuKind)
        guard let first = folders.first else { return nil }
        let menu = NSMenu()
        let many = folders.count > 1 ? " \(folders.count) Folders" : ""
        let inside = menuKind == .contextualMenuForContainer

        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        if isLocked(first) {
            add(many.isEmpty ? "Unlock Folder" : "Unlock" + many, "lock.open", #selector(unlockItems(_:)))
        } else if isManaged(first) {
            add(inside ? "Lock This Folder Now" : (many.isEmpty ? "Lock Now" : "Lock" + many), "lock", #selector(lockItems(_:)))
            add("Remove Lock…", "lock.slash", #selector(removeItems(_:)))
        } else {
            add(inside ? "Lock This Folder" : (many.isEmpty ? "Lock Folder" : "Lock" + many), "lock", #selector(lockItems(_:)))
        }
        return menu
    }

    func clicked() -> [URL] {
        let items = targets(.contextualMenuForItems)
        return items.isEmpty ? targets(.contextualMenuForContainer) : items
    }

    @objc func lockItems(_ sender: AnyObject?) {
        clicked().filter { !isLocked($0) }.forEach { request("lock", $0) }
    }

    @objc func unlockItems(_ sender: AnyObject?) {
        clicked().filter(isLocked).forEach { request("unlock", $0) }
    }

    @objc func removeItems(_ sender: AnyObject?) {
        clicked().filter { isManaged($0) && !isLocked($0) }.forEach { request("remove", $0) }
    }

    // MARK: Talk to the app

    func request(_ action: String, _ folder: URL, auto: Bool = false, dir: URL? = nil) {
        var c = URLComponents()
        c.scheme = "folderlock"
        c.host = action
        c.queryItems = [URLQueryItem(name: "path", value: folder.path),
                        URLQueryItem(name: "auto", value: auto ? "1" : "0"),
                        URLQueryItem(name: "dir", value: (dir ?? folder).path)]
        guard let url = c.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.open(url, configuration: cfg)
    }
}
