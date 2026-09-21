import Foundation

/// Newline-delimited JSON framing (spec/03-protocol.md).
///
/// Both ends validate at the boundary. Unknown message types decode to `nil` rather than
/// throwing, so the server can add an event type without breaking shipped headsets.
public enum WireCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder = JSONDecoder()

    public static func encode(_ message: ClientMessage) throws -> String {
        String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    public static func encode(_ event: ServerEvent) throws -> String {
        String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    /// Returns `nil` for a well-formed frame carrying an unknown `type`.
    /// Throws only when the frame is not decodable JSON of a known shape.
    public static func decodeEvent(_ text: String) throws -> ServerEvent? {
        do {
            return try decoder.decode(ServerEvent.self, from: Data(text.utf8))
        } catch WireError.unknownMessageType {
            return nil
        } catch let DecodingError.dataCorrupted(ctx) where ctx.underlyingError is WireError {
            return nil
        }
    }

    public static func decodeClientMessage(_ text: String) throws -> ClientMessage? {
        do {
            return try decoder.decode(ClientMessage.self, from: Data(text.utf8))
        } catch WireError.unknownMessageType {
            return nil
        } catch let DecodingError.dataCorrupted(ctx) where ctx.underlyingError is WireError {
            return nil
        }
    }

    /// Splits a byte buffer on newlines, returning complete frames and the unconsumed tail.
    public static func frames(from buffer: inout String) -> [String] {
        var out: [String] = []
        while let idx = buffer.firstIndex(of: "\n") {
            let frame = String(buffer[buffer.startIndex..<idx])
            buffer = String(buffer[buffer.index(after: idx)...])
            let trimmed = frame.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }
}
