import Foundation

public struct SessionOfferEnvelope: Codable {
    public let type: String?
    public let sessionId: String?
    public let payload: SessionOfferPayload

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case payload
    }

    public init(type: String? = "session_offer", sessionId: String? = nil, payload: SessionOfferPayload) {
        self.type = type
        self.sessionId = sessionId
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try? container.decode(String.self, forKey: .type)
        self.sessionId = try? container.decode(String.self, forKey: .sessionId)
        if let p = try? container.decode(SessionOfferPayload.self, forKey: .payload) {
            self.payload = p
        } else {
            self.payload = try SessionOfferPayload(from: decoder)
        }
    }

    public var effectiveSessionId: String {
        if let s = sessionId, !s.isEmpty {
            return s
        }
        return payload.sessionId ?? ""
    }
}

public struct SessionOfferPayload: Codable {
    public let sessionId: String?
    public let sdp: String?
    public let iceServers: [[String: AnyCodable]]?
    public let accessMode: String?
    public let accessType: String?
    public let desktopScope: String?
    public let operatorId: String?
    public let operatorName: String?
    public let confirmationDigits: Int?
    public let confirmationRequired: Bool?
    public let recording: RecordingConfig?
    public let relayUrl: String?
    public let relayToken: String?

    public init(
        sessionId: String? = nil,
        sdp: String? = nil,
        iceServers: [[String: AnyCodable]]? = nil,
        accessMode: String? = nil,
        accessType: String? = nil,
        desktopScope: String? = nil,
        operatorId: String? = nil,
        operatorName: String? = nil,
        confirmationDigits: Int? = nil,
        confirmationRequired: Bool? = nil,
        recording: RecordingConfig? = nil,
        relayUrl: String? = nil,
        relayToken: String? = nil
    ) {
        self.sessionId = sessionId
        self.sdp = sdp
        self.iceServers = iceServers
        self.accessMode = accessMode
        self.accessType = accessType
        self.desktopScope = desktopScope
        self.operatorId = operatorId
        self.operatorName = operatorName
        self.confirmationDigits = confirmationDigits
        self.confirmationRequired = confirmationRequired
        self.recording = recording
        self.relayUrl = relayUrl
        self.relayToken = relayToken
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sdp
        case iceServers = "ice_servers"
        case accessMode = "access_mode"
        case accessType = "access_type"
        case desktopScope = "desktop_scope"
        case operatorId = "operator_id"
        case operatorName = "operator_name"
        case confirmationDigits = "confirmation_digits"
        case confirmationRequired = "confirmation_required"
        case recording
        case relayUrl = "relay_url"
        case relayToken = "relay_token"
    }
}

public struct SessionAnswerEnvelope: Codable {
    public let type: String = "session_answer"
    public let sessionId: String
    public let payload: SessionAnswerPayload

    public init(sessionId: String, accepted: Bool, sdp: String? = nil, reason: String? = nil) {
        self.sessionId = sessionId
        self.payload = SessionAnswerPayload(sessionId: sessionId, accepted: accepted, sdp: sdp, reason: reason)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case payload
    }
}

public struct SessionAnswerPayload: Codable {
    public let sessionId: String
    public let accepted: Bool
    public let sdp: String?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case accepted
        case sdp
        case reason
    }
}

public struct SignalMessage: Codable {
    public let type: String = "signal"
    public let sessionId: String
    public let signal: [String: AnyCodable]

    public init(sessionId: String, signal: [String: AnyCodable]) {
        self.sessionId = sessionId
        self.signal = signal
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case signal
    }
}

public struct SessionTerminateEnvelope: Codable {
    public let type: String = "session_terminate"
    public let sessionId: String
    public let payload: SessionTerminatePayload

    public init(sessionId: String, reason: String) {
        self.sessionId = sessionId
        self.payload = SessionTerminatePayload(sessionId: sessionId, reason: reason)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case payload
    }
}

public struct SessionTerminatePayload: Codable {
    public let sessionId: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case reason
    }
}

public struct RecordingConfig: Codable {
    public let enabled: Bool?
    public let ingestUrl: String?
    public let ingestToken: String?
    public let profile: String?
    public let epoch: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case ingestUrl = "ingest_url"
        case ingestToken = "ingest_token"
        case profile
        case epoch
    }
}

public struct AnyCodable: Codable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
            return
        }
        if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let a = try? container.decode([AnyCodable].self) {
            self.value = a.map { $0.value }
        } else if let m = try? container.decode([String: AnyCodable].self) {
            self.value = m.mapValues { $0.value }
        } else {
            self.value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let b = value as? Bool {
            try container.encode(b)
        } else if let i = value as? Int {
            try container.encode(i)
        } else if let d = value as? Double {
            try container.encode(d)
        } else if let s = value as? String {
            try container.encode(s)
        } else if let a = value as? [Any] {
            try container.encode(a.map { AnyCodable($0) })
        } else if let m = value as? [String: Any] {
            try container.encode(m.mapValues { AnyCodable($0) })
        } else {
            try container.encode(String(describing: value))
        }
    }
}
