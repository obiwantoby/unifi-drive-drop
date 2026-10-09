import SwiftUI

@main
struct DriveDropApp: App {
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
        MenuBarExtra("DriveDrop", systemImage: "arrow.up.forward.square") {
            MenuBarContent()
                .environmentObject(model)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let drivedropPickFiles = Notification.Name("drivedrop.pickFiles")
}
