import Foundation

enum Log {
    private static let start = Date()
    private static func stamp() -> String {
        String(format: "%8.3f", Date().timeIntervalSince(start))
    }
    static func info(_ msg: @autoclosure () -> String) {
        FileHandle.standardError.write("[\(stamp())] \(msg())\n".data(using: .utf8)!)
    }
    static func error(_ msg: @autoclosure () -> String) {
        FileHandle.standardError.write("[\(stamp())] ERROR: \(msg())\n".data(using: .utf8)!)
    }
}
