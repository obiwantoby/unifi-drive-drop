import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding(.bottom, 4)

            Form {
                Section("Console") {
                    TextField("Host", text: $host, prompt: Text("https://console.local"))
                    TextField("Username", text: $user)
                    SecureField("Password", text: $pass,
                                prompt: Text(model.username.isEmpty ? "Password" : "Stored — leave blank to keep"))
                    Toggle("Accept self-signed certificate", isOn: $model.allowInvalidCerts)
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(testing || host.isEmpty || user.isEmpty || pass.isEmpty)
                    if let r = testResult {
                        Label(r, systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.caption)
                    }
                }

                Section("Uploads") {
                    TextField("Destination folder", text: $model.currentDir, prompt: Text("/Public"))
                    Text("Relative to your personal drive. Created automatically if missing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Default expiration", selection: expirationBinding) {
                        ForEach(Expiration.menuOrder) { Text($0.label).tag($0.id) }
                    }
                    Toggle("Copy link automatically after upload", isOn: $model.copyOnUpload)
                }

                Section("Menu bar") {
                    Toggle("Show the Dock icon", isOn: $model.showDockIcon)
                    Text(model.showDockIcon
                         ? "The window is reachable from the Dock tile, ⌘-Tab and Exposé, as well as from the menu bar."
                         : "Menu bar only. The tile disappears from the Dock, ⌘-Tab and Exposé — use the menu bar's Open Window to get back to the window.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Text("Drive has no API-key access — its file API is per-user, so DriveDrop signs in with a local UniFi OS account and keeps the session cookie. Create a dedicated account with Drive access rather than reusing an admin login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Remove saved password", role: .destructive) {
                        pass = ""
                        model.clearSavedPassword()
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.saveCredentials(host: host, user: user, pass: pass)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || user.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
        .onAppear { host = model.host; user = model.username }
    }

    private var expirationBinding: Binding<String> {
        Binding(get: { model.defaultExpirationRaw },
                set: { model.defaultExpirationRaw = $0 })
    }

    private func test() {
        testing = true
        testResult = nil
        let h = host, u = user, p = pass
        let insecure = model.allowInvalidCerts
        Task {
            let s = DriveSession(host: h, username: u, password: p, allowInvalidCerts: insecure)
            do {
                try await s.login()
                let c = LiveDriveClient(session: s)
                let usage = try await c.usage()
                await MainActor.run {
                    testing = false
                    testOK = true
                    testResult = usage.totalBytes > 0
                        ? "Signed in · \(Fmt.bytes(usage.freeBytes)) free"
                        : "Signed in"
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testOK = false
                    testResult = error.localizedDescription
                }
            }
        }
    }
}
