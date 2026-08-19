import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model, !terminationPending else {
            return .terminateNow
        }
        terminationPending = true
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination()
    }
}

@main
@MainActor
struct DisplayTransformerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject
    private var model = AppModel()

    var body: some Scene {
        WindowGroup("Display Transformer") {
            ControlView(model: model) {
                appDelegate.model = model
                model.appDidLaunch()
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Übertragung") {
                Button("Übertragung stoppen") {
                    model.requestStop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isRunning)

                Button("Monitore aktualisieren") {
                    model.refreshDisplays()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)
            }
        }
    }
}
