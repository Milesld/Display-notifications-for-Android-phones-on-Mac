import Foundation

/// Wire protocol shared by the Android app and the macOS receiver.
///
/// A BLE notification is limited to 20 bytes unless an MTU is negotiated, so
/// every JSON message is split into frames:
///
///     byte 0      magic (0x4E, "N")
///     byte 1      flags: 0x01 = start, 0x02 = end
///     bytes 2...3 sequence number, little endian
///     bytes 4...  UTF-8 JSON fragment (at most 16 bytes)
///
/// Keeping the chunk size at 16 bytes avoids depending on MTU negotiation.
public enum NotifyBridgeProtocol {
    public static let serviceUUID = "9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D01"
    public static let txCharacteristicUUID = "9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D02"
    public static let rxCharacteristicUUID = "9F3A6D20-4C1B-4E8A-9F2D-7B5C1A0E6D03"

    /// Default ATT notification payload. The header uses four bytes.
    public static let notificationMTU = 20
    public static let headerSize = 4
    public static let frameMagic: UInt8 = 0x4E
    public static let startFlag: UInt8 = 0x01
    public static let endFlag: UInt8 = 0x02
    public static let maxMessageBytes = 64 * 1024
    public static let protocolVersion = 1
}

/// One JSON object sent over the framed BLE link.
///
/// Notification messages use type == "notification". Pairing/status messages
/// use type == "pair" / "status". Unknown fields are ignored by JSONDecoder.
public struct WireMessage: Codable, Equatable {
    public var v: Int
    public var type: String

    // status / pairing
    public var state: String?
    public var detail: String?
    public var pin: String?
    public var client: String?

    // notification
    public var id: String?
    public var app: String?
    public var pkg: String?
    public var title: String?
    public var text: String?
    public var time: Int64?
    public var category: String?

    public init(
        v: Int = NotifyBridgeProtocol.protocolVersion,
        type: String,
        state: String? = nil,
        detail: String? = nil,
        pin: String? = nil,
        client: String? = nil,
        id: String? = nil,
        app: String? = nil,
        pkg: String? = nil,
        title: String? = nil,
        text: String? = nil,
        time: Int64? = nil,
        category: String? = nil
    ) {
        self.v = v
        self.type = type
        self.state = state
        self.detail = detail
        self.pin = pin
        self.client = client
        self.id = id
        self.app = app
        self.pkg = pkg
        self.title = title
        self.text = text
        self.time = time
        self.category = category
    }

    public var isValid: Bool {
        v == NotifyBridgeProtocol.protocolVersion && !type.isEmpty
    }

    public var isNotification: Bool {
        isValid && type == "notification"
    }
}

public enum BLEFrameCodec {
    /// Encode a JSON payload into BLE notification-sized frames.
    /// The returned frames must be sent in order.
    public static func encode(payload: Data, sequence: UInt16) -> [Data] {
        let chunkSize = NotifyBridgeProtocol.notificationMTU - NotifyBridgeProtocol.headerSize
        precondition(chunkSize > 0)
        precondition(payload.count <= NotifyBridgeProtocol.maxMessageBytes)

        if payload.isEmpty {
            return [frame(flags: NotifyBridgeProtocol.startFlag | NotifyBridgeProtocol.endFlag,
                          sequence: sequence,
                          payload: Data())]
        }

        var frames: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            var flags: UInt8 = 0
            if offset == 0 { flags |= NotifyBridgeProtocol.startFlag }
            if end == payload.count { flags |= NotifyBridgeProtocol.endFlag }
            frames.append(frame(flags: flags, sequence: sequence, payload: chunk))
            offset = end
        }
        return frames
    }

    public static func encodeJSON<T: Encodable>(_ value: T, sequence: UInt16) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let payload = try encoder.encode(value)
        return encode(payload: payload, sequence: sequence)
    }

    private static func frame(flags: UInt8, sequence: UInt16, payload: Data) -> Data {
        var data = Data(capacity: NotifyBridgeProtocol.headerSize + payload.count)
        data.append(NotifyBridgeProtocol.frameMagic)
        data.append(flags)
        data.append(UInt8(sequence & 0xFF))
        data.append(UInt8((sequence >> 8) & 0xFF))
        data.append(payload)
        return data
    }
}

