import AppKit

struct Accessibility {
  static var isTrusted: Bool { AXIsProcessTrustedWithOptions(nil) }
  private static let accessibilitySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  )

  @discardableResult
  static func check(prompt: Bool = false) -> Bool {
    guard !isTrusted else {
      return true
    }

    if prompt {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    return false
  }

  static func openSettings() {
    guard let accessibilitySettingsURL else { return }
    NSWorkspace.shared.open(accessibilitySettingsURL)
  }
}
