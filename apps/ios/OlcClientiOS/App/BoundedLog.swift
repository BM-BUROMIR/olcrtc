import Foundation

enum BoundedLog {
    private static let lock = NSLock()

    // ai-generated: appends diagnostic data while retaining one bounded previous file.
    static func append(_ data: Data, to file: URL, maxBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        try? rotateIfNeededUnlocked(file, maxBytes: maxBytes)
        if let handle = try? FileHandle(forWritingTo: file) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }

    // ai-generated: rotates an externally written diagnostic file before reopening it.
    static func rotateIfNeeded(_ file: URL, maxBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        try? rotateIfNeededUnlocked(file, maxBytes: maxBytes)
    }

    // ai-generated: performs one locked size check and backup replacement.
    private static func rotateIfNeededUnlocked(_ file: URL, maxBytes: UInt64) throws {
        guard maxBytes > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maxBytes else {
            return
        }
        let backup = file.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: file, to: backup)
    }
}
