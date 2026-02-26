import AppKit
import Defaults

enum SyncScope: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
  case all
  case pinnedOnly
  case textOnly

  var id: Self { self }

  var description: String {
    switch self {
    case .all:
      return NSLocalizedString("SyncScopeAll", tableName: "StorageSettings", comment: "")
    case .pinnedOnly:
      return NSLocalizedString("SyncScopePinnedOnly", tableName: "StorageSettings", comment: "")
    case .textOnly:
      return NSLocalizedString("SyncScopeTextOnly", tableName: "StorageSettings", comment: "")
    }
  }
}

enum UnlockPolicy: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
  case onSleepOrRestart
  case timer
  case strictPerAction

  var id: Self { self }

  var description: String {
    switch self {
    case .onSleepOrRestart:
      return NSLocalizedString("UnlockPolicySleepRestart", tableName: "StorageSettings", comment: "")
    case .timer:
      return NSLocalizedString("UnlockPolicyTimer", tableName: "StorageSettings", comment: "")
    case .strictPerAction:
      return NSLocalizedString("UnlockPolicyStrict", tableName: "StorageSettings", comment: "")
    }
  }
}

enum CloudSyncStatus: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
  case healthy
  case unavailable
  case authRequired
  case quotaExceeded
  case error

  var id: Self { self }

  var description: String {
    switch self {
    case .healthy:
      return NSLocalizedString("CloudSyncStatusHealthy", tableName: "StorageSettings", comment: "")
    case .unavailable:
      return NSLocalizedString("CloudSyncStatusUnavailable", tableName: "StorageSettings", comment: "")
    case .authRequired:
      return NSLocalizedString("CloudSyncStatusAuthRequired", tableName: "StorageSettings", comment: "")
    case .quotaExceeded:
      return NSLocalizedString("CloudSyncStatusQuotaExceeded", tableName: "StorageSettings", comment: "")
    case .error:
      return NSLocalizedString("CloudSyncStatusError", tableName: "StorageSettings", comment: "")
    }
  }
}

struct StorageType {
  static let files = StorageType(types: [.fileURL])
  static let images = StorageType(types: [.png, .tiff])
  static let text = StorageType(types: [.html, .rtf, .string])
  static let all = StorageType(types: files.types + images.types + text.types)

  var types: [NSPasteboard.PasteboardType]
}

extension Defaults.Keys {
  static let clearOnQuit = Key<Bool>("clearOnQuit", default: false)
  static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false)
  static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5)
  static let enabledPasteboardTypes = Key<Set<NSPasteboard.PasteboardType>>(
    "enabledPasteboardTypes", default: Set(StorageType.all.types)
  )
  static let highlightMatch = Key<HighlightMatch>("highlightMatch", default: .bold)
  static let ignoreAllAppsExceptListed = Key<Bool>("ignoreAllAppsExceptListed", default: false)
  static let ignoreEvents = Key<Bool>("ignoreEvents", default: false)
  static let ignoreOnlyNextEvent = Key<Bool>("ignoreOnlyNextEvent", default: false)
  static let ignoreRegexp = Key<[String]>("ignoreRegexp", default: [])
  static let ignoredApps = Key<[String]>("ignoredApps", default: [])
  static let ignoredPasteboardTypes = Key<Set<String>>(
    "ignoredPasteboardTypes",
    default: Set([
      "Pasteboard generator type",
      "com.agilebits.onepassword",
      "com.typeit4me.clipping",
      "de.petermaurer.TransientPasteboardType",
      "net.antelle.keeweb"
    ])
  )
  static let imageMaxHeight = Key<Int>("imageMaxHeight", default: 40)
  static let lastReviewRequestedAt = Key<Date>("lastReviewRequestedAt", default: Date.now)
  static let menuIcon = Key<MenuIcon>("menuIcon", default: .maccy)
  static let migrations = Key<[String: Bool]>("migrations", default: [:])
  static let numberOfUsages = Key<Int>("numberOfUsages", default: 0)
  static let pasteByDefault = Key<Bool>("pasteByDefault", default: false)
  static let pinTo = Key<PinsPosition>("pinTo", default: .top)
  static let popupPosition = Key<PopupPosition>("popupPosition", default: .cursor)
  static let popupLayoutMode = Key<PopupLayoutMode>("popupLayoutMode", default: .list)
  static let popupScreen = Key<Int>("popupScreen", default: 0)
  static let previewDelay = Key<Int>("previewDelay", default: 1500)
  static let removeFormattingByDefault = Key<Bool>("removeFormattingByDefault", default: false)
  static let searchMode = Key<Search.Mode>("searchMode", default: .exact)
  static let showFooter = Key<Bool>("showFooter", default: true)
  static let showInStatusBar = Key<Bool>("showInStatusBar", default: true)
  static let showRecentCopyInMenuBar = Key<Bool>("showRecentCopyInMenuBar", default: false)
  static let showSearch = Key<Bool>("showSearch", default: true)
  static let searchVisibility = Key<SearchVisibility>("searchVisibility", default: .always)
  static let showSpecialSymbols = Key<Bool>("showSpecialSymbols", default: true)
  static let showTitle = Key<Bool>("showTitle", default: true)
  static let size = Key<Int>("historySize", default: 200)
  static let sortBy = Key<Sorter.By>("sortBy", default: .lastCopiedAt)
  static let suppressClearAlert = Key<Bool>("suppressClearAlert", default: false)
  static let syncEnabled = Key<Bool>("syncEnabled", default: false)
  static let syncScope = Key<SyncScope>("syncScope", default: .all)
  static let encryptionEnabled = Key<Bool>("encryptionEnabled", default: false)
  static let unlockPolicy = Key<UnlockPolicy>("unlockPolicy", default: .onSleepOrRestart)
  static let unlockTimeoutMinutes = Key<Int>("unlockTimeoutMinutes", default: 5)
  static let cloudSyncStatus = Key<CloudSyncStatus>("cloudSyncStatus", default: .healthy)
  static let encryptedVaultVersion = Key<Int>("encryptedVaultVersion", default: 1)
  static let encryptionSalt = Key<Data?>("encryptionSalt", default: nil)
  static let encryptionVerifier = Key<Data?>("encryptionVerifier", default: nil)
  static let syncItemTombstones = Key<Data?>("syncItemTombstones", default: nil)
  static let syncTagTombstones = Key<Data?>("syncTagTombstones", default: nil)
  static let windowSize = Key<NSSize>("windowSize", default: NSSize(width: 450, height: 800))
  static let windowPosition = Key<NSPoint>("windowPosition", default: NSPoint(x: 0.5, y: 0.8))
  static let showApplicationIcons = Key<Bool>("showApplicationIcons", default: false)
  static let previewWidth = Key<CGFloat>("previewWidth", default: 400)
  static let shelfPreviewImageEditorBundleID = Key<String?>("shelfPreviewImageEditorBundleID", default: nil)
}
