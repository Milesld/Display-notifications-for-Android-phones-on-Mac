import Foundation
import Darwin
import NotifyBridgeCore

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("  ok  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

print("NotifyBridge protocol self-tests")

do {
    let payload = Data("hello".utf8)
    let frames = BLEFrameCodec.encode(payload: payload, sequence: 7)
    check(frames.count == 1, "short payload uses one frame")
    check(frames[0].count == 4 + payload.count, "frame length")
    check(frames[0][0] == NotifyBridgeProtocol.frameMagic, "magic byte")
    check(frames[0][1] == NotifyBridgeProtocol.startFlag | NotifyBridgeProtocol.endFlag, "start+end flags")
    var reassembler = BLEFrameReassembler()
    check(reassembler.ingest(frames[0]) == payload, "short payload reassembles")
}

do {
    let original = String(repeating: "微信消息：今晚一起吃饭吗？🍜 ", count: 80)
    let payload = Data(original.utf8)
    let frames = BLEFrameCodec.encode(payload: payload, sequence: 42)
    check(frames.count > 1, "long payload uses multiple frames")
    check(frames.allSatisfy { $0.count <= NotifyBridgeProtocol.notificationMTU }, "all frames fit 20 bytes")
    check(frames.first?[1] == NotifyBridgeProtocol.startFlag, "first frame starts")
    check(frames.last?[1] == NotifyBridgeProtocol.endFlag, "last frame ends")
    var reassembler = BLEFrameReassembler()
    var result: Data?
    for frame in frames {
        if let complete = reassembler.ingest(frame) { result = complete }
    }
    check(result == payload, "long UTF-8 payload round-trips")
    check(String(data: result ?? Data(), encoding: .utf8) == original, "UTF-8 text is preserved")
}

do {
    let frames = BLEFrameCodec.encode(payload: Data(), sequence: 1)
    check(frames.count == 1, "empty payload uses one frame")
    var reassembler = BLEFrameReassembler()
    check(reassembler.ingest(frames[0]) == Data(), "empty payload reassembles")
}

do {
    let frames = BLEFrameCodec.encode(payload: Data(repeating: 0x41, count: 40), sequence: 9)
    check(frames.count > 1, "sequence test payload uses multiple frames")
    var reassembler = BLEFrameReassembler()
    _ = reassembler.ingest(frames[0])
    var badFirst = frames[0]
    badFirst[2] = 10
    _ = reassembler.ingest(badFirst)
    check(reassembler.ingest(frames[1]) == nil, "sequence mismatch is discarded")
}

do {
    var bogus = Data([0x00, 0x03, 0x01, 0x00])
    bogus.append(Data("x".utf8))
    var reassembler = BLEFrameReassembler()
    check(reassembler.ingest(bogus) == nil, "invalid magic is ignored")
}

do {
    let original = WireMessage(
        type: "notification",
        id: "com.tencent.mm:42",
        app: "微信",
        pkg: "com.tencent.mm",
        title: "张三",
        text: "晚上吃饭吗？",
        time: 1_700_000_000_000,
        category: "msg"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
    check(decoded == original, "WireMessage JSON round-trip")
    check(decoded.isNotification, "notification type")
}

do {
    let deviceID = "0123456789ABCDEF"
    if let data = NotifyBridgeIdentity.manufacturerData(fromDeviceID: deviceID) {
        check(data.count == 10, "identity manufacturer data length")
        check(data[0] == 0xFF && data[1] == 0xFF, "identity company ID")
        check(NotifyBridgeIdentity.parseDeviceID(fromManufacturerData: data) == deviceID, "identity round-trip")
        check(NotifyBridgeIdentity.shortSuffix(deviceID) == "CDEF", "identity short suffix")

        var wrongCompany = data
        wrongCompany[0] = 0x00
        check(NotifyBridgeIdentity.parseDeviceID(fromManufacturerData: wrongCompany) == nil, "wrong company rejected")
        check(NotifyBridgeIdentity.parseDeviceID(fromManufacturerData: Data([0xFF])) == nil, "short data rejected")
    } else {
        check(false, "identity manufacturer data")
    }

    check(
        NotifyBridgeIdentity.stableNotificationIdentifier("0|com.tencent.mm|123|null|10123:1700000000000")
            == "0|com.tencent.mm|123|null|10123",
        "legacy notification ID is normalized"
    )
    check(NotifyBridgeIdentity.stableNotificationIdentifier("0|com.tencent.mm|123") == "0|com.tencent.mm|123", "current ID is preserved")
    check(NotifyBridgeIdentity.stableNotificationIdentifier("key:123") == "key:123", "short numeric tag is preserved")
    check(NotifyBridgeIdentity.stableNotificationIdentifier(nil) == nil, "nil notification ID")
}

do {
    let androidJSON = #"{"v":1,"type":"notification","id":"0|com.tencent.mm|12345|null|10123:1700000000000","app":"微信","pkg":"com.tencent.mm","time":1700000000000,"title":"张三","text":"晚上吃饭吗？","category":"msg"}"#
    let message = try JSONDecoder().decode(WireMessage.self, from: Data(androidJSON.utf8))
    check(message.isNotification, "Android notification JSON decodes")
    check(message.app == "微信", "Android app label decodes")
    check(message.text == "晚上吃饭吗？", "Android message text decodes")
    check(message.time == 1_700_000_000_000, "Android timestamp decodes")
}

do {
    let data = Data(#"{"v":1,"type":"pair","pin":"123456","client":"notifybridge-macos"}"#.utf8)
    let message = try JSONDecoder().decode(WireMessage.self, from: data)
    check(message.pin == "123456", "pairing PIN decodes")
    check(message.client == "notifybridge-macos", "pairing client decodes")
    check(!message.isNotification, "pairing is not a notification")
}

do {
    let message = WireMessage(
        type: "notification",
        id: "id-1",
        app: "信息",
        pkg: "com.android.mms",
        title: "李四",
        text: String(repeating: "这是一条较长的测试短信。", count: 40),
        time: 1_700_000_000_000,
        category: "msg"
    )
    let frames = try BLEFrameCodec.encodeJSON(message, sequence: 3)
    var reassembler = BLEFrameReassembler()
    var payload: Data?
    for frame in frames {
        if let complete = reassembler.ingest(frame) { payload = complete }
    }
    if let payload {
        let decoded = try JSONDecoder().decode(WireMessage.self, from: payload)
        check(decoded == message, "framed JSON round-trip")
    } else {
        check(false, "framed JSON round-trip")
    }
}

if failures == 0 {
    print("All protocol self-tests passed.")
    exit(0)
} else {
    print("\(failures) test(s) failed.")
    exit(1)
}
