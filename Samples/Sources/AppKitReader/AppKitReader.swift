import AppKit
import Combine
import ReaderSampleSupport

@main
@MainActor
enum AppKitReaderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session = ReaderSession()
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let results = NSPopUpButton()
    private var changes: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "終了 / Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "編集 / Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "コピー / Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "すべて選択 / Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let controls = NSStackView(views: [
            button("開く / Open…", #selector(openFile)),
            button("サンプル / Demo", #selector(openDemo)),
            button("前へ / Previous", #selector(previous)),
            button("次へ / Next", #selector(next)), search, results,
        ])
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        search.placeholderString = "検索 / Search"
        search.target = self
        search.action = #selector(find)
        search.sendsSearchStringImmediately = false
        results.target = self
        results.action = #selector(showHit)
        results.widthAnchor.constraint(equalToConstant: 180).isActive = true
        search.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let content = NSView()
        for child in [controls, session.reader, status] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            session.reader.topAnchor.constraint(equalTo: controls.bottomAnchor),
            session.reader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            session.reader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            session.reader.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.contentView = content
        window.minSize = NSSize(width: 920, height: 500)
        changes = session.objectWillChange.sink { [weak self] in
            // objectWillChange は値の変更前なので、次の main queue で表示へ反映する。
            DispatchQueue.main.async { self?.refresh() }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.open(ReaderSession.demoURL)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func refresh() {
        window.title = "\(session.title) · AppKit"
        status.stringValue = session.status
        status.textColor = session.errorMessage == nil ? .secondaryLabelColor : .systemRed
        let selected = results.indexOfSelectedItem
        results.removeAllItems()
        if session.hits.isEmpty { results.addItem(withTitle: session.isSearching ? "検索中…" : "検索結果 / Results") }
        for (index, hit) in session.hits.enumerated() { results.addItem(withTitle: "\(index + 1): \(hit.snippet)") }
        if session.hits.indices.contains(selected) { results.selectItem(at: selected) }
        results.isEnabled = !session.hits.isEmpty
    }

    @objc private func openFile() { session.chooseFile() }
    @objc private func openDemo() { session.open(ReaderSession.demoURL) }
    @objc private func previous() { session.reader.goBackward() }
    @objc private func next() { session.reader.goForward() }
    @objc private func find() { session.search(search.stringValue) }
    @objc private func showHit() { session.showHit(at: results.indexOfSelectedItem) }
    func windowWillClose(_ notification: Notification) { session.close() }
    func applicationWillTerminate(_ notification: Notification) { session.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
