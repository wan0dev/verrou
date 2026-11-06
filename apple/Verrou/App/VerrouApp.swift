import AppKit
import ServiceManagement
import SwiftUI

/// Entry point: the app, or (Debug builds, `VERROU_REVIEW=1`) the offscreen
/// visual review, which opens no SwiftUI scene and no window.
@main
enum VerrouMain {
    static func main() {
        #if DEBUG
        if AppModel.isReview {
            MainActor.assumeIsolated { ReviewDriver.run() }
            return
        }
        #endif
        VerrouApp.main()
    }
}

struct VerrouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Verrou", id: "main") {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Login") { delegate.model.newItem(login: true) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!delegate.model.canEdit)
                Button("New Secure Note") { delegate.model.newItem(login: false) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!delegate.model.canEdit)
                Button("New Document…") { delegate.model.newDocument() }
                    .disabled(!delegate.model.canEdit)
                Button("New Folder…") { delegate.model.promptNewFolder() }
                    .disabled(!delegate.model.canManageFolders)
                Divider()
                Button("Import…") { delegate.model.startImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!delegate.model.canEdit)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find…") { delegate.model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(delegate.model.lockState != .unlocked)
            }
            // The selected item, as in 1Password and Quick Access: ⌘C alone
            // stays the text copy of the fields.
            CommandMenu("Item") {
                ItemCommands(model: delegate.model)
            }
            CommandMenu("Vault") {
                Button("Quick Access") { delegate.quickAccess?.toggle() }
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
                Button("Generate Password…") { delegate.generator?.show() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Divider()
                Button("Sync") { Task { await delegate.model.syncNow() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(delegate.model.lockState != .unlocked || delegate.model.mode == .demo)
                Button("Clean Up Duplicates…") { delegate.model.openDuplicates() }
                    .disabled(delegate.model.lockState != .unlocked)
                // Panes of the main window, as in the sidebar.
                Divider()
                Button("Security Audit") {
                    delegate.model.showMainWindow()
                    delegate.model.openAudit()
                }
                .disabled(delegate.model.lockState != .unlocked)
                if delegate.model.mode == .vaultwarden {
                    Button("Sends") { delegate.model.openSends() }
                        .disabled(!delegate.model.sendsAvailable)
                    Button("New Send…") {
                        delegate.model.showMainWindow()
                        delegate.model.newSend()
                    }
                    .disabled(!delegate.model.sendsAvailable)
                    Button("New File Send…") {
                        delegate.model.showMainWindow()
                        delegate.model.newFileSend()
                    }
                    .disabled(!delegate.model.sendsAvailable)
                    Button("Emergency Access") { delegate.model.openEmergency() }
                        .disabled(!delegate.model.emergencyAvailable)
                    Divider()
                    Button("New Shared Vault…") {
                        delegate.model.showMainWindow()
                        delegate.model.openNewOrganization()
                    }
                    .disabled(!delegate.model.canEdit)
                    Button("Join a Shared Vault…") {
                        delegate.model.showMainWindow()
                        delegate.model.openJoin()
                    }
                    .disabled(!delegate.model.canEdit)
                }
                Divider()
                Button("Lock") { delegate.model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(delegate.model.lockState != .unlocked)
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarMenu(quickAccess: { delegate.quickAccess?.show() }, generator: { delegate.generator?.show() })
                .environment(delegate.model)
        } label: {
            MenuBarIcon()
                .environment(delegate.model)
        }
    }
}

/// The main window, from anywhere: the menu bar, a notification, the
/// extension's "unlock". Closed, SwiftUI has torn its scene down with it, so
/// only the `openWindow` action of a scene still alive can bring it back: the
/// menu bar icon registers that action (`MenuBarIcon`), always on screen
/// while its setting is on. The Dock icon, which only follows the window (see
/// `AppDelegate`), comes back with it.
@MainActor
enum MainScene {
    /// `openWindow(id: "main")`, registered by the menu bar icon.
    static var reopen: (() -> Void)?
    /// A reopen event is on its way: it must not send another one.
    private static var reopening = false

    static func show() {
        // Offscreen review: nothing must appear, nor the app come to the front.
        guard !AppModel.isReview else { return }
        // An accessory app has no Dock icon and no app menu: give them back
        // with the window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let reopen {
            reopen()
        } else if !reopening {
            // No menu bar icon: a reopen event, as a click on the Dock sends
            // it, recreates the scene.
            reopening = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { reopening = false }
            }
        }
    }
}

