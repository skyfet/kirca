import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var apnsChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    apnsChannel = FlutterMethodChannel(
      name: "kirca/apns",
      binaryMessenger: controller.binaryMessenger
    )
    apnsChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestPermissions" else {
        result(FlutterMethodNotImplemented)
        return
      }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
        granted, _ in
        DispatchQueue.main.async {
          if granted {
            UIApplication.shared.registerForRemoteNotifications()
          }
          result(granted)
        }
      }
      _ = self
    }

    UNUserNotificationCenter.current().delegate = self
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsChannel?.invokeMethod("onToken", arguments: hex)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    apnsChannel?.invokeMethod("onToken", arguments: nil)
  }
}
