import AppKit
import Foundation

protocol Action {
  func execute() throws
  func showQuestionDialog() -> Bool
}

extension Action {
  func showQuestionDialog() -> Bool {
    false
  }
}

// MARK: General Actions

class CopyIDAction: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    if let deviceId = device.identifier {
      NSPasteboard.general.copyToPasteboard(text: deviceId)
      MiniSim.showSuccessMessage(title: "Device ID copied to clipboard!", message: deviceId)
    }
  }
}

class CopyNameAction: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    NSPasteboard.general.copyToPasteboard(text: device.name)
    MiniSim.showSuccessMessage(title: "Device name copied to clipboard!", message: device.name)
  }
}

class DeleteAction: Action {
  let device: Device
  let skipConfirmation: Bool

  init(device: Device, skipConfirmation: Bool = false) {
    self.device = device
    self.skipConfirmation = skipConfirmation
  }

  func showQuestionDialog() -> Bool {
    guard !skipConfirmation else { return false }
    return !NSAlert.showQuestionDialog(
      title: "Are you sure?",
      message: "Are you sure you want to delete this device?"
    )
  }

  func execute() throws {
    try self.device.delete()
    MiniSim.showSuccessMessage(title: "Device deleted!", message: self.device.name)
    NotificationCenter.default.post(name: .deviceDeleted, object: nil)
  }
}

class CustomCommandAction: Action {
  let device: Device
  let itemName: String

  init(device: Device, itemName: String) {
    self.device = device
    self.itemName = itemName
  }

  func execute() throws {
    if let command = CustomCommandService.getCustomCommand(platform: device.platform, commandName: itemName) {
      try CustomCommandService.runCustomCommand(device, command: command)
    }
  }
}

class UnsupportedAction: Action {
  private let message: String

  init(message: String) {
    self.message = message
  }

  func execute() throws {
    throw UnsupportedActionError(message: message)
  }
}

struct UnsupportedActionError: Error, LocalizedError {
  let message: String

  var errorDescription: String? {
    message
  }
}

// MARK: Android Actions

class PasteClipboardAction: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    guard let clipboard = NSPasteboard.general.pasteboardItems?.first,
          let text = clipboard.string(forType: .string) else {
      return
    }
    try ADB.sendText(device: device, text: text)
  }
}

class UploadToDownloadsAction: Action {
  let device: Device
  let destinationLabel = "Downloads"


    init(device: Device) {
    self.device = device
  }

  func execute() throws {
    guard let destinationPath = try resolveDestinationPath() else {
      NSSound.beep()
      NSAlert.showError(
        message: NSLocalizedString(
            "Downloads folder not found on device. Expected \(AndroidUploadPathBuilder.primaryDestinationPath) or \(AndroidUploadPathBuilder.fallbackDestinationPath).",
          comment: ""
        )
      )
      return
    }

    let selectedUrls = UploadHelpers.pickUploadItems(
      prompt: "Upload",
      message: "Choose files or folders to upload to \(destinationLabel)."
    )

    let result = try UploadHelpers.processUploadItems(
      selectedUrls: selectedUrls,
      destinationLabel: destinationLabel,
      missingItemHandler: UploadHelpers.promptForMissingItem
    ) { file in
      let destinationFilePath = AndroidUploadPathBuilder.destinationFilePath(
        for: file,
        destinationPath: destinationPath
      )
      try ADB.push(device: device, sourcePath: file.sourceURL.path, destinationPath: destinationFilePath)
    }

    if result.canceled || result.uploadedCount == 0 {
      return
    }
      
    // Best-effort folder content refresh for Files/MediaStore views (Files app) on Android 11+.
    // (use deprecated MediaScanner broadcast to force path reindexing)
    // See https://stackoverflow.com/questions/66929450/images-not-shown-in-photos-using-adb-push-pictures-to-android-11-emulator
    // and https://stackoverflow.com/questions/64552886/adb-push-files-are-not-showing-on-android-11-emulator
    _ = try? ADB.broadcastMediaScan(device: device, path: destinationPath)

    let uploadedLabel: String
    if result.uploadedCount == 1, let itemName = result.singleUploadedItemName {
      uploadedLabel = itemName
    } else {
      uploadedLabel = "\(result.uploadedCount) items"
    }

    MiniSim.showSuccessMessage(
      title: "Upload complete",
      message: "Uploaded \(uploadedLabel) to \(destinationPath)."
    )
  }

  private func resolveDestinationPath() throws -> String? {
    if try ADB.directoryExists(device: device, path: AndroidUploadPathBuilder.primaryDestinationPath) {
        return AndroidUploadPathBuilder.primaryDestinationPath
    }
    if try ADB.directoryExists(device: device, path: AndroidUploadPathBuilder.fallbackDestinationPath) {
        return AndroidUploadPathBuilder.fallbackDestinationPath
    }
    return nil
  }
}


class LaunchLogCat: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    try ADB.launchLogCat(device: device)
  }
}

class ColdBootCommand: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    try device.launch(additionalArgs: ["-no-snapshot"])
  }
}

class NoAudioCommand: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    try device.launch(additionalArgs: ["-no-audio"])
  }
}

class ToggleA11yCommand: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    guard let deviceId = device.identifier else {
      return
    }
    ADB.toggleAccesibility(deviceId: deviceId)
  }
}

// MARK: iOS Simulator Files Actions