/// Reassembles one ordered stream of frames. BLE guarantees ordered delivery
/// for a subscribed characteristic, so a single buffer is enough.
/// Stable identity advertised in the BLE scan response. Android randomizes its
/// BLE address, so CoreBluetooth's peripheral identifier can change between
/// sessions; this app-level 8-byte ID survives those changes.
public enum NotifyBridgeIdentity {
    public static let manufacturerCompanyID: UInt16 = 0xFFFF
    public static let byteCount = 8
    /// The primary advertising packet cannot hold the 128-bit service UUID and
    /// the full 8-byte identity at once (31-byte limit), and CoreBluetooth does
    /// not reliably merge the scan response into the advertisement dictionary.
    /// Android therefore repeats the first four bytes in the main packet.
    public static let shortByteCount = 4

    public static func parseDeviceID(fromManufacturerData data: Data?) -> String? {
        guard let data else { return nil }
        let payload: Data
        switch data.count {
        case byteCount + 2, shortByteCount + 2:
            let first = data[data.startIndex]
            let second = data[data.startIndex + 1]
            let company = UInt16(first) | (UInt16(second) << 8)
            guard company == manufacturerCompanyID else { return nil }
            payload = data.dropFirst(2)
        case byteCount, shortByteCount:
            // Some stacks (and some macOS builds) hand back the manufacturer
            // payload without the two-byte company identifier.
            payload = data
        default:
            return nil
        }
        return payload.map { String(format: "%02X", $0) }.joined()
    }

    /// True when two identities refer to the same phone. A 4-byte identity from
    /// the main advertising packet is a prefix of the full 8-byte identity
    /// stored at pairing time, so prefix matching keeps auto reconnect working
    /// even if only the short form ever arrives.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.uppercased()
        let b = rhs.uppercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    public static func manufacturerData(fromDeviceID id: String) -> Data? {
        let compact = id.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.count == byteCount * 2 else { return nil }
        var bytes = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        var data = Data([UInt8(manufacturerCompanyID & 0xFF), UInt8((manufacturerCompanyID >> 8) & 0xFF)])
        data.append(bytes)
        return data
    }

    public static func shortSuffix(_ id: String) -> String {
        String(id.suffix(4))
    }

    /// Older Android builds appended the notification post time to the ID.
    /// Stripping it lets a new message update the same macOS notification
    /// instead of leaving the old card behind as a duplicate.
    public static func stableNotificationIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if let range = identifier.range(of: ":[0-9]{13}$", options: .regularExpression) {
            return String(identifier[..<range.lowerBound])
        }
        return identifier
    }
}

public struct BLEFrameReassembler {
    private var buffer = Data()
    private var active = false
    private var sequence: UInt16 = 0

    public init() {}

    /// Returns a complete payload when the end flag is seen, otherwise nil.
    public mutating func ingest(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= NotifyBridgeProtocol.headerSize,
              bytes[0] == NotifyBridgeProtocol.frameMagic else {
            reset()
            return nil
        }

        let flags = bytes[1]
        let frameSequence = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)

        if flags & NotifyBridgeProtocol.startFlag != 0 {
            buffer.removeAll(keepingCapacity: true)
            active = true
            sequence = frameSequence
        }

        guard active, frameSequence == sequence else {
            reset()
            return nil
        }

        buffer.append(contentsOf: bytes.dropFirst(NotifyBridgeProtocol.headerSize))

        if buffer.count > NotifyBridgeProtocol.maxMessageBytes {
            reset()
            return nil
        }

        if flags & NotifyBridgeProtocol.endFlag != 0 {
            let payload = buffer
            reset()
            return payload
        }
        return nil
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        active = false
    }
}
