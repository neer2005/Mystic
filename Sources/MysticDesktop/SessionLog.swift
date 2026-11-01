import Foundation
import MysticKit

/// The persistent session log, as Nightjar's desktop `logfile.rs` keeps it: every line of the
/// session log, timestamped in UTC and redacted with Nightjar's rules (PC names and addresses,
/// IDs, keys and PINs) before it reaches the file. A launch moves `mystic.log` to
/// `mystic.prev.log`, so the last two runs are kept; a run past 4 MiB rotates the same way, so
/// the folder stays under twice that. Writes happen on their own queue and never wait on the UI.
final class SessionLog: @unchecked Sendable {
    static let cap: UInt64=4*1024*1024
    static let current="mystic.log",previous="mystic.prev.log"
    /// `~/Library/Logs/Mystic`, where Console finds it too.
    static var defaultFolder: URL {
        FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Logs/Mystic",isDirectory:true)
    }
    let folder: URL
    var file: URL { folder.appendingPathComponent(Self.current) }
    private let queue=DispatchQueue(label:"Mystic.SessionLog")
    private var handle: FileHandle?
    private var written: UInt64=0
    private let now: @Sendable () -> Date

    init(folder: URL = SessionLog.defaultFolder,now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder=folder;self.now=now
        queue.async { [self] in rotate() }
    }
    deinit { try? handle?.close() }
    /// Keeps a PC's names and addresses out of the file from now on.
    static func addSecrets(_ secrets: [String?]) { for case let secret? in secrets { Redaction.addSecret(secret) } }

    func write(_ line: String) {
        let stamp=Self.stamp(now())
        // Redaction runs here so a name added as a secret before this line is hidden in it.
        let text=line.split(separator:"\n",omittingEmptySubsequences:false).map { "\(stamp) \(Redaction.scrub(String($0)))\n" }.joined()
        queue.async { [self] in append(Data(text.utf8)) }
    }
    /// Waits for every line written so far; for tests.
    func flush() { queue.sync {} }

    private func append(_ data: Data) {
        if written >= Self.cap { rotate() }
        guard let handle else { return }
        do { try handle.write(contentsOf:data);written+=UInt64(data.count) } catch { try? handle.close();self.handle=nil }
    }
    private func rotate() {
        try? handle?.close();handle=nil;written=0
        let manager=FileManager.default
        do {
            try manager.createDirectory(at:folder,withIntermediateDirectories:true)
            let previous=folder.appendingPathComponent(Self.previous)
            if manager.fileExists(atPath:file.path) {
                try? manager.removeItem(at:previous)
                try manager.moveItem(at:file,to:previous)
            }
            guard manager.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else { return }
            handle=try FileHandle(forWritingTo:file)
        } catch { handle=nil }
    }
    /// `2026-11-01T10:11:40.123Z`.
    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds:true,timeZone:.gmt))
    }
}