/// Menu bar icon: padlock closed or open, depending on the vault.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.lockState == .unlocked ? "lock.open.fill" : "lock.fill")
            .accessibilityLabel(model.lockState == .unlocked ? "Verrou, unlocked" : "Verrou, locked")
            .onAppear { MainScene.reopen = { openWindow(id: "main") } }
            // The scene goes away with the icon: nothing left to call.
            .onDisappear { MainScene.reopen = nil }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    let quickAccess: () -> Void
    let generator: () -> Void

    var body: some View {
        Text(status)
        Divider()
        Button("Quick Access", action: quickAccess)
            .keyboardShortcut(.space, modifiers: [.command, .shift])
        Button("Generate Password…", action: generator)
        Button("Open Verrou", action: showMainWindow)
        Divider()
        if model.lockState == .unlocked {
            if model.mode == .vaultwarden {
                Button("Sync") { Task { await model.syncNow() } }
            }
            Button("Lock") { model.lock() }
        } else {
            // The main window asks for Touch ID by itself.
            Button("Unlock…", action: showMainWindow)
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Verrou") { (NSApp.delegate as? AppDelegate)?.quit() }
            .keyboardShortcut("q")
    }

    private var status: String {
        switch model.lockState {
        case .unlocked: model.account.map { String(localized: "Unlocked · \($0.email)") } ?? String(localized: "Unlocked")
        case .unlocking: String(localized: "Unlocking…")
        case .locked: model.needsLogin ? String(localized: "Not logged in") : String(localized: "Locked")
        }
    }

    private func showMainWindow() {
        MainScene.show()
    }
}

struct ItemCommands: View {
    let model: AppModel

