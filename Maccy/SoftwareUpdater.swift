import Sparkle

@Observable
class SoftwareUpdater {
  var automaticallyChecksForUpdates = false {
    didSet {
      updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  let isAvailable: Bool

  private var updater: SPUUpdater?
  private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?
  private var updaterController: SPUStandardUpdaterController?

  init() {
    guard Self.hasEdDSAPublicKey else {
      isAvailable = false
      return
    }

    isAvailable = true

    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    guard let updater = updaterController?.updater else { return }
    self.updater = updater
    automaticallyChecksForUpdatesObservation = updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new, .old]
    ) { [unowned self] updater, change in
      guard change.newValue != change.oldValue else {
        return
      }

      self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
  }

  func checkForUpdates() {
    updater?.checkForUpdates()
  }

  static var hasEdDSAPublicKey: Bool {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
      return false
    }

    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
