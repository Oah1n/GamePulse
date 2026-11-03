import Foundation

enum DiagnosticLog {
    private static let url = URL(fileURLWithPath: "/tmp/GamePulse-diagnostics.log")

    static func reset() {
        try? Data().write(to: url, options: .atomic)
        write("diagnostics started")
    }

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }
}
