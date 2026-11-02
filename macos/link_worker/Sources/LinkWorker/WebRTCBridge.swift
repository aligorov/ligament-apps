import Foundation
import CoreMedia
import CoreVideo
import WebRTC

public protocol WebRTCBridgeDelegate: AnyObject {
    func webRTCBridge(_ bridge: WebRTCBridge, didGenerateCandidate candidate: RTCIceCandidate)
    func webRTCBridgeDidDisconnect(_ bridge: WebRTCBridge)
}

public final class WebRTCBridge: NSObject, @unchecked Sendable {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var dataChannel: RTCDataChannel?

    public weak var delegate: WebRTCBridgeDelegate?
    public var targetDisplayBounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var hasRemoteDescription: Bool = false
    private var pendingIceCandidates: [RTCIceCandidate] = []

    public override init() {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
        super.init()
    }

    deinit {
        RTCCleanupSSL()
    }

    public func setupPeerConnection(iceServers: [[String: AnyCodable]]?) {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        var rtcIceServers: [RTCIceServer] = []
        if let iceServers = iceServers {
            for server in iceServers {
                var urlStrings: [String] = []
                if let urls = server["urls"]?.value as? [String] {
                    urlStrings = urls
                } else if let url = server["urls"]?.value as? String {
                    urlStrings = [url]
                } else if let url = server["url"]?.value as? String {
                    urlStrings = [url]
                }
                let username = server["username"]?.value as? String
                let credential = server["credential"]?.value as? String
                rtcIceServers.append(RTCIceServer(urlStrings: urlStrings, username: username, credential: credential))
            }
        }
        config.iceServers = rtcIceServers

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let vSource = factory.videoSource()
        let vTrack = factory.videoTrack(with: vSource, trackId: "video_track_screen")
        let vCapturer = RTCVideoCapturer()

        peer?.add(vTrack, streamIds: ["screen_stream"])

        if let sender = peer?.senders.first(where: { $0.track?.kind == "video" }) {
            let params = sender.parameters
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            for encoding in params.encodings {
                encoding.maxBitrateBps = 10_000_000
                encoding.minBitrateBps = 1_500_000
            }
            sender.parameters = params
        }

        self.peerConnection = peer
        self.videoSource = vSource
        self.videoTrack = vTrack
        self.videoCapturer = vCapturer
    }

    public func feedVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard sampleBuffer.isValid,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let source = videoSource,
                  let capturer = videoCapturer else {
                return
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeStampNs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)

            let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: imageBuffer)
            let rtcVideoFrame = RTCVideoFrame(
                buffer: rtcPixelBuffer,
                rotation: ._0,
                timeStampNs: timeStampNs
            )

            source.capturer(capturer, didCapture: rtcVideoFrame)
        }
    }

    public func createAnswer(for offerSdp: String) async throws -> String {
        guard let peer = peerConnection else {
            throw NSError(domain: "WebRTCBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Peer connection not initialized"])
        }

        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offerSdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(remoteDescription) { [weak self] error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    guard let self = self else {
                        continuation.resume(returning: ())
                        return
                    }
                    self.hasRemoteDescription = true
                    for candidate in self.pendingIceCandidates {
                        self.peerConnection?.add(candidate) { _ in }
                    }
                    self.pendingIceCandidates.removeAll()
                    continuation.resume(returning: ())
                }
            }
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "false",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )

        let localAnswer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.answer(for: constraints) { sdp, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let sdp = sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: NSError(domain: "WebRTCBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create answer"]))
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(localAnswer) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        return localAnswer.sdp
    }

    public func addCandidate(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        if hasRemoteDescription {
            peerConnection?.add(candidate) { _ in }
        } else {
            pendingIceCandidates.append(candidate)
        }
    }

    public func close() {
        hasRemoteDescription = false
        pendingIceCandidates.removeAll()
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        videoTrack = nil
        videoSource = nil
        videoCapturer = nil
    }
}

extension WebRTCBridge: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .disconnected || newState == .failed || newState == .closed {
            delegate?.webRTCBridgeDidDisconnect(self)
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.webRTCBridge(self, didGenerateCandidate: candidate)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        if dataChannel.label == "link-control-v1" {
            self.dataChannel = dataChannel
            dataChannel.delegate = self
        }
    }
}

extension WebRTCBridge: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "mouse_move":
            if let x = json["x"] as? Double, let y = json["y"] as? Double {
                InputInjector.shared.moveMouse(normX: x, normY: y, bounds: targetDisplayBounds)
            }
        case "mouse_action":
            if let action = json["action"] as? String,
               let button = json["button"] as? Int,
               let x = json["x"] as? Double,
               let y = json["y"] as? Double {
                InputInjector.shared.mouseAction(action: action, button: button, normX: x, normY: y, bounds: targetDisplayBounds)
            }
        case "mouse_wheel":
            if let deltaY = json["delta_y"] as? Double {
                InputInjector.shared.mouseWheel(deltaY: deltaY)
            }
        case "key_action":
            if let keyCode = json["mac_key_code"] as? UInt16,
               let isDown = json["is_down"] as? Bool {
                InputInjector.shared.keyAction(macKeyCode: keyCode, isDown: isDown)
            }
        case "text_input":
            if let text = json["text"] as? String {
                InputInjector.shared.insertText(text)
            }
        default:
            break
        }
    }
}
