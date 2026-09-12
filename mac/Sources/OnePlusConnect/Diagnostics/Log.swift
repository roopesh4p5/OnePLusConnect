import Foundation

/// Local-only log: ring buffer for the Diagnostics window + a file under ~/Library/Logs/OnePlusConnect.
final class Log {
    static let shared = Log()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
        var line: String {
            "\(Log.timeFormatter.string(from: date)) \(level.tag) \(message)"
        }
    }

    enum Level: String {
        case debug, info, warn, error
        var tag: String {
            switch self {
            case .debug: return "[D]"
            case .info: return "[I]"
            case .warn: return "[W]"
            case .error: return "[E]"
            }
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let queue = DispatchQueue(label: "oneplusconnect.log")
    private var entries: [Entry] = []
    private let maxEntries = 2000
    private var fileHandle: FileHandle?
    var onAppend: ((Entry) -> Void)?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OnePlusConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("oneplusconnect.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: file)
        try? fileHandle?.seekToEnd()
    }

    func debug(_ m: String) { append(.debug, m) }
    func info(_ m: String) { append(.info, m) }
    func warn(_ m: String) { append(.warn, m) }
    func error(_ m: String) { append(.error, m) }

    private func append(_ level: Level, _ message: String) {
        let entry = Entry(date: Date(), level: level, message: message)
        queue.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries { self.entries.removeFirst(self.entries.count - self.maxEntries) }
            let line = entry.line + "\n"
            print(line, terminator: "")
            if let data = line.data(using: .utf8) { try? self.fileHandle?.write(contentsOf: data) }
            self.onAppend?(entry)
        }
    }

    func snapshot() -> [Entry] {
        queue.sync { entries }
    }
}
