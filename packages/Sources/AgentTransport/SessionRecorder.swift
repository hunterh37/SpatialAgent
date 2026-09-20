import Foundation

/// Writes raw frames to a `.jsonl` file so a bug seen once in the headset becomes a fixture
/// that reproduces on anyone's laptop (docs/architecture.md §6):
///
///     fake_headset.py --replay session.jsonl
///
/// Records the wire, not the render. Nothing here contains camera frames or raw scene
/// reconstructions — only the abstracted messages already sent over the LAN (spec/05-scene.md).
public final class SessionRecorder: @unchecked Sendable {
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "io.medvr.SpatialAgent.recorder")
    public let url: URL

    public init?(directory: URL? = nil, name: String = ISO8601DateFormatter().string(from: .now)) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        let sanitized = name.replacingOccurrences(of: ":", with: "-")
        url = dir.appendingPathComponent("session-\(sanitized).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        if handle == nil { return nil }
    }

    public func record(outbound line: String) { write(direction: "out", line: line) }
    public func record(inbound line: String) { write(direction: "in", line: line) }

    private func write(direction: String, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = #"{"dir":"\#(direction)","t":\#(Date().timeIntervalSince1970),"frame":\#(trimmed)}"# + "\n"
        queue.async { [handle] in try? handle?.write(contentsOf: Data(entry.utf8)) }
    }

    public func close() {
        queue.sync { try? handle?.close() }
    }
}
