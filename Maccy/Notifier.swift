import AppKit
import UserNotifications

class Notifier {
  private static var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  static func notify(body: String?, sound: NSSound?) {
    guard let body else { return }

    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        deliver(body: body, sound: sound, settings: settings)
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
          if let error, !isNotificationsNotAllowed(error) {
            NSLog("Failed to authorize notifications: \(error)")
          }

          guard granted else { return }
          center.getNotificationSettings { authorizedSettings in
            deliver(body: body, sound: sound, settings: authorizedSettings)
          }
        }
      case .denied:
        return
      @unknown default:
        return
      }
    }
  }

  private static func deliver(body: String, sound: NSSound?, settings: UNNotificationSettings) {
    let content = UNMutableNotificationContent()
    if settings.alertSetting == .enabled {
      content.body = body
    }

    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(request) { error in
      if let error {
        NSLog("Failed to deliver notification: \(error)")
      } else if settings.soundSetting == .enabled {
        sound?.play()
      }
    }
  }

  private static func isNotificationsNotAllowed(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == UNErrorDomain && error.code == UNError.Code.notificationsNotAllowed.rawValue
  }
}
