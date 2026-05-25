import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let channelName = "kirca/apns"

  // Held statically so APNs delegate callbacks (which fire on the AppDelegate
  // before any Flutter engine is up) can push tokens back over the channel
  // we register inside `didInitializeImplicitFlutterEngine`.
  static weak var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // MethodChannel: Flutter calls `requestPermissions`, native pushes the
    // hex APNs device token back via `onToken` once Apple registers us.
    let channel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: engineBridge.binaryMessenger
    )
    AppDelegate.pushChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestPermissions" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.requestPushPermissions(result: result)
    }
  }

  private func requestPushPermissions(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, _ in
      DispatchQueue.main.async {
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
          result(true)
        } else {
          // Push permission denied — Flutter side falls back to the
          // 8-second timeout in Push.requestToken().
          result(false)
        }
      }
    }
  }

  // MARK: - APNs token plumbing

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    AppDelegate.pushChannel?.invokeMethod("onToken", arguments: hex)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    AppDelegate.pushChannel?.invokeMethod("onToken", arguments: nil)
  }

  // MARK: - Foreground presentation

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show banners and play sound even when the app is in the foreground so
    // users notice new messages without having to background the app first.
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }
}
