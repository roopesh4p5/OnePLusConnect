import Foundation

struct QualityPreset: Equatable, Identifiable {
    var id: String { key }
    let key: String
    let title: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int

    static let batterySaver = QualityPreset(key: "battery", title: "Battery Saver", width: 1280, height: 900, fps: 30, bitrate: 6_000_000)
    static let balanced = QualityPreset(key: "balanced", title: "Balanced", width: 1920, height: 1350, fps: 60, bitrate: 16_000_000)
    static let quality = QualityPreset(key: "quality", title: "Quality", width: 2240, height: 1584, fps: 60, bitrate: 30_000_000)
    static let native = QualityPreset(key: "native", title: "Native (sharpest)", width: 2800, height: 1980, fps: 60, bitrate: 60_000_000)
    static let all: [QualityPreset] = [.batterySaver, .balanced, .quality, .native]

    static func named(_ key: String) -> QualityPreset? { all.first { $0.key == key } }
}

enum PinchZoomMode: String, CaseIterable {
    case keyboard   // Cmd+= / Cmd+-
    case off
    var title: String { self == .keyboard ? "Keyboard zoom (⌘+ / ⌘−)" : "Off" }
}

/// UserDefaults-backed preferences. Keys are stable so SwiftUI @AppStorage can share them.
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    enum Key {
        static let mode = "mode"
        static let preset = "quality.preset"
        static let customWidth = "quality.customWidth"
        static let customHeight = "quality.customHeight"
        static let customBitrate = "quality.customBitrate"
        static let fps = "video.fps"
        static let bitrateOverride = "video.bitrateOverride" // 0 = use preset
        static let adbPath = "adb.path"
        static let adbPort = "adb.port"
        static let pinchZoom = "input.pinchZoom"
        static let longPressRightClick = "input.longPressRightClick"
        static let naturalScrolling = "input.naturalScrolling"
        static let scrollSpeed = "input.scrollSpeed"
        static let autoResume = "session.autoResume"
        static let extendHiDPI = "display.hiDPI"
        static let extendUseNativePixels = "display.useNativePixels"
        static let keepDisplayOnReconnect = "display.keepOnReconnect"
        static let showOverlay = "tablet.showOverlay"
        static let wifiEnabled = "wifi.enabled"
        static let wifiManualHost = "wifi.manualHost"
        static let wifiDiscoveryPort = "wifi.discoveryPort"
        static let wifiBitrateCap = "wifi.bitrateCapMbps" // 0 = no cap
    }

    private init() {
        d.register(defaults: [
            Key.mode: SessionMode.mirror.rawValue,
            Key.preset: QualityPreset.native.key,
            Key.customWidth: 1920,
            Key.customHeight: 1350,
            Key.customBitrate: 30_000_000,
            Key.fps: 60,
            Key.bitrateOverride: 0,
            Key.adbPath: "",
            Key.adbPort: 27183,
            Key.pinchZoom: PinchZoomMode.keyboard.rawValue,
            Key.longPressRightClick: true,
            Key.naturalScrolling: true,
            Key.scrollSpeed: 1.0,
            Key.autoResume: true,
            Key.extendHiDPI: true,
            Key.extendUseNativePixels: true,
            Key.keepDisplayOnReconnect: true,
            Key.showOverlay: true,
            Key.wifiEnabled: true,
            Key.wifiManualHost: "",
            Key.wifiDiscoveryPort: 27184,
            Key.wifiBitrateCap: 0,
        ])
    }

    var mode: SessionMode {
        get { SessionMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .mirror }
        set { d.set(newValue.rawValue, forKey: Key.mode) }
    }

    var presetKey: String {
        get { d.string(forKey: Key.preset) ?? QualityPreset.native.key }
        set { d.set(newValue, forKey: Key.preset) }
    }

    /// Effective preset (resolves "custom").
    var preset: QualityPreset {
        if presetKey == "custom" {
            return QualityPreset(key: "custom", title: "Custom", width: max(320, d.integer(forKey: Key.customWidth)), height: max(240, d.integer(forKey: Key.customHeight)), fps: fps, bitrate: max(500_000, d.integer(forKey: Key.customBitrate)))
        }
        return QualityPreset.named(presetKey) ?? .native
    }

    var fps: Int {
        get { let v = d.integer(forKey: Key.fps); return v == 0 ? 60 : v }
        set { d.set(newValue, forKey: Key.fps) }
    }

    var bitrateOverride: Int {
        get { d.integer(forKey: Key.bitrateOverride) }
        set { d.set(newValue, forKey: Key.bitrateOverride) }
    }

    var effectiveBitrate: Int { bitrateOverride > 0 ? bitrateOverride : preset.bitrate }

    var adbPath: String {
        get { d.string(forKey: Key.adbPath) ?? "" }
        set { d.set(newValue, forKey: Key.adbPath) }
    }

    var adbPort: Int {
        get { let v = d.integer(forKey: Key.adbPort); return v == 0 ? 27183 : v }
        set { d.set(newValue, forKey: Key.adbPort) }
    }

    // MARK: Wi-Fi fallback

    /// When no authorized USB tablet is present, connect over the local network instead.
    var wifiEnabled: Bool {
        get { d.bool(forKey: Key.wifiEnabled) }
        set { d.set(newValue, forKey: Key.wifiEnabled) }
    }
    /// Optional "ip" or "ip:port" to use when the discovery beacon cannot cross the network.
    var wifiManualHost: String {
        get { d.string(forKey: Key.wifiManualHost) ?? "" }
        set { d.set(newValue, forKey: Key.wifiManualHost) }
    }
    var wifiDiscoveryPort: Int {
        get { let v = d.integer(forKey: Key.wifiDiscoveryPort); return v == 0 ? 27184 : v }
        set { d.set(newValue, forKey: Key.wifiDiscoveryPort) }
    }
    /// Bitrate ceiling (Mbps) applied on Wi-Fi unless an explicit bitrate override is set. 0 disables the cap.
    var wifiBitrateCapMbps: Int {
        get { d.integer(forKey: Key.wifiBitrateCap) }
        set { d.set(newValue, forKey: Key.wifiBitrateCap) }
    }

    var pinchZoom: PinchZoomMode {
        get { PinchZoomMode(rawValue: d.string(forKey: Key.pinchZoom) ?? "") ?? .keyboard }
        set { d.set(newValue.rawValue, forKey: Key.pinchZoom) }
    }

    var longPressRightClick: Bool { d.bool(forKey: Key.longPressRightClick) }
    var naturalScrolling: Bool { d.bool(forKey: Key.naturalScrolling) }
    var scrollSpeed: Double { let v = d.double(forKey: Key.scrollSpeed); return v <= 0 ? 1.0 : v }
    var autoResume: Bool { d.bool(forKey: Key.autoResume) }
    var extendHiDPI: Bool { d.bool(forKey: Key.extendHiDPI) }
    var extendUseNativePixels: Bool { d.bool(forKey: Key.extendUseNativePixels) }
    var keepDisplayOnReconnect: Bool { d.bool(forKey: Key.keepDisplayOnReconnect) }
}
