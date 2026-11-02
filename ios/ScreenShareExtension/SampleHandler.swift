import ReplayKit
import OSLog

public final class SampleHandler: RPBroadcastSampleHandler, SocketConnectionDelegate {
    private var clientConnection: SocketConnection?
    private var uploader: SampleUploader?

    private static let appGroupIdentifier = "group.com.ligament.authenticator"

    private var socketFilePath: String {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
        return container?.appendingPathComponent("rtc_SSFD").path ?? ""
    }

    public override init() {
        super.init()
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let path = socketFilePath
        guard !path.isEmpty else { return }

        let connection = SocketConnection(filePath: path)
        self.clientConnection = connection
        connection.delegate = self
        self.uploader = SampleUploader(connection: connection)
        connection.open()
    }

    public override func broadcastPaused() {
        // Broadcast paused by user
    }

    public override func broadcastResumed() {
        // Broadcast resumed
    }

    public override func broadcastFinished() {
        clientConnection?.closeSocket()
        clientConnection = nil
        uploader = nil
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            uploader?.send(sampleBuffer: sampleBuffer)
        case .audioApp:
            // Reserved for system audio forwarding
            break
        case .audioMic:
            // Microphone audio if needed
            break
        @unknown default:
            break
        }
    }

    // MARK: - SocketConnectionDelegate
    public func socketDidOpen() {
        os_log("Ligament ScreenShareExtension: connected to main app socket", type: .info)
    }

    public func socketDidClose(error: Error?) {
        if let error = error {
            os_log("Ligament ScreenShareExtension: socket closed with error: %{public}@", type: .error, error.localizedDescription)
        }
    }
}
