import SwiftUI
import AppKit

/// First-run permission wizard (PRD §34).
struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to One+Connect").font(.title2).bold()
            Text("To provide an extended display, One+Connect needs the permissions below. Your display data travels only over the USB cable or your own Wi-Fi network; no cloud servers are used.")
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(title: "Screen Recording",
                          detail: "Required to capture the display that is sent to the tablet.",
                          granted: model.screenRecordingGranted) {
                if !CaptureManager.requestPermission() {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                }
            }

            permissionRow(title: "Accessibility",
                          detail: "Required to turn tablet touches into mouse events.",
                          granted: model.accessibilityGranted) {
                _ = CGEventInput.requestAuthorization()
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }

            Divider()
            HStack(alignment: .top) {
                Image(systemName: model.adbPath == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundColor(model.adbPath == nil ? .red : .green)
                VStack(alignment: .leading) {
                    Text("USB / ADB").bold()
                    Text(model.adbPath.map { "Using \($0)" } ?? "adb not found. Install Android platform-tools (brew install --cask android-platform-tools) or set the path in Preferences. Without adb the app still works over Wi-Fi.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top) {
                Image(systemName: "wifi").foregroundColor(.secondary)
                VStack(alignment: .leading) {
                    Text("USB or Wi-Fi — your choice").bold()
                    Text("Pick the link in the menu bar under “Connect over”: Automatic prefers the cable, Wi-Fi only stays wireless even with the cable plugged in. For Wi-Fi, open the tablet app and keep both devices on the same network. macOS may ask to allow local network access — click Allow.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
            HStack {
                Text(model.permissionsReady ? "✓ You're ready." : "Grant both permissions, then restart One+Connect if macOS asks.")
                    .foregroundColor(model.permissionsReady ? .green : .secondary)
                Spacer()
                Button("Re-check") { model.refreshPermissions(); Core.shared.connection.relocateADB() }
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open System Settings", action: action)
            }
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
