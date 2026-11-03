import Foundation
import ScreenCaptureKit
import CoreMedia
import WebRTC
import Darwin

final class WorkerCoordinator: WebRTCBridgeDelegate, ScreenCaptureDelegate {
    private let ipc = IPCClient()
    private let capturer = ScreenCapturer()
    private let webRTC = WebRTCBridge()
    private var recorder: RecorderSink?
    private var currentSessionId: String = ""
    private let runLoop = CFRunLoopGetCurrent()

    func run(socketPath: String) async {
        do {
            try ipc.connect(socketPath: socketPath)
            
            let initialData = try ipc.readFrame()
            let decoder = JSONDecoder()
            let offerEnvelope: SessionOfferEnvelope
            do {
                offerEnvelope = try decoder.decode(SessionOfferEnvelope.self, from: initialData)
            } catch {
                if let raw = String(data: initialData, encoding: .utf8) {
                    fputs("link-worker-darwin failed to decode initial offer: \(error), raw data: \(raw)\n", stderr)
                }
                throw error
            }
            let offer = offerEnvelope.payload
            self.currentSessionId = offerEnvelope.effectiveSessionId
            guard !self.currentSessionId.isEmpty else {
                fputs("link-worker-darwin error: session_id is missing from offer payload\n", stderr)
                exit(1)
            }

            webRTC.delegate = self
            capturer.delegate = self
            recorder = RecorderSink(config: offer.recording)

            webRTC.setupPeerConnection(iceServers: offer.iceServers)

            // Start ScreenCaptureKit (Video + System Audio)
            do {
                fputs("link-worker-darwin: starting screen capture for session \(self.currentSessionId)...\n", stderr)
                try await capturer.startCapture(captureAudio: true)
                fputs("link-worker-darwin: screen capture started successfully\n", stderr)
                webRTC.targetDisplayBounds = capturer.activeDisplayBounds
            } catch {
                fputs("link-worker-darwin: startCapture failed: \(error)\n", stderr)
                let answer = SessionAnswerEnvelope(
                    sessionId: self.currentSessionId,
                    accepted: false,
                    reason: "host_screen_capture_unavailable"
                )
                try? ipc.send(answer)
                exit(1)
            }

            // Create WebRTC Answer SDP
            guard let offerSdp = offer.sdp, !offerSdp.isEmpty else {
                fputs("link-worker-darwin: offer SDP is empty\n", stderr)
                let answer = SessionAnswerEnvelope(
                    sessionId: self.currentSessionId,
                    accepted: false,
                    reason: "invalid_offer"
                )
                try? ipc.send(answer)
                await capturer.stopCapture()
                exit(1)
            }

            do {
                fputs("link-worker-darwin: creating WebRTC answer...\n", stderr)
                let answerSdp = try await webRTC.createAnswer(for: offerSdp)
                fputs("link-worker-darwin: WebRTC answer created successfully\n", stderr)
                let answer = SessionAnswerEnvelope(
                    sessionId: self.currentSessionId,
                    accepted: true,
                    sdp: answerSdp
                )
                try ipc.send(answer)
            } catch {
                fputs("link-worker-darwin: createAnswer failed: \(error)\n", stderr)
                let answer = SessionAnswerEnvelope(
                    sessionId: self.currentSessionId,
                    accepted: false,
                    reason: "host_worker_failed"
                )
                try? ipc.send(answer)
                await capturer.stopCapture()
                exit(1)
            }

            // Background reader for IPC signaling
            Task.detached { [weak self] in
                self?.readLoop()
            }

        } catch {
            fputs("link-worker-darwin error: \(error)\n", stderr)
            exit(1)
        }
    }

    private func readLoop() {
        while true {
            do {
                let frameData = try ipc.readFrame()
                guard let json = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any],
                      let type = json["type"] as? String else {
                    continue
                }

                if type == "signal",
                   let signal = json["signal"] as? [String: Any],
                   let candidateMap = signal["candidate"] as? [String: Any],
                   let sdp = candidateMap["candidate"] as? String {
                    let sdpMLineIndex = (candidateMap["sdpMLineIndex"] as? Int32) ?? 0
                    let sdpMid = candidateMap["sdpMid"] as? String
                    webRTC.addCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                } else if type == "session_terminate" {
                    Task { [weak self] in
                        await self?.shutdown()
                    }
                    break
                }
            } catch {
                Task { [weak self] in
                    await self?.shutdown()
                }
                break
            }
        }
    }

    func shutdown() async {
        await capturer.stopCapture()
        webRTC.close()
        ipc.close()
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        exit(0)
    }

    // MARK: - ScreenCaptureDelegate
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        webRTC.feedVideoFrame(sampleBuffer)
        recorder?.feedVideoFrame(sampleBuffer)
    }

    func didCaptureAudioFrame(_ sampleBuffer: CMSampleBuffer) {
        // Reserved for audio forwarding
    }

    func didPauseCapture(reason: String) {
        fputs("link-worker-darwin: stream paused (\(reason))\n", stderr)
    }

    func didResumeCapture() {
        fputs("link-worker-darwin: stream resumed\n", stderr)
        webRTC.targetDisplayBounds = capturer.activeDisplayBounds
    }

    func didFailCapture(error: Error) {
        Task { [weak self] in
            guard let self = self else { return }
            try? self.ipc.send(SessionTerminateEnvelope(sessionId: self.currentSessionId, reason: "host_media_failed"))
            await self.shutdown()
        }
    }

    // MARK: - WebRTCBridgeDelegate
    func webRTCBridge(_ bridge: WebRTCBridge, didGenerateCandidate candidate: RTCIceCandidate) {
        let signal: [String: AnyCodable] = [
            "type": AnyCodable("candidate"),
            "candidate": AnyCodable([
                "candidate": candidate.sdp,
                "sdpMLineIndex": candidate.sdpMLineIndex,
                "sdpMid": candidate.sdpMid as Any
            ])
        ]
        let message = SignalMessage(sessionId: currentSessionId, signal: signal)
        try? ipc.send(message)
    }

    func webRTCBridgeDidDisconnect(_ bridge: WebRTCBridge) {
        Task { [weak self] in
            guard let self = self else { return }
            try? self.ipc.send(SessionTerminateEnvelope(sessionId: self.currentSessionId, reason: "peer_failed"))
            await self.shutdown()
        }
    }
}

// Entry Point
let args = CommandLine.arguments
var socketPath: String?

for arg in args {
    if arg.hasPrefix("--link-host=unix:") {
        socketPath = String(arg.dropFirst("--link-host=unix:".count))
    }
}

guard let path = socketPath, !path.isEmpty else {
    fputs("Usage: link-worker-darwin --link-host=unix:<socketPath>\n", stderr)
    exit(2)
}

// Trap termination signals
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

let coordinator = WorkerCoordinator()
Task {
    await coordinator.run(socketPath: path)
}

CFRunLoopRun()
