import Foundation
import CryptoKit

/// Network transport constants shared by the direct (LAN / Tailscale) and
/// cloud relay paths. The BLE link keeps its own v1 framing.
public enum NetworkProtocol {
    public static let version = 2
    public static let serviceType = "_notifybridge._tcp"
    public static let defaultDirectPort: UInt16 = 47821
    public static let defaultRelayPort: UInt16 = 443
    public static let maxFrameBytes = 256 * 1024
    public static let cloudVersion = 1
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

/// Registration / delivery / acknowledgement messages on the relay server.
/// Payloads are opaque end-to-end encrypted strings; the server never parses
/// notification content.
public struct CloudRelayMessage: Codable, Equatable {
    public var v: Int
    public var type: String
    public var role: String?
    public var channel: String?
    public var token: String?
    public var name: String?
    public var id: String?
    public var payload: String?
    public var code: String?
    public var message: String?
    public var peer: Bool?
    public var time: Int64?

    public init(
        v: Int = NetworkProtocol.cloudVersion,
        type: String,
        role: String? = nil,
        channel: String? = nil,
        token: String? = nil,
        name: String? = nil,
        id: String? = nil,
        payload: String? = nil,
        code: String? = nil,
        message: String? = nil,
        peer: Bool? = nil,
        time: Int64? = nil
    ) {
        self.v = v
        self.type = type
        self.role = role
        self.channel = channel
        self.token = token
        self.name = name
        self.id = id
        self.payload = payload
        self.code = code
        self.message = message
        self.peer = peer
        self.time = time
    }
}

/// Decrypted content travelling through the relay. Notifications are wrapped
/// so the server only sees a ciphertext blob and a random message id.
public struct CloudEnvelope: Codable, Equatable {
    public var type: String
    public var seq: Int64?
    public var session: String?
    public var data: WireMessage?

    public init(type: String, seq: Int64? = nil, session: String? = nil, data: WireMessage? = nil) {
        self.type = type
        self.seq = seq
        self.session = session
        self.data = data
    }
}

public struct EncryptedPayload: Codable, Equatable {
    public var iv: String
    public var ct: String

    public init(iv: String, ct: String) {
        self.iv = iv
        self.ct = ct
    }
}

/// Derives channel/auth/encryption keys from the 32-byte relay secret shown by
/// the Android app. The auth token and channel id are safe to hand to the relay;
/// the AES key is not.
public enum RelayCrypto {
    private static let salt = Data("NotifyBridge-v1".utf8)

    public static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64URLEncodedString()
    }

    public static func decodeSecret(_ input: String) -> Data? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        guard let data = Data(base64Encoded: value), data.count == 32 else { return nil }
        return data
    }

    public static func derive(_ secret: Data, info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func channel(_ secret: Data) -> String {
        derive(secret, info: "channel", count: 16).map { String(format: "%02x", $0) }.joined()
    }

    public static func token(_ secret: Data) -> String {
        derive(secret, info: "auth", count: 32).base64URLEncodedString()
    }

    public static func encrypt(_ plaintext: String, secret: Data, aad: Data) throws -> String {
        let key = SymmetricKey(data: derive(secret, info: "enc", count: 32))
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce, authenticating: aad)
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        let payload = EncryptedPayload(
            iv: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ct: ciphertext.base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(payload)
        guard let string = String(data: encoded, encoding: .utf8) else {
            throw CryptoError.encoding
        }
        return string
    }

    public static func decrypt(_ payload: String, secret: Data, aad: Data) throws -> String {
        guard let data = payload.data(using: .utf8) else { throw CryptoError.encoding }
        let box = try JSONDecoder().decode(EncryptedPayload.self, from: data)
        guard let iv = Data(base64Encoded: box.iv),
              let combined = Data(base64Encoded: box.ct),
              combined.count > 16 else {
            throw CryptoError.malformedPayload
        }
        let nonce = try AES.GCM.Nonce(data: iv)
        let ciphertext = Data(combined.prefix(combined.count - 16))
        let tag = Data(combined.suffix(16))
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let key = SymmetricKey(data: derive(secret, info: "enc", count: 32))
        let opened = try AES.GCM.open(sealed, using: key, authenticating: aad)
        guard let string = String(data: opened, encoding: .utf8) else {
            throw CryptoError.encoding
        }
        return string
    }

    public enum CryptoError: Error {
        case encoding
        case malformedPayload
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Host[:port] parsing used by both the direct and relay settings.
public struct RelayTarget: Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static func parse(_ raw: String, defaultPort: UInt16) -> RelayTarget? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(String(rest.dropFirst())) : defaultPort
            guard let port, port > 0, !host.isEmpty else { return nil }
            return RelayTarget(host: host, port: port)
        }
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount > 1 {
            return RelayTarget(host: value, port: defaultPort)
        }
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            let portText = String(value[value.index(after: colon)...])
            guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
            return RelayTarget(host: host, port: port)
        }
        return RelayTarget(host: value, port: defaultPort)
    }
}