    var body: some View {
        let multi = model.isMultiSelection
        let item = multi ? nil : model.selectedSummary
        let ids = multi ? model.selectedIDs : item.map { [$0.id] } ?? []
        Button("Copy Username") { if let item { model.copyUsername(of: item.id) } }
            .keyboardShortcut("c", modifiers: [.command, .control])
            .disabled(item?.category != .login || item?.subtitle.isEmpty != false)
        Button("Copy Password") { if let item { model.copyPassword(of: item.id) } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(item?.category != .login)
        Button("Copy One-Time Code") { if let item { model.copyCode(of: item.id) } }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(item?.hasTotp != true)
        Button("Copy Website") { if let item { model.copyWebsite(of: item.id) } }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(item?.host == nil)
        Divider()
        Button("Edit Item…") { if let item { Task { await model.edit(item.id) } } }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.canModify(item) || item == nil || item?.state == .trashed)
        Button(item?.favorite == true ? "Remove from Favorites" : "Add to Favorites") {
            if let item { Task { await model.setFavorite(item.id, !item.favorite) } }
        }
        .disabled(!model.canModify(item) || item?.state != .active)
        if item?.state == .archived {
            Button("Unarchive") { if let item { Task { await model.setArchived(item.id, false) } } }
                .disabled(!model.canModify(item))
        } else {
            Button("Archive") {
                if multi {
                    Task { await model.performBulk(.archive, on: ids) }
                } else if let item {
                    Task { await model.setArchived(item.id, true) }
                }
            }
            .disabled(multi ? !model.canEdit || model.availability(of: ids).active == 0
                            : !model.canModify(item) || item?.state != .active)
        }
        Button(item?.sharing == nil ? "Share…" : "Collections…") { if let item { model.openSharing(item.id) } }
            .disabled(!model.canModify(item) || item?.state != .active
                      || (item?.sharing == nil && model.writableOrganizations.isEmpty))
        Button("Open Website") {
            if let host = item?.host, let url = URL(string: "https://\(host)") { NSWorkspace.shared.open(url) }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(item?.host == nil)
        Divider()
        if item?.state == .trashed {
            Button("Restore") { if let item { Task { await model.restore(item.id) } } }
                .disabled(!model.canModify(item))
        } else {
            Button("Move to Trash") { moveToTrash(ids) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(ids.isEmpty || !model.canEdit || (!multi && !model.canModify(item)) || model.editor != nil)
        }
        Divider()
        Text("Hold ⌥ to show the hidden fields")
    }

    private func moveToTrash(_ ids: [String]) {
        let window = NSApp.keyWindow
        let typed = NSApp.currentEvent?.type == .keyDown
        guard !typed || (window?.identifier?.rawValue == "main" && !(window?.firstResponder is NSText)) else {
            window?.firstResponder?.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
            return
        }
        if ids.count == 1 {
            Task { await model.trash(ids[0]) }
        } else {
            Task { await model.performBulk(.trash, on: ids) }
        }
    }
}

/// Opening Verrou at login (login item).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS waits for the user's approval in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Launched by macOS at login (and not by the user).
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The vault window is built once, behind the lock screen (empty:
    /// locking clears everything it displays), and kept: unlocking reveals
    /// it instead of rebuilding it. It is built right after the lock screen
    /// first shows, while Touch ID waits for the finger.
    @State private var vaultMounted = false

    private var unlocked: Bool { model.lockState == .unlocked }

    var body: some View {
        ZStack {
            if vaultMounted || unlocked {
                MainView()
                    .opacity(unlocked ? 1 : 0)
                    .allowsHitTesting(unlocked)
                    .accessibilityHidden(!unlocked)
            }
            if !unlocked {
                Group {
                    if model.needsLogin {
                        LoginView()
                    } else {
                        LockView()
                    }
                }
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.async { vaultMounted = true }
                }
            }
        }
        .toolbar(unlocked ? .automatic : .hidden, for: .windowToolbar)
        .animation(.easeOut(duration: 0.15), value: model.lockState)
        .animation(.easeOut(duration: 0.15), value: model.needsLogin)
        .onContinuousHover { _ in model.noteActivity() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var quickAccess: QuickAccessController?
    private(set) var generator: GeneratorWindow?
    /// Filling in apps (⌘\), through quick access.
    private(set) var autofill: UniversalAutofill?
    private var demo: DemoDriver?
    #if DEBUG
    private var endToEnd: EndToEndDriver?
    #endif
    #if DEBUG || BENCH
    private var bench: BenchDriver?
    #endif

    /// To read before launch finishes: the open event is no longer
    /// "current" afterwards.
    private var launchedAtLogin = false

    /// The Quit item asked to quit: `applicationShouldTerminate` lets that
    /// one through.
    private var quitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LaunchAtLogin.launchedAtLogin
        // Sharing notifications: before launch finishes, to receive the tap
        // that launched the app. Nothing real in the demo or during a test
        // run.
        let environment = ProcessInfo.processInfo.environment
        let notifier = ActivityNotifier.shared
        notifier.silent = model.mode != .vaultwarden || environment["VERROU_E2E_SERVER"] != nil
        notifier.install()
        notifier.setHandler { [weak model] route in model?.openActivity(route) }
        // Button tooltips (toolbar, icons) after 0.3 s instead of about a
        // second: hovering responds right away.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.start()
        let generator = GeneratorWindow(model: model)
        self.generator = generator
        let quickAccess = QuickAccessController(model: model)
        quickAccess.generator = generator
        self.quickAccess = quickAccess
        autofill = UniversalAutofill(model: model, quickAccess: quickAccess)
        quickAccess.autofill = autofill
        let environment = ProcessInfo.processInfo.environment
        if model.mode == .vaultwarden, environment["VERROU_E2E_SERVER"] == nil {
            let bridge = BrowserBridge(model: model)
            model.browserBridge = bridge
            bridge.apply()
        }
        if launchedAtLogin {
            // Login: Verrou waits quietly, in the menu bar and behind ⌘⇧Space,
            // with no window and no Touch ID.
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue == "main" }.forEach { $0.close() }
            }
        }
        watchWindows()
        if ProcessInfo.processInfo.environment["VERROU_DEMO"] == "1" {
            demo = DemoDriver(model: model, quickAccess: quickAccess)
            demo?.start()
        }
        #if DEBUG
        if let config = EndToEndDriver.Config(ProcessInfo.processInfo.environment) {
            endToEnd = EndToEndDriver(model: model, config: config)
            endToEnd?.start()
        }
        #endif
        #if DEBUG || BENCH
        if environment["VERROU_BENCH"] == "1" {
            bench = BenchDriver(model: model)
            bench?.start()
        }
        #endif
    }

