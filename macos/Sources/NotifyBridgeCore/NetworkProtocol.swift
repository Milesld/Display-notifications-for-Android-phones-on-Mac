import Foundation

/// Network transport constants for the direct Wi-Fi/LAN path. The BLE link
/// keeps its own v1 framing.
public enum NetworkProtocol {
    public static let version = 2
    public static let serviceType = "_notifybridge._tcp"
    public static let defaultDirectPort: UInt16 = 47821
    public static let maxFrameBytes = 256 * 1024
}

/// One length-prefixed JSON message on a TCP stream.
///
///     uint32 big-endian length
///     length bytes UTF-8 JSON
public enum TCPFrameCodec {
    public static func encode(_ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }

    public static func encode(_ json: String) -> Data? {
        guard let payload = json.data(using: .utf8) else { return nil }
        return encode(payload)
    }

    /// Appends bytes to a receive buffer and returns every complete frame.
    /// A corrupt length prefix clears the buffer; the caller should reconnect.
    public static func append(_ data: Data, to buffer: inout Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer)
            let length = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            guard length > 0, length <= UInt32(NetworkProtocol.maxFrameBytes) else {
                buffer.removeAll(keepingCapacity: true)
                return frames
            }
            let total = 4 + Int(length)
            if bytes.count < total { break }
            frames.append(Data(bytes[4..<total]))
            // Rebuild instead of removeFirst: Data slices can keep a
            // non-zero startIndex, which made subdata(in:) crash.
            buffer = Data(bytes[total...])
        }
        return frames
    }
}

/// JSON envelope used by the direct TCP transport. Unknown fields are ignored.
public struct NetworkMessage: Codable, Equatable {
    public var v: Int
    public var type: String

    // hello / status
    public var state: String?
    public var detail: String?
    public var reason: String?
    public var deviceId: String?
    public var name: String?
    public var session: String?
    public var notifications: String?

    // auth
    public var pin: String?
    public var clientName: String?
    public var since: Int64?

    // auth_ok / notification
    public var head: Int64?
    public var seq: Int64?
    public var time: Int64?
    public var data: WireMessage?

    public init(
        v: Int = NetworkProtocol.version,
        type: String,
        state: String? = nil,
        detail: String? = nil,
        reason: String? = nil,
        deviceId: String? = nil,
        name: String? = nil,
        session: String? = nil,
        notifications: String? = nil,
        pin: String? = nil,
        clientName: String? = nil,
        since: Int64? = nil,
        head: Int64? = nil,
        seq: Int64? = nil,
        time: Int64? = nil,
        data: WireMessage? = nil
    ) {
        self.v = v
        self.type = type
        self.state = state
        self.detail = detail
        self.reason = reason
        self.deviceId = deviceId
        self.name = name
        self.session = session
        self.notifications = notifications
        self.pin = pin
        self.clientName = clientName
        self.since = since
        self.head = head
        self.seq = seq
        self.time = time
        self.data = data
    }

    public var isValid: Bool {
        v == NetworkProtocol.version && !type.isEmpty
    }
}
