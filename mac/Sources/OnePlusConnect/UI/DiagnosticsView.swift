import SwiftUI

/// Live pipeline metrics and the local log (PRD §63/§64).
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title3).bold()
            let d = model.diagnostics
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Link", model.connection.device.map { "\($0.linkDescription) — \(model.connection.isReady ? "✓ Connected" : model.connection.shortTitle)" } ?? model.connection.shortTitle)
                row("Transport", d.transportConnected ? "✓ Stable (RTT \(fmt(d.rttMs)) ms)" : "—")
                row("Session", model.session.title + (model.lastError.map { " — \($0)" } ?? ""))
                row("Stream", d.streamSize.isEmpty ? "—" : "\(d.streamSize) fps · \(fmt(d.bitrateMbps)) Mbps target")
                row("Throughput", "\(fmt(d.throughputMbps)) Mbps")
                row("Video", "capture \(fmt(d.captureFps, 0)) fps · encode \(fmt(d.encodeFps, 0)) fps · tablet \(fmt(d.tabletFps, 0)) fps")
                row("Encode latency", "\(fmt(d.encodeLatencyMs)) ms")
                row("Decode latency", "\(fmt(d.decodeLatencyMs)) ms")
                row("Dropped frames", "\(fmt(d.droppedPercent)) % (Mac \(d.droppedOnMac), tablet \(d.droppedOnTablet))")
                row("Input latency", "\(fmt(d.inputLatencyMs)) ms")
                row("Session latency", "\(fmt(d.sessionLatencyMs)) ms (capture → tablet render)")
                row("Send backlog", "\(d.pendingBytes / 1024) KB")
                row("Tablet", "\(d.battery.map { "Battery \($0)%" } ?? "Battery —") · thermal \(d.thermal ?? "—")")
            }
            .font(.system(.body, design: .monospaced))

            Divider()
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logLines) { entry in
                            Text(entry.line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(for: entry.level))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logLines.count) { _, _ in
                    if let last = model.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 560)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundColor(.secondary)
            Text(v)
        }
    }

    private func fmt(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v)
    }

    private func color(for level: Log.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
