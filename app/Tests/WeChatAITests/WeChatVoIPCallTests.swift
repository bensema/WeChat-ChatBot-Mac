import XCTest
@testable import WeChatAI

final class WeChatVoIPCallTests: XCTestCase {
    func testCancelledCallParsesCDATAMessageFromEventJSON() throws {
        let xml = #"<voipmsg type="VoIPBubbleMsg"><VoIPBubbleMsg><msg><![CDATA[对方已取消]]></msg><msg_type>100</msg_type><duration>0</duration></VoIPBubbleMsg></voipmsg>"#
        let event = try XCTUnwrap(JSONSerialization.data(withJSONObject: ["raw_message": xml]))
        let json = try XCTUnwrap(String(data: event, encoding: .utf8))

        XCTAssertEqual(WeChatVoIPCall.parse(json)?.summary, "对方已取消")
    }

    func testCallDurationUsesMMSSAndHHMMSS() throws {
        let short = #"<voipmsg type="VoIPBubbleMsg"><VoIPBubbleMsg><msg></msg><duration>10</duration></VoIPBubbleMsg></voipmsg>"#
        let long = #"<voipmsg type="VoIPBubbleMsg"><VoIPBubbleMsg><duration>3661</duration></VoIPBubbleMsg></voipmsg>"#

        XCTAssertEqual(WeChatVoIPCall.parse(short)?.summary, "通话时长 00:10")
        XCTAssertEqual(WeChatVoIPCall.parse(long)?.summary, "通话时长 1:01:01")
    }

    func testOrdinaryVoIPXMLAndVoiceXMLAreNotCallLogs() {
        XCTAssertNil(WeChatVoIPCall.parse("<voicemsg><voicelength>1000</voicelength></voicemsg>"))
        XCTAssertNil(WeChatVoIPCall.parse("<msg>普通文本</msg>"))
    }

    func testDurationSummaryFromWeChatWhenDurationFieldIsZero() {
        let xml = #"<voipmsg type="VoIPBubbleMsg"><VoIPBubbleMsg><msg><![CDATA[通话时长 00:10]]></msg><duration>0</duration></VoIPBubbleMsg></voipmsg>"#

        XCTAssertEqual(WeChatVoIPCall.parse(xml)?.summary, "通话时长 00:10")
    }

    func testWeChat415CallNotificationIsNormalizedForPreviewAndAI() throws {
        let xml = #"<voipmsg type="VoIPBubbleMsg"><VoIPBubbleMsg><msg><![CDATA[对方已取消]]></msg><msg_type>100</msg_type><duration>0</duration><room_type>1</room_type></VoIPBubbleMsg></voipmsg>"#
        let event = try XCTUnwrap(OneBotEventParser.parseEvent([
            "self_id": "wxid_self",
            "user_id": "wxid_friend",
            "message_id": "call-1",
            "message": [["type": "text", "data": ["text": xml]]],
            "raw_message": xml,
            "time": 1_794_708_793.0
        ], rawText: nil))

        XCTAssertEqual(event.plainText, "对方已取消")
        XCTAssertTrue(event.rawJSON.contains("VoIPBubbleMsg"))
    }
}
