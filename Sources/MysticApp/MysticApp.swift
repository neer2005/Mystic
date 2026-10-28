import SwiftUI
import AppKit
import MysticDesktop

@main
struct MysticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ConnectionModel()
    var body: some Scene {
        Window("Mystic", id: "library") { HostLibraryView(model: model).onAppear { appDelegate.model = model } }
            .defaultSize(width: 1200, height: 720)
            .commands {
                SidebarCommands()
                LibraryCommands()
                CommandGroup(after: .newItem) {
                    Button("Connect to Host") { model.connect() }.keyboardShortcut("k", modifiers: .command)
                        .disabled(model.isBusy || model.hasSession)
                    Button("Disconnect") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift])
                }
            }
        Settings { MysticSettingsView(model:model) }
        Window("Mystic Stream", id: "stream") { StreamingView(model: model) }
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
