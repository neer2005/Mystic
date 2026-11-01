import SwiftUI
import AppKit
import MysticDesktop

@main
struct MysticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ConnectionModel()
    /// Nightjar's command line for game frontends; see `ShortcutLaunch`.
    private let startup: ShortcutLaunch?
    init() {
        switch ShortcutLaunch.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
        case .none: startup = nil
        case .launch(let launch): startup = launch
        case .version:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
            print("Mystic \(version) (Nightjar 4.0.1 engine)");exit(0)
        case .help: print(ShortcutLaunch.usage);exit(0)
        case .invalid(let message): FileHandle.standardError.write(Data((message + "\n").utf8));exit(64)
        }
        FullScreenCommands.suppressAppKitItem()
    }
    var body: some Scene {
        Window("Mystic", id: "library") { HostLibraryView(model: model, startup: startup).onAppear { appDelegate.model = model } }
            .defaultSize(width: 1200, height: 720)
            .commands {
                SidebarCommands()
                // Show Toolbar and Customize Toolbar…; the stream toolbar keeps secondary items there.
                ToolbarCommands()
                FullScreenCommands()
                LibraryCommands()
                StreamCommands(model:model)
                CommandGroup(after: .newItem) {
                    Button("Connect to Host") { model.connect() }.keyboardShortcut("k", modifiers: .command)
                        .disabled(model.isBusy || model.hasSession)
                    Button("Disconnect") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(!model.canDisconnect)
                }
            }
        Settings { MysticSettingsView(model:model) }
        Window("Mystic Stream", id: "stream") { StreamingView(model: model) }
            .windowManagerRole(.principal)
            // Opened by starting a stream; an empty stream window from the Window menu has no use.
            .commandsRemoved()
            .defaultSize(width: 1280, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ConnectionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasSession || model.isBusy else { return .terminateNow }
        model.disconnect()
        Task { @MainActor in
            while model.phase == .disconnecting { try? await Task.sleep(for: .milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
