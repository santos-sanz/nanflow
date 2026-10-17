import Foundation

public enum NFLog {
    private static let queue = DispatchQueue(label: "nanflow.log")
    private static var fileURL: URL {
        EnvLoader.appSupportDir().appendingPathComponent("nanflow.log")
    }

    public static func write(_ message: String) {
        queue.async {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let line = "[\(df.string(from: Date()))] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: fileURL)
            }
        }
    }
}
