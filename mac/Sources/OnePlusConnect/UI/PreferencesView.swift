import SwiftUI

struct PreferencesView: View {
    @AppStorage(Preferences.Key.mode) private var mode = SessionMode.mirror.rawValue
    @AppStorage(Preferences.Key.preset) private var preset = QualityPreset.native.key
    @AppStorage(Preferences.Key.customWidth) private var customWidth = 1920
    @AppStorage(Preferences.Key.customHeight) private var customHeight = 1350
    @AppStorage(Preferences.Key.customBitrate) private var customBitrate = 30_000_000
    @AppStorage(Preferences.Key.fps) private var fps = 60
    @AppStorage(Preferences.Key.adbPath) private var adbPath = ""
    @AppStorage(Preferences.Key.adbPort) private var adbPort = 27183
    @AppStorage(Preferences.Key.pinchZoom) private var pinchZoom = PinchZoomMode.keyboard.rawValue
    @AppStorage(Preferences.Key.longPressRightClick) private var longPressRightClick = true
    @AppStorage(Preferences.Key.naturalScrolling) private var naturalScrolling = true
    @AppStorage(Preferences.Key.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Preferences.Key.autoResume) private var autoResume = true
    @AppStorage(Preferences.Key.extendHiDPI) private var hiDPI = true
    @AppStorage(Preferences.Key.extendUseNativePixels) private var useNativePixels = true
    @AppStorage(Preferences.Key.keepDisplayOnReconnect) private var keepDisplay = true
    @AppStorage(Preferences.Key.linkMode) private var linkMode = LinkMode.auto.rawValue
    @AppStorage(Preferences.Key.codec) private var codec = VideoCodecChoice.auto.rawValue
    @AppStorage(Preferences.Key.adaptiveBitrate) private var adaptiveBitrate = true
    @AppStorage(Preferences.Key.wifiManualHost) private var wifiManualHost = ""
    @AppStorage(Preferences.Key.wifiDiscoveryPort) private var wifiDiscoveryPort = 27184
    @AppStorage(Preferences.Key.wifiBitrateCap) private var wifiBitrateCap = 0

    var body: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: $mode) {
                    ForEach(SessionMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("HiDPI (Retina) virtual display", isOn: $hiDPI)
                Toggle("Offer the tablet's native pixel size as a display mode", isOn: $useNativePixels)
                Toggle("Keep the virtual display for 30 s while reconnecting", isOn: $keepDisplay)
                Text("Extended mode uses a private macOS API and is experimental. Mirror mode needs no virtual display.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Video") {
                Picker("Quality", selection: $preset) {
                    ForEach(QualityPreset.all) { Text("\($0.title) — \($0.width)×\($0.height)").tag($0.key) }
                    Text("Custom").tag("custom")
                }
                if preset == "custom" {
                    HStack {
                        TextField("Width", value: $customWidth, format: .number)
                        Text("×")
                        TextField("Height", value: $customHeight, format: .number)
                    }
                    TextField("Bitrate (bps)", value: $customBitrate, format: .number)
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                Picker("Codec", selection: $codec) {
                    ForEach(VideoCodecChoice.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Adapt the bitrate when the link cannot keep up", isOn: $adaptiveBitrate)
                Text("HEVC carries the same picture in roughly half the bits of H.264, which is what keeps a Wi-Fi link as sharp as the cable. Adaptive bitrate lowers quality briefly instead of dropping whole frames.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Input") {
                Toggle("Long press → right click", isOn: $longPressRightClick)
                Toggle("Natural scrolling", isOn: $naturalScrolling)
                Slider(value: $scrollSpeed, in: 0.25...3, step: 0.25) { Text("Scroll speed \(scrollSpeed, specifier: "%.2f")×") }
                Picker("Pinch gesture", selection: $pinchZoom) {
                    ForEach(PinchZoomMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section("Connection") {
                Picker("Connect over", selection: $linkMode) {
                    ForEach(LinkMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                TextField("adb path (blank = auto-detect)", text: $adbPath)
                TextField("Port", value: $adbPort, format: .number)
                Toggle("Resume sharing automatically after reconnect", isOn: $autoResume)
                Button("Re-detect adb") { Core.shared.connection.relocateADB() }
                Text("This is a choice, not a fallback: “Wi-Fi only” keeps streaming wirelessly even while the cable is plugged in, and switching here takes effect immediately.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Wi-Fi") {
                TextField("Tablet address (optional, e.g. 192.168.1.20 or 192.168.1.20:27183)", text: $wifiManualHost)
                    .disabled(linkMode == LinkMode.usb.rawValue)
                TextField("Discovery port (UDP)", value: $wifiDiscoveryPort, format: .number)
                    .disabled(linkMode == LinkMode.usb.rawValue)
                Picker("Bitrate cap on Wi-Fi", selection: $wifiBitrateCap) {
                    Text("None").tag(0)
                    Text("8 Mbps").tag(8)
                    Text("12 Mbps").tag(12)
                    Text("16 Mbps").tag(16)
                    Text("30 Mbps").tag(30)
                    Text("50 Mbps").tag(50)
                }
                .disabled(linkMode == LinkMode.usb.rawValue)
                Text("The tablet app announces itself on the local network; leave the address blank unless your router blocks broadcasts. A manual address is used even without a beacon. Leave the cap at None for the sharpest wireless picture — adaptive bitrate already backs off when the network cannot keep up.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(minWidth: 480, minHeight: 620)
        .onChange(of: mode) { _, _ in Core.shared.session.applyPreferencesChange() }
        .onChange(of: preset) { _, _ in Core.shared.session.applyPreferencesChange() }
        .onChange(of: fps) { _, _ in Core.shared.session.applyPreferencesChange() }
        .onChange(of: longPressRightClick) { _, _ in Core.shared.input.refreshPreferences() }
        .onChange(of: pinchZoom) { _, _ in Core.shared.input.refreshPreferences() }
        .onChange(of: codec) { _, _ in Core.shared.session.applyPreferencesChange() }
        .onChange(of: linkMode) { _, _ in Core.shared.connection.refreshLinkPreferences() }
        .onChange(of: wifiManualHost) { _, _ in Core.shared.connection.refreshLinkPreferences() }
        .onChange(of: wifiDiscoveryPort) { _, _ in Core.shared.connection.refreshLinkPreferences() }
    }
}