enum SimulatorFilesError: Error {
  case unsupportedDevice
  case missingIdentifier
  case baseDirectoryMissing
  case storageNotFound
}

extension SimulatorFilesError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .unsupportedDevice:
      return NSLocalizedString("This action is only available for iOS simulators.", comment: "")
    case .missingIdentifier:
      return NSLocalizedString("Simulator identifier is missing.", comment: "")
    case .baseDirectoryMissing:
      return NSLocalizedString("Simulator data folder not found. Boot the simulator and try again.", comment: "")
    case .storageNotFound:
      return NSLocalizedString(
        "File Provider Storage folder not found. Boot the simulator and open the Files app once, then try again.",
        comment: ""
      )
    }
  }
}

struct SimulatorFileProviderStorage {
  static func url(for device: Device) throws -> URL {
    guard device.platform == .ios, device.type == .virtual else {
      throw SimulatorFilesError.unsupportedDevice
    }
    guard let identifier = device.identifier, !identifier.isEmpty else {
      throw SimulatorFilesError.missingIdentifier
    }

    let baseURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
      .appendingPathComponent(identifier, isDirectory: true)
      .appendingPathComponent("data/Containers/Shared/AppGroup", isDirectory: true)

    guard FileManager.default.fileExists(atPath: baseURL.path) else {
      throw SimulatorFilesError.baseDirectoryMissing
    }

    let groupUrls = try FileManager.default.contentsOfDirectory(
      at: baseURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )

    let candidates = groupUrls
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      .compactMap { groupURL -> (url: URL, identifier: String?)? in
        let isDirectory = (try? groupURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isDirectory else {
          return nil
        }

        let storageURL = groupURL.appendingPathComponent("File Provider Storage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
          return nil
        }

        let metadataURL = groupURL.appendingPathComponent(
          ".com.apple.mobile_container_manager.metadata.plist",
          isDirectory: false
        )
        let identifier = metadataIdentifier(from: metadataURL)
        return (storageURL, identifier)
      }

    if let preferred = candidates.first(where: { $0.identifier == "group.com.apple.FileProvider.LocalStorage" }) {
      return preferred.url
    }

    if let fileProvider = candidates.first(where: { ($0.identifier ?? "").contains("FileProvider") }) {
      return fileProvider.url
    }

    if let fallback = candidates.first {
      return fallback.url
    }

    throw SimulatorFilesError.storageNotFound
  }

  private static func metadataIdentifier(from metadataURL: URL) -> String? {
    guard let data = try? Data(contentsOf: metadataURL),
          let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ) as? [String: Any] else {
      return nil
    }
    return plist["MCMMetadataIdentifier"] as? String
  }
}

class UploadToSimulatorFilesAction: Action {
  let device: Device
  private let destinationLabel = "Local Files"

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    let storageURL = try SimulatorFileProviderStorage.url(for: device)

    let selectedUrls = UploadHelpers.pickUploadItems(
      prompt: "Upload",
      message: "Choose files or folders to upload to \(destinationLabel)."
    )

    let result = try UploadHelpers.processUploadItems(
      selectedUrls: selectedUrls,
      destinationLabel: destinationLabel,
      missingItemHandler: UploadHelpers.promptForMissingItem,
      directoryStartHandler: { directoryURL in
        let baseDestination = storageURL.appendingPathComponent(
          directoryURL.lastPathComponent,
          isDirectory: true
        )
        try FileManager.default.createDirectory(
          at: baseDestination,
          withIntermediateDirectories: true,
          attributes: nil
        )
      }
    ) { file in
      let destinationDir = destinationDirectory(for: file, baseURL: storageURL)
      try FileManager.default.createDirectory(
        at: destinationDir,
        withIntermediateDirectories: true,
        attributes: nil
      )
      let destinationFile = destinationDir.appendingPathComponent(
        file.sourceURL.lastPathComponent,
        isDirectory: false
      )
      try copyItemReplacingIfNeeded(from: file.sourceURL, to: destinationFile)
    }

    if result.canceled || result.uploadedCount == 0 {
      return
    }

    let uploadedLabel: String
    if result.uploadedCount == 1, let itemName = result.singleUploadedItemName {
      uploadedLabel = itemName
    } else {
      uploadedLabel = "\(result.uploadedCount) items"
    }

    MiniSim.showSuccessMessage(
      title: "Upload complete",
      message: "Uploaded \(uploadedLabel) to \(destinationLabel)."
    )
  }

  private func copyItemReplacingIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  }

  private func destinationDirectory(for file: UploadFileReference, baseURL: URL) -> URL {
    var destinationDir = baseURL
    if let rootDirectoryName = file.rootDirectoryName {
      destinationDir = destinationDir.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }
    for component in file.relativeDirectoryComponents {
      destinationDir = destinationDir.appendingPathComponent(component, isDirectory: true)
    }
    return destinationDir
  }
}

class OpenSimulatorFilesAction: Action {
  let device: Device

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    let storageURL = try SimulatorFileProviderStorage.url(for: device)

    let openAction = {
      if !NSWorkspace.shared.open(storageURL) {
        NSWorkspace.shared.activateFileViewerSelecting([storageURL])
      }
    }

    if Thread.isMainThread {
      openAction()
    } else {
      DispatchQueue.main.sync {
        openAction()
      }
    }
  }
}
