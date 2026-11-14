import Flutter
import UIKit
import UserNotifications
import CallKit
import AVFoundation
import WebRTC

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  private var pushToken: String?
  private var pendingAction: [String: Any]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    setupNotificationCategories()

    if let remoteNotif = launchOptions?[.remoteNotification] as? [String: Any] {
      self.pendingAction = [
        "action": UNNotificationDefaultActionIdentifier,
        "payload": remoteNotif
      ]
    }

    if let flutterVC = window?.rootViewController as? FlutterViewController {
      if self.pushChannel == nil {
        setupPushChannel(messenger: flutterVC.binaryMessenger)
      }
      LigamentCallKitManager.shared.setup(messenger: flutterVC.binaryMessenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LigamentPush") {
      setupPushChannel(messenger: registrar.messenger())
      LigamentCallKitManager.shared.setup(messenger: registrar.messenger())
    }
  }

  private func setupNotificationCategories() {
    let approveAction = UNNotificationAction(
      identifier: "APPROVE",
      title: "Подтвердить",
      options: [.authenticationRequired]
    )
    let denyAction = UNNotificationAction(
      identifier: "DENY",
      title: "Отклонить",
      options: [.destructive, .authenticationRequired]
    )
    let challengeCategory = UNNotificationCategory(
      identifier: "TWOFA_CHALLENGE",
      actions: [approveAction, denyAction],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    UNUserNotificationCenter.current().setNotificationCategories([challengeCategory])
  }

  private func setupPushChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ligament/push", binaryMessenger: messenger)
    self.pushChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handlePushMethodCall(call, result: result)
    }

    if let token = self.pushToken {
      channel.invokeMethod("onPushToken", arguments: token)
    }
  }

  private func handlePushMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "registerForPush":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        DispatchQueue.main.async {
          if granted {
            UIApplication.shared.registerForRemoteNotifications()
            result(["status": "granted", "token": self.pushToken as Any])
          } else {
            result(["status": "denied", "error": error?.localizedDescription as Any])
          }
        }
      }
    case "getPushToken":
      result(self.pushToken)
    case "getInitialNotification":
      let initial = self.pendingAction
      self.pendingAction = nil
      result(initial)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    self.pushToken = token
    self.pushChannel?.invokeMethod("onPushToken", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    self.pushChannel?.invokeMethod("onPushTokenError", arguments: error.localizedDescription)
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    var payload: [String: Any] = [:]
    for (k, v) in userInfo {
      if let keyStr = k as? String {
        payload[keyStr] = v
      }
    }
    self.pushChannel?.invokeMethod("onRemoteNotification", arguments: payload)
    completionHandler(.newData)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .badge, .sound, .list])
    } else {
      completionHandler([.alert, .badge, .sound])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionId = response.actionIdentifier
    let userInfo = response.notification.request.content.userInfo
    var payload: [String: Any] = [:]
    for (k, v) in userInfo {
      if let keyStr = k as? String {
        payload[keyStr] = v
      }
    }
    let event: [String: Any] = [
      "action": actionId,
      "payload": payload
    ]
    self.pendingAction = event
    self.pushChannel?.invokeMethod("onNotificationAction", arguments: event)
    completionHandler()
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    LigamentCallKitManager.shared.onEnterBackground()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    LigamentCallKitManager.shared.onEnterForeground()
  }
}

// MARK: - Native Apple CallKit Manager

final class LigamentCallKitManager: NSObject, CXProviderDelegate {
  static let shared = LigamentCallKitManager()

