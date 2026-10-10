import SwiftUI

/// Clicking the Dock icon, or reopening the app while it is already running, must bring the
/// window back. Without this the app looks dead in Exposé: it is running, has a Dock tile, and
/// has no window — the only way back is the menu bar, which is not where anyone looks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Prefer an existing window: SwiftUI usually keeps it around, merely ordered out,
            // and re-showing it preserves the folder and scroll position the user left.
            let win = NSApp.windows.first {
                $0.title == "DriveDrop" && $0.canBecomeMain && !($0 is NSPanel)
            }
            if let win {
                win.makeKeyAndOrderFront(nil)
            } else {
                NotificationCenter.default.post(name: .drivedropReopen, object: nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct DriveDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DriveDrop", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Files…") {
                    NotificationCenter.default.post(name: .drivedropPickFiles, object: nil)
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        // Menu bar presence. .window style so the usage bar and link rows render properly.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .frame(width: 320)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let drivedropPickFiles = Notification.Name("drivedrop.pickFiles")
    static let drivedropReopen    = Notification.Name("drivedrop.reopen")
}

/// The status item's label is instantiated for as long as the item exists, unlike the popover
/// content, which SwiftUI creates lazily on first open. A reopen request arriving before the
/// popover has ever been shown therefore has to be handled here.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "arrow.up.forward.square")
            .onReceive(NotificationCenter.default.publisher(for: .drivedropReopen)) { _ in
                openWindow(id: "main")
            }
    }
}
