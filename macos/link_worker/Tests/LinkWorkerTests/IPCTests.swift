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

    func testProductionServerOfferDecodingWithoutRootSessionId() throws {
        // Real 2FA server sends {"type":"session_offer","payload":{...}} WITHOUT session_id at root
        let json = """
        {
            "type": "session_offer",
            "payload": {
                "session_id": "prod-session-456",
                "operator_id": "oper-789",
                "operator_name": "Support Agent",
                "access_type": "attended",
                "access_mode": "control",
                "desktop_scope": "interactive",
                "sdp": "v=0\\r\\no=- 999 888 IN IP4 127.0.0.1\\r\\n",
                "ice_servers": [
                    {"urls": "stun:stun.l.google.com:19302"},
                    {"urls": ["turn:turn.example.com:3478"], "username": "user", "credential": null}
                ],
                "confirmation_required": true,
                "confirmation_digits": 2
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SessionOfferEnvelope.self, from: json)
        XCTAssertEqual(envelope.type, "session_offer")
        XCTAssertEqual(envelope.effectiveSessionId, "prod-session-456")
        XCTAssertEqual(envelope.payload.sessionId, "prod-session-456")
        XCTAssertEqual(envelope.payload.operatorName, "Support Agent")
        XCTAssertEqual(envelope.payload.accessMode, "control")
        XCTAssertEqual(envelope.payload.iceServers?.count, 2)
    }
}
