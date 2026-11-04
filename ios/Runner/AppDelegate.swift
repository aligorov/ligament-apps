import Flutter
import UIKit
import UserNotifications
import CallKit
import AVFoundation

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
}

// MARK: - Native Apple CallKit Manager

final class LigamentCallKitManager: NSObject, CXProviderDelegate {
  static let shared = LigamentCallKitManager()

  private var provider: CXProvider?
  private let callController = CXCallController()
  private var callKitChannel: FlutterMethodChannel?
  private var currentCallUUID: UUID?

  func setup(messenger: FlutterBinaryMessenger) {
    if callKitChannel == nil {
      let channel = FlutterMethodChannel(name: "ligament/callkit", binaryMessenger: messenger)
      callKitChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleMethodCall(call, result: result)
      }
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

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "reportIncomingCall":
      guard let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      let callerName = (args["callerName"] as? String) ?? "Ligament"
      let hasVideo = (args["hasVideo"] as? Bool) ?? false

      self.currentCallUUID = uuid

      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: callerName)
      update.localizedCallerName = callerName
      update.hasVideo = hasVideo
      update.supportsHolding = false
      update.supportsGrouping = false
      update.supportsUngrouping = false
      update.supportsDTMF = false

      provider?.reportNewIncomingCall(with: uuid, update: update) { error in
        if let error = error {
          NSLog("[CallKit] reportNewIncomingCall error: %@", error.localizedDescription)
          result(FlutterError(code: "REPORT_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }

    case "startOutgoingCall":
      guard let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      let recipientName = (args["recipientName"] as? String) ?? "Ligament"
      let hasVideo = (args["hasVideo"] as? Bool) ?? false

      self.currentCallUUID = uuid

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
            let uuid = UUID(uuidString: uuidString) else {
        result(FlutterError(code: "INVALID_UUID", message: "Valid UUID is required", details: nil))
        return
      }
      provider?.reportOutgoingCall(with: uuid, connectedAt: Date())
      result(true)

    case "endCall":
      if let uuidString = args["uuid"] as? String, let uuid = UUID(uuidString: uuidString) {
        endCallWithUUID(uuid, result: result)
      } else if let currentUUID = self.currentCallUUID {
        endCallWithUUID(currentUUID, result: result)
      } else {
        result(true)
      }

    case "setMuted":
      guard let uuidString = args["uuid"] as? String,
            let uuid = UUID(uuidString: uuidString),
            let muted = args["muted"] as? Bool else {
        result(false)
        return
      }
      let action = CXSetMutedCallAction(call: uuid, muted: muted)
      let transaction = CXTransaction(action: action)
      callController.request(transaction) { _ in }
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func endCallWithUUID(_ uuid: UUID, result: @escaping FlutterResult) {
    if currentCallUUID == uuid {
      currentCallUUID = nil
    }
    let action = CXEndCallAction(call: uuid)
    let transaction = CXTransaction(action: action)
    callController.request(transaction) { [weak self] error in
      if error != nil {
        self?.provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      }
      result(true)
    }
  }

  // MARK: - CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    currentCallUUID = nil
    callKitChannel?.invokeMethod("onCallEnded", arguments: ["uuid": ""])
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    currentCallUUID = action.callUUID
    configureAudioSession()
    action.fulfill()
    callKitChannel?.invokeMethod("onCallAccepted", arguments: [
      "uuid": action.callUUID.uuidString
    ])
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if currentCallUUID == action.callUUID {
      currentCallUUID = nil
    }
    action.fulfill()
    callKitChannel?.invokeMethod("onCallEnded", arguments: [
      "uuid": action.callUUID.uuidString
    ])
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
    callKitChannel?.invokeMethod("onCallMuted", arguments: [
      "uuid": action.callUUID.uuidString,
      "muted": action.isMuted
    ])
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    configureAudioSession()
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("[CallKit] Audio session activated by CallKit")
    callKitChannel?.invokeMethod("onAudioSessionActivated", arguments: nil)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("[CallKit] Audio session deactivated by CallKit")
    callKitChannel?.invokeMethod("onAudioSessionDeactivated", arguments: nil)
  }

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
      )
      try session.setActive(true)
    } catch {
      NSLog("[CallKit] Error configuring AVAudioSession: %@", error.localizedDescription)
    }
  }
}
