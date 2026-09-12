import Foundation

struct ADBDevice: Equatable {
    enum State: String { case device, unauthorized, offline, other }
    let serial: String
    let state: State
    let model: String?

    var displayName: String {
        if let m = model { return m.replacingOccurrences(of: "_", with: " ") }
        return serial
    }
}

enum ADBError: LocalizedError {
    case notFound
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notFound: return "adb was not found. Install Android platform-tools or set the adb path in Preferences."
        case .failed(let m): return "adb failed: \(m)"
        case .timeout: return "adb timed out"
        }
    }
}

/// Thin wrapper around the `adb` binary.
final class ADB {
    private(set) var path: String

    init(path: String) { self.path = path }

    /// Finds adb: explicit preference, PATH via login shell, then common SDK locations.
    static func locate(preferred: String) -> String? {
        let fm = FileManager.default
        if !preferred.isEmpty, fm.isExecutableFile(atPath: preferred) { return preferred }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }

        // Ask the user's login shell (picks up PATH additions from .zprofile/.zshrc).
        if let out = try? runProcess("/bin/zsh", ["-lc", "command -v adb"], timeout: 5),
           out.status == 0 {
            let p = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func devices() throws -> [ADBDevice] {
        let out = try ADB.runProcess(path, ["devices", "-l"], timeout: 8)
        guard out.status == 0 else { throw ADBError.failed(out.stderr.isEmpty ? out.stdout : out.stderr) }
        var result: [ADBDevice] = []
        for line in out.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = ADBDevice.State(rawValue: parts[1]) ?? .other
            var model: String?
            for p in parts.dropFirst(2) where p.hasPrefix("model:") {
                model = String(p.dropFirst("model:".count))
            }
            result.append(ADBDevice(serial: serial, state: state, model: model))
        }
        return result
    }

    func forward(serial: String, localPort: Int, remotePort: Int) throws {
        let out = try ADB.runProcess(path, ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(remotePort)"], timeout: 8)
        guard out.status == 0 else { throw ADBError.failed(out.stderr.isEmpty ? out.stdout : out.stderr) }
    }

    func removeForward(localPort: Int) {
        _ = try? ADB.runProcess(path, ["forward", "--remove", "tcp:\(localPort)"], timeout: 5)
    }

    func getProp(serial: String, _ prop: String) -> String? {
        guard let out = try? ADB.runProcess(path, ["-s", serial, "shell", "getprop", prop], timeout: 5), out.status == 0 else { return nil }
        let v = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    struct ProcessResult { let status: Int32; let stdout: String; let stderr: String }

    @discardableResult
    static func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        p.environment = env
        try p.run()

        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            throw ADBError.timeout
        }
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus,
                             stdout: String(data: outData, encoding: .utf8) ?? "",
                             stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