  private var provider: CXProvider?
  private let callController = CXCallController()
  private var callKitChannel: FlutterMethodChannel?
  private var currentCallUUID: UUID?
  private var providerCallUUID: UUID?
  private var trackedCallUUIDs: Set<UUID> = []
  private var currentCallHasVideo: Bool = false
  private var isCallAnswered: Bool = false
  private var keepAliveEnabled: Bool = true
  private var silentPlayer: AVAudioPlayer?
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  func setup(messenger: FlutterBinaryMessenger) {
    if callKitChannel == nil {
      let channel = FlutterMethodChannel(name: "ligament/callkit", binaryMessenger: messenger)
      callKitChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleMethodCall(call, result: result)
      }
      NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioRouteChange(_:)),
        name: AVAudioSession.routeChangeNotification,
        object: nil
      )
    }

    if provider == nil {
      let config = CXProviderConfiguration(localizedName: "Ligament 2FA")
      config.supportsVideo = true
      config.maximumCallsPerCallGroup = 1
      config.supportedHandleTypes = [.generic]
      config.includesCallsInRecents = true

      let cxProvider = CXProvider(configuration: config)
      cxProvider.setDelegate(self, queue: nil)
      self.provider = cxProvider
    }
  }

  func onEnterBackground() {
    beginBgTask()
    if keepAliveEnabled && currentCallUUID == nil {
      startSilentKeepAlive()
    }
  }

  func onEnterForeground() {
    stopSilentKeepAlive()
    endBgTask()
  }

  private func beginBgTask() {
    endBgTask()
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "LigamentVoIPKeepAlive") { [weak self] in
      self?.endBgTask()
    }
  }

  private func endBgTask() {
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }

  private func buildSilentWavData() -> Data {
    let sampleRate: UInt32 = 8000
    let numSamples: UInt32 = 8000
    let dataSize: UInt32 = numSamples * 2
    let fileSize: UInt32 = 36 + dataSize
    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    var leFileSize = fileSize.littleEndian
    data.append(Data(bytes: &leFileSize, count: 4))
    data.append("WAVEfmt ".data(using: .ascii)!)
    var fmtChunkSize = UInt32(16).littleEndian
    var audioFormat = UInt16(1).littleEndian
    var numChannels = UInt16(1).littleEndian
    var leSampleRate = sampleRate.littleEndian
    var byteRate = (sampleRate * 2).littleEndian
    var blockAlign = UInt16(2).littleEndian
    var bitsPerSample = UInt16(16).littleEndian
    data.append(Data(bytes: &fmtChunkSize, count: 4))
    data.append(Data(bytes: &audioFormat, count: 2))
    data.append(Data(bytes: &numChannels, count: 2))
    data.append(Data(bytes: &leSampleRate, count: 4))
    data.append(Data(bytes: &byteRate, count: 4))
    data.append(Data(bytes: &blockAlign, count: 2))
    data.append(Data(bytes: &bitsPerSample, count: 2))
    data.append("data".data(using: .ascii)!)
    var leDataSize = dataSize.littleEndian
    data.append(Data(bytes: &leDataSize, count: 4))
    data.append(Data(count: Int(dataSize)))
    return data
  }

  private func startSilentKeepAlive() {
    if silentPlayer?.isPlaying == true { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let wavData = buildSilentWavData()
      let player = try AVAudioPlayer(data: wavData)
      player.volume = 0.0
      player.numberOfLoops = -1
      player.prepareToPlay()
      player.play()
      silentPlayer = player
    } catch {
      NSLog("[CallKit] startSilentKeepAlive error: %@", error.localizedDescription)
    }
  }

  private func stopSilentKeepAlive() {
    if let player = silentPlayer {
      player.stop()
      silentPlayer = nil
    }
  }

  @objc private func handleAudioRouteChange(_ notification: Notification) {
    let session = AVAudioSession.sharedInstance()
    let isSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    DispatchQueue.main.async { [weak self] in
      self?.callKitChannel?.invokeMethod("onAudioRouteChanged", arguments: ["isSpeaker": isSpeaker])
    }
  }

  private func activateWebRTCAudio(hasVideo: Bool) {
    stopSilentKeepAlive()
    let rtcAudio = RTCAudioSession.sharedInstance()
    rtcAudio.lockForConfiguration()
    do {
      let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
      try rtcAudio.setCategory(.playAndRecord, with: options)
      try rtcAudio.setMode(.voiceChat)
      try rtcAudio.setActive(true)
      if hasVideo {
        try? rtcAudio.overrideOutputAudioPort(.speaker)
      }
    } catch {
      NSLog("[CallKit] activateWebRTCAudio config error: %@", error.localizedDescription)
    }
    rtcAudio.unlockForConfiguration()
    rtcAudio.useManualAudio = false
    rtcAudio.isAudioEnabled = true
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "startBackgroundKeepAlive":
      keepAliveEnabled = true
      if UIApplication.shared.applicationState != .active && currentCallUUID == nil {
        startSilentKeepAlive()
      }
      result(true)

    case "stopBackgroundKeepAlive":
      keepAliveEnabled = false
      stopSilentKeepAlive()
      result(true)

    case "reportIncomingCall":
      guard let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      if self.currentCallUUID == uuid {
        result(true)
        return
      }
      let callerName = (args["callerName"] as? String) ?? "Ligament"
      let hasVideo = (args["hasVideo"] as? Bool) ?? false

      stopSilentKeepAlive()

      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: callerName)
      update.localizedCallerName = callerName
      update.hasVideo = hasVideo
      update.supportsHolding = false
      update.supportsGrouping = false
      update.supportsUngrouping = false
      update.supportsDTMF = false

      // Если входящий звонок уже был зарегистрирован под временным UUID (до прихода offer),
      // обновляем метаданные у существующего вызова и синхронизируем currentCallUUID без дублирования окна.
      if let existingProviderUUID = self.providerCallUUID ?? self.currentCallUUID {
        self.trackedCallUUIDs.insert(existingProviderUUID)
        self.trackedCallUUIDs.insert(uuid)
        self.providerCallUUID = existingProviderUUID
        self.currentCallUUID = uuid
        self.currentCallHasVideo = hasVideo
        self.provider?.reportCall(with: existingProviderUUID, updated: update)
        result(true)
        return
      }

      self.currentCallUUID = uuid
      self.providerCallUUID = uuid
      self.trackedCallUUIDs.insert(uuid)
      self.currentCallHasVideo = hasVideo
      self.isCallAnswered = false

      let rtcAudio = RTCAudioSession.sharedInstance()
      rtcAudio.useManualAudio = true
      rtcAudio.isAudioEnabled = false

      provider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        if let error = error {
          NSLog("[CallKit] reportNewIncomingCall error: %@", error.localizedDescription)
          // Если CallKit отклонён системой, сразу включаем аудио для внутриприложенческого вызова
          self?.activateWebRTCAudio(hasVideo: hasVideo)
          result(FlutterError(code: "REPORT_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }

    case "answerCall":
      let hasVideo = (args["hasVideo"] as? Bool) ?? self.currentCallHasVideo
      self.currentCallHasVideo = hasVideo
      if let uuidString = args["uuid"] as? String,
         let requestedUUID = UUID(uuidString: uuidString),
         !isCallAnswered {
        isCallAnswered = true
        let targetUUID = self.providerCallUUID ?? requestedUUID
        let action = CXAnswerCallAction(call: targetUUID)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
          if error != nil {
            self?.activateWebRTCAudio(hasVideo: hasVideo)
          }
        }
      }
      activateWebRTCAudio(hasVideo: hasVideo)
      result(true)

    case "activateAudio":
      let hasVideo = (args["hasVideo"] as? Bool) ?? self.currentCallHasVideo
      self.currentCallHasVideo = hasVideo
      activateWebRTCAudio(hasVideo: hasVideo)
      result(true)

    case "startOutgoingCall":
      guard let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      let recipientName = (args["recipientName"] as? String) ?? "Ligament"
      let hasVideo = (args["hasVideo"] as? Bool) ?? false

      stopSilentKeepAlive()
      self.currentCallUUID = uuid
      self.providerCallUUID = uuid
      self.trackedCallUUIDs.insert(uuid)
      self.currentCallHasVideo = hasVideo
      self.isCallAnswered = true
      activateWebRTCAudio(hasVideo: hasVideo)

      let handle = CXHandle(type: .generic, value: recipientName)
      let action = CXStartCallAction(call: uuid, handle: handle)
      action.isVideo = hasVideo
      let transaction = CXTransaction(action: action)

      callController.request(transaction) { error in
        if let error = error {
          NSLog("[CallKit] startOutgoingCall error: %@", error.localizedDescription)
          result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }

    case "reportOutgoingCallConnected":
      guard let uuidString = args["uuid"] as? String,
            let requestedUUID = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      let targetUUID = self.providerCallUUID ?? requestedUUID
      provider?.reportOutgoingCall(with: targetUUID, connectedAt: Date())
      activateWebRTCAudio(hasVideo: self.currentCallHasVideo)
      result(true)

    case "endCall":
      var uuidsToEnd = self.trackedCallUUIDs
      if let activeUUID = self.providerCallUUID {
        uuidsToEnd.insert(activeUUID)
      }
      if let currentUUID = self.currentCallUUID {
        uuidsToEnd.insert(currentUUID)
      }
      if let uuidString = args["uuid"] as? String, let requestedUUID = UUID(uuidString: uuidString) {
        uuidsToEnd.insert(requestedUUID)
      }
      self.currentCallUUID = nil
      self.providerCallUUID = nil
      self.trackedCallUUIDs.removeAll()
      self.isCallAnswered = false
      if uuidsToEnd.isEmpty {
        result(true)
      } else {
        endCallUUIDs(Array(uuidsToEnd), result: result)
      }

    case "setMuted":
      guard let uuidString = args["uuid"] as? String,
            let requestedUUID = UUID(uuidString: uuidString),
            let muted = args["muted"] as? Bool else {
        result(false)
        return
      }
      let targetUUID = self.providerCallUUID ?? requestedUUID
      let action = CXSetMutedCallAction(call: targetUUID, muted: muted)
      let transaction = CXTransaction(action: action)
      callController.request(transaction) { _ in }
      result(true)

    case "setSpeaker":
      let enabled = (args["enabled"] as? Bool) ?? false
      let rtcAudio = RTCAudioSession.sharedInstance()
      rtcAudio.lockForConfiguration()
      do {
        try rtcAudio.overrideOutputAudioPort(enabled ? .speaker : .none)
      } catch {
        NSLog("[CallKit] setSpeaker error: %@", error.localizedDescription)
      }
      rtcAudio.unlockForConfiguration()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func endCallUUIDs(_ uuids: [UUID], result: @escaping FlutterResult) {
    let actions = uuids.map { CXEndCallAction(call: $0) }
    let transaction = CXTransaction(actions: actions)
    callController.request(transaction) { [weak self] error in
      if error != nil {
        for uuid in uuids {
          self?.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
      }
      if UIApplication.shared.applicationState != .active && self?.keepAliveEnabled == true {
        self?.startSilentKeepAlive()
      }
      result(true)
    }
  }

  // MARK: - CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    currentCallUUID = nil
    providerCallUUID = nil
    trackedCallUUIDs.removeAll()
    isCallAnswered = false
    callKitChannel?.invokeMethod("onCallEnded", arguments: ["uuid": ""])
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    if currentCallUUID == nil {
      currentCallUUID = action.callUUID
    }
    providerCallUUID = action.callUUID
    trackedCallUUIDs.insert(action.callUUID)
    isCallAnswered = true
    activateWebRTCAudio(hasVideo: currentCallHasVideo)
    action.fulfill()
    callKitChannel?.invokeMethod("onCallAccepted", arguments: [
      "uuid": action.callUUID.uuidString
    ])
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if currentCallUUID == action.callUUID || providerCallUUID == action.callUUID {
      currentCallUUID = nil
      providerCallUUID = nil
      trackedCallUUIDs.removeAll()
      isCallAnswered = false
    } else {
      trackedCallUUIDs.remove(action.callUUID)
    }
    action.fulfill()
    callKitChannel?.invokeMethod("onCallEnded", arguments: [
      "uuid": action.callUUID.uuidString
    ])
    if UIApplication.shared.applicationState != .active && keepAliveEnabled {
      startSilentKeepAlive()
    }
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
    callKitChannel?.invokeMethod("onCallMuted", arguments: [
      "uuid": action.callUUID.uuidString,
      "muted": action.isMuted
    ])
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    isCallAnswered = true
    activateWebRTCAudio(hasVideo: currentCallHasVideo)
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("[CallKit] Audio session activated by CallKit")
    let rtcAudio = RTCAudioSession.sharedInstance()
    rtcAudio.audioSessionDidActivate(audioSession)
    rtcAudio.useManualAudio = false
    rtcAudio.isAudioEnabled = true
    if currentCallHasVideo {
      try? audioSession.overrideOutputAudioPort(.speaker)
    }
    callKitChannel?.invokeMethod("onAudioSessionActivated", arguments: nil)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("[CallKit] Audio session deactivated by CallKit")
    let rtcAudio = RTCAudioSession.sharedInstance()
    rtcAudio.audioSessionDidDeactivate(audioSession)
    callKitChannel?.invokeMethod("onAudioSessionDeactivated", arguments: nil)
    if UIApplication.shared.applicationState != .active && keepAliveEnabled && currentCallUUID == nil {
      startSilentKeepAlive()
    }
  }
}