    /// `true`: one of the app's windows is on screen. Panels don't count,
    /// and neither may the menu bar icon's own windows: `NSStatusBarWindow`
    /// is no panel and reports visible for as long as the item sits in the
    /// menu bar — only a window that can become main (titled, as the app's
    /// real windows are) keeps the Dock icon around.
    private var hasWindows: Bool {
        NSApp.windows.contains {
            !($0 is NSPanel) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
    }

    /// The Dock icon follows the windows: closed, the app lives in the menu
    /// bar alone (`NSApp.setActivationPolicy(.accessory)` drops the Dock icon
    /// and the app menu, keeps the windows and the status items). Called
    /// after each close or opening, once the window's state has settled.
    private func followWindows() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Without the menu bar icon, the Dock icon is the only way back.
            let menuBarIcon = UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
            let wanted: NSApplication.ActivationPolicy = hasWindows || !menuBarIcon ? .regular : .accessory
            guard NSApp.activationPolicy() != wanted else { return }
            NSApp.setActivationPolicy(wanted)
        }
    }

    /// The observer tokens ([`watchWindows`]): a block observer whose token
    /// is released is cancelled — they must live as long as the app.
    private var windowWatchers: [NSObjectProtocol] = []

    private func watchWindows() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            windowWatchers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followWindows() }
            })
        }
        // The menu bar setting changes while the app runs.
        windowWatchers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindows() }
        })
        // The launch state: launched at login, the window was closed above,
        // before these observers existed.
        followWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// SwiftUI ends a menu-bar-only app by itself: once the last window
    /// has closed, the next interaction with the menu performs a bare
    /// terminate: (no AppleEvent reason). Staying in the menu bar is the
    /// point, so that one is cancelled — a real quit still goes through,
    /// from the Quit item (the flag above), from the system (a logout
    /// carries a reason), or from the app menu, which only exists while a
    /// window is open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)?.stringValue
        guard reason == nil, sender.activationPolicy() == .accessory, !hasWindows else { return .terminateNow }
        return .terminateCancel
    }

    /// Quit for real, from the menu bar's Quit item.
    func quit() {
        quitting = true
        NSApp.terminate(nil)
    }

    /// A click on the app (Finder, Spotlight): the main window comes back.
    /// With the menu bar icon, its registered `openWindow` recreates it;
    /// without it, `true` leaves the reopen to SwiftUI's own scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, MainScene.reopen != nil { MainScene.show() }
        return true
    }

    /// An answer from the iPhone (silent iCloud notification): read it
    /// without waiting for the next poll.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if RemoteCloud.isApproval(userInfo) { model.remote?.poke() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.lock()
    }
}
