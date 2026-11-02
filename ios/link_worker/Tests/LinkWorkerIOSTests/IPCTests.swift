import XCTest
@testable import LinkWorkerIOS

final class IPCTests: XCTestCase {
    func testModelEncodingDecoding() throws {
        let json = """
        {
            "type": "session_offer",
            "session_id": "test-session-ios",
            "payload": {
                "session_id": "test-session-ios",
                "sdp": "v=0\\r\\no=- 123 456 IN IP4 127.0.0.1\\r\\n",
                "access_mode": "view_only",
                "access_type": "attended"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SessionOfferEnvelope.self, from: json)
        let offer = envelope.payload
        XCTAssertEqual(envelope.type, "session_offer")
        XCTAssertEqual(offer.sessionId, "test-session-ios")
        XCTAssertEqual(offer.accessMode, "view_only")

        let answer = SessionAnswerEnvelope(sessionId: "test-session-ios", accepted: true, sdp: "v=0\\r\\n")
        let encoder = JSONEncoder()
        let answerData = try encoder.encode(answer)
        let answerJson = String(data: answerData, encoding: .utf8)!
        XCTAssertTrue(answerJson.contains("\"type\":\"session_answer\""))
        XCTAssertTrue(answerJson.contains("\"accepted\":true"))
    }
}
