import XCTest
@testable import LinkWorker

final class IPCTests: XCTestCase {
    func testModelEncodingDecoding() throws {
        let json = """
        {
            "type": "session_offer",
            "session_id": "test-session-123",
            "payload": {
                "session_id": "test-session-123",
                "sdp": "v=0\\r\\no=- 123 456 IN IP4 127.0.0.1\\r\\n",
                "access_mode": "control",
                "access_type": "unattended",
                "confirmation_digits": 4,
                "recording": {
                    "enabled": true,
                    "ingest_url": "https://example.com/record"
                }
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SessionOfferEnvelope.self, from: json)
        let offer = envelope.payload
        XCTAssertEqual(envelope.type, "session_offer")
        XCTAssertEqual(offer.sessionId, "test-session-123")
        XCTAssertEqual(offer.accessMode, "control")
        XCTAssertEqual(offer.accessType, "unattended")
        XCTAssertEqual(offer.recording?.enabled, true)
        XCTAssertEqual(offer.recording?.ingestUrl, "https://example.com/record")

        let answer = SessionAnswerEnvelope(sessionId: "test-session-123", accepted: true, sdp: "v=0\\r\\n")
        let encoder = JSONEncoder()
        let answerData = try encoder.encode(answer)
        let answerJson = String(data: answerData, encoding: .utf8)!
        XCTAssertTrue(answerJson.contains("\"type\":\"session_answer\""))
        XCTAssertTrue(answerJson.contains("\"accepted\":true"))
        XCTAssertTrue(answerJson.contains("\"payload\":{"))

        let term = SessionTerminateEnvelope(sessionId: "test-session-123", reason: "peer_failed")
        let termData = try encoder.encode(term)
        let termJson = String(data: termData, encoding: .utf8)!
        XCTAssertTrue(termJson.contains("\"type\":\"session_terminate\""))
        XCTAssertTrue(termJson.contains("\"reason\":\"peer_failed\""))
    }
}
