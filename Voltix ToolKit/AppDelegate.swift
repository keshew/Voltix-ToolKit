import AdjustSdk
import AppTrackingTransparency
import FirebaseCore
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

private let adjustAppToken = "hpk9t70g0hds"
private let adjustEnvironment = ADJEnvironmentProduction

final class AdjustAttributionHandler: NSObject, AdjustDelegate {
    func adjustAttributionChanged(_ attribution: ADJAttribution?) {
        guard let attribution else { return }

        if #available(iOS 14, *),
           ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            print("Adjust attribution received before ATT decision, skipping save for now")
            return
        }

        guard let jsonResponse = attribution.jsonResponse,
              let data = try? JSONSerialization.data(withJSONObject: jsonResponse, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.removeObject(forKey: "lastAdjustAttribution")
            print("Adjust attribution jsonResponse is empty")
            return
        }

        UserDefaults.standard.set(jsonString, forKey: "lastAdjustAttribution")
        print("Adjust attribution saved:", jsonString)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    static var orientationLock = UIInterfaceOrientationMask.allButUpsideDown
    private static let pushDedupQueue = DispatchQueue(label: "voltix-toolkit.push.dedup")
    private static var lastPushDispatchSignature: String = ""
    private static var lastPushDispatchAt: Date = .distantPast
    private let adjustAttributionHandler = AdjustAttributionHandler()

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()

        UNUserNotificationCenter.current().delegate = self

        Messaging.messaging().delegate = self
        Messaging.messaging().isAutoInitEnabled = true

        let adjustConfig = ADJConfig(appToken: adjustAppToken, environment: adjustEnvironment)
        adjustConfig?.delegate = adjustAttributionHandler
        adjustConfig?.attConsentWaitingInterval = 13
        Adjust.initSdk(adjustConfig)

        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Messaging.messaging().appDidReceiveMessage(userInfo)
            let pushIdentifier = savePushIdIfNeeded(userInfo, source: "launchOptions")
            notifyPushClicked(pushId: pushIdentifier, source: "launchOptions")
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken

        let apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(apnsToken, forKey: "apnsToken")
        print("APNS token:", apnsToken)

        Messaging.messaging().token { token, error in
            if let error {
                print("=== FCM_TOKEN_FETCH_AFTER_APNS_ERROR === \(error.localizedDescription)")
                return
            }
            let value = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "null"
            print("=== FCM_TOKEN_FETCH_AFTER_APNS === \(value)")
            self.saveAndPublishFCMToken(token, source: "afterAPNSTokenFetch")
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set("null", forKey: "fcmToken")
        print("APNS registration failed:", error.localizedDescription)
        print("=== APNS_REGISTRATION_ERROR === \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Messaging.messaging().appDidReceiveMessage(userInfo)
        savePushIdIfNeeded(userInfo, source: "willPresent")
        completionHandler([.list, .banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Messaging.messaging().appDidReceiveMessage(userInfo)
        let pushIdentifier = savePushIdIfNeeded(userInfo, source: "click")
        notifyPushClicked(pushId: pushIdentifier, source: "click")
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
        let pushIdentifier = savePushIdIfNeeded(userInfo, source: "didReceiveRemoteNotification")
        notifyPushClicked(pushId: pushIdentifier, source: "didReceiveRemoteNotification")
        completionHandler(.newData)
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        saveAndPublishFCMToken(fcmToken, source: "didReceiveRegistrationToken")
    }
}

private extension AppDelegate {
    func saveAndPublishFCMToken(_ token: String?, source: String) {
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedToken, !normalizedToken.isEmpty {
            UserDefaults.standard.set(normalizedToken, forKey: "fcmToken")
            print("FCM token (\(source)):", normalizedToken)
            print("=== FCM_TOKEN === \(normalizedToken)")
            NotificationCenter.default.post(
                Notification(name: NSNotification.Name("tokenReceivedPublisher"), object: nil)
            )
            return
        }

        UserDefaults.standard.set("null", forKey: "fcmToken")
        print("FCM token (\(source)): null")
        print("=== FCM_TOKEN === null")
    }

    func notifyPushClicked(pushId: String?, source: String) {
        let normalizedPushId = pushId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signature = normalizedPushId.isEmpty ? "empty:\(source)" : normalizedPushId
        let now = Date()

        let shouldDispatch = AppDelegate.pushDedupQueue.sync { () -> Bool in
            let elapsed = now.timeIntervalSince(AppDelegate.lastPushDispatchAt)
            let isDuplicate = (AppDelegate.lastPushDispatchSignature == signature) && elapsed < 2.0
            if isDuplicate {
                return false
            }
            AppDelegate.lastPushDispatchSignature = signature
            AppDelegate.lastPushDispatchAt = now
            return true
        }

        guard shouldDispatch else {
            print("pushClicked dedup skip source=\(source) push_id=\(normalizedPushId)")
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("pushClicked"), object: nil)
        }
    }

    func textValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func extractPushId(from object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let direct = textValue(dictionary["push_id"]) { return direct }
            if let direct = textValue(dictionary["gcm.notification.push_id"]) { return direct }
            if let nested = dictionary["push_data"], let id = extractPushId(from: nested) { return id }
            if let nested = dictionary["data"], let id = extractPushId(from: nested) { return id }
            return nil
        }

        if let dictionary = object as? [AnyHashable: Any] {
            if let direct = textValue(dictionary["push_id"]) { return direct }
            if let direct = textValue(dictionary["gcm.notification.push_id"]) { return direct }
            if let nested = dictionary["push_data"], let id = extractPushId(from: nested) { return id }
            if let nested = dictionary["data"], let id = extractPushId(from: nested) { return id }
            return nil
        }

        if let text = object as? String,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return extractPushId(from: json)
        }

        return nil
    }

    @discardableResult
    func savePushIdIfNeeded(_ userInfo: [AnyHashable: Any], source: String) -> String? {
        if let pushId = extractPushId(from: userInfo as Any), !pushId.isEmpty {
            UserDefaults.standard.set(pushId, forKey: "lastPushId")
            print("push_id (\(source)):", pushId)
            if let data = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(text, forKey: "lastPushUserInfoDump")
            }
            return pushId
        }

        print("push_id (\(source)) отсутствует")
        if let data = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: "lastPushUserInfoDump")
        }
        return nil
    }
}
