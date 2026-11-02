import Flutter
import UIKit
import UserNotifications

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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LigamentPush")
    setupPushChannel(messenger: registrar.messenger())
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
