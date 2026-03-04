import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy
  @Default(.syncEnabled) private var syncEnabled
  @Default(.syncScope) private var syncScope
  @Default(.encryptionEnabled) private var encryptionEnabled
  @Default(.unlockPolicy) private var unlockPolicy
  @Default(.unlockTimeoutMinutes) private var unlockTimeoutMinutes
  @Default(.cloudSyncStatus) private var cloudSyncStatus

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size
  @State private var syncManager = SyncEncryptionManager.shared

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  private let timeoutFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 1_440
    return formatter
  }()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Save", tableName: "StorageSettings") }
      ) {
        Toggle(
          isOn: $viewModel.saveFiles,
          label: { Text("Files", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveImages,
          label: { Text("Images", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveText,
          label: { Text("Text", tableName: "StorageSettings") }
        )
        Text("SaveDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }

      Settings.Section(label: { Text("Size", tableName: "StorageSettings") }) {
        HStack {
          TextField("", value: $size, formatter: sizeFormatter)
            .frame(width: 80)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
          Stepper("", value: $size, in: 1...999)
            .labelsHidden()
          Text(storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              storageSize = Storage.shared.size
            }
        }
      }

      Settings.Section(label: { Text("SortBy", tableName: "StorageSettings") }) {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .leading)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("SyncEncryption", tableName: "StorageSettings") }
      ) {
        Toggle(isOn: $syncEnabled) {
          Text("EnableSync", tableName: "StorageSettings")
        }

        Picker(selection: $syncScope) {
          ForEach(SyncScope.allCases) { scope in
            Text(scope.description).tag(scope)
          }
        } label: {
          Text("SyncScope", tableName: "StorageSettings")
        }
        .onChange(of: syncScope) { _, _ in
          SyncEncryptionManager.shared.handleSyncScopeChanged()
        }

        Text("TagsAlwaysSyncDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)

        HStack {
          Button(action: {
            syncManager.manualSyncFromUI()
          }, label: {
            Text("Sync now")
          })
          .disabled(
            !syncEnabled ||
              syncManager.isSyncInProgress ||
              (encryptionEnabled && syncManager.isLocked)
          )

          if syncManager.isSyncInProgress {
            ProgressView()
              .controlSize(.small)
          }

          Spacer()
        }

        Toggle(isOn: $encryptionEnabled) {
          Text("EnableEncryption", tableName: "StorageSettings")
        }
        .onChange(of: encryptionEnabled) { _, newValue in
          if newValue {
            SyncEncryptionManager.shared.enableEncryptionFromUI()
          } else {
            SyncEncryptionManager.shared.disableEncryptionAndWipeFromUI()
          }
        }

        if encryptionEnabled {
          Picker(selection: $unlockPolicy) {
            ForEach(UnlockPolicy.allCases) { policy in
              Text(policy.description).tag(policy)
            }
          } label: {
            Text("UnlockPolicy", tableName: "StorageSettings")
          }

          if unlockPolicy == .timer {
            HStack {
              Text("UnlockTimeout", tableName: "StorageSettings")
              TextField("", value: $unlockTimeoutMinutes, formatter: timeoutFormatter)
                .frame(width: 60)
              Text("MinutesSuffix", tableName: "StorageSettings")
                .foregroundStyle(.secondary)
            }
          }

          if syncManager.isLocked {
            HStack {
              Text("VaultLockedLabel", tableName: "StorageSettings")
              Spacer()
              Button(action: {
                SyncEncryptionManager.shared.unlockWithPrompt()
              }, label: {
                Text("Unlock", tableName: "StorageSettings")
              })
            }
          }

          HStack {
            Button(action: {
              SyncEncryptionManager.shared.changePasswordFromUI()
            }, label: {
              Text(
                Bundle.main.localizedString(
                  forKey: "ChangePassword",
                  value: "Change password",
                  table: "StorageSettings"
                )
              )
            })
            .disabled(syncManager.isSyncInProgress)
            Spacer()
          }

          HStack {
            Button(role: .destructive, action: {
              SyncEncryptionManager.shared.resetEncryptedVaultFromUI()
            }, label: {
              Text("ResetEncryptedVault", tableName: "StorageSettings")
            })
            Spacer()
          }
        }

        Text(syncManager.statusText.isEmpty ? cloudSyncStatus.description : syncManager.statusText)
          .controlSize(.small)
          .foregroundStyle(.gray)

        Text("SyncScopeWarning", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)

        Text("EncryptionDisableWarning", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }
    }
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
