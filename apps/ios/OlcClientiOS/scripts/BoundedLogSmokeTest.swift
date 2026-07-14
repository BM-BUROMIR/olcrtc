import Foundation

@main
struct BoundedLogSmokeTest {
    // ai-generated: verifies bounded append rotation and backup replacement.
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("olc-bounded-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tunnel.log")

        BoundedLog.append(Data("12345".utf8), to: file, maxBytes: 8)
        BoundedLog.append(Data("6789".utf8), to: file, maxBytes: 8)
        try check(try String(contentsOf: file, encoding: .utf8) == "123456789", "line completing the limit should remain")

        BoundedLog.append(Data("x".utf8), to: file, maxBytes: 8)
        let backup = file.appendingPathExtension("1")
        try check(try String(contentsOf: file, encoding: .utf8) == "x", "new log should start after rotation")
        try check(try String(contentsOf: backup, encoding: .utf8) == "123456789", "previous log should be retained once")

        BoundedLog.append(Data("yyyyyyyy".utf8), to: file, maxBytes: 8)
        BoundedLog.append(Data("z".utf8), to: file, maxBytes: 8)
        try check(try String(contentsOf: backup, encoding: .utf8) == "xyyyyyyyy", "backup should be replaced on next rotation")
        try check(try String(contentsOf: file, encoding: .utf8) == "z", "current log should remain bounded")

        print("BoundedLogSmokeTest passed")
    }

    // ai-generated: reports a focused bounded-log smoke-test assertion failure.
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
