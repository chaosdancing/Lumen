import Foundation

/// 极简文件日志：写到容器的 Application Support/Lumen/lumen.log
/// 沙盒应用跑不了 `log show`，出问题时靠这个文件定位。
enum AppLog {
    private static let queue = DispatchQueue(label: "com.example.lumen.log")
    private static let maxBytes = 512 * 1024

    static var fileURL: URL { StorePaths.root.appendingPathComponent("lumen.log") }

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERR ", message) }

    static func write(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        queue.async {
            let url = fileURL
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

extension Error {
    /// 把 URLError / NSError 的细节摊平，便于贴到日志里
    var logDescription: String {
        let ns = self as NSError
        var s = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] {
            s += " url=\(url)"
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " | underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)"
        }
        return s
    }
}
