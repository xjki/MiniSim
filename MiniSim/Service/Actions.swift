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
  private let destinationPath = "/sdcard/Download"

  init(device: Device) {
    self.device = device
  }

  func execute() throws {
    let selectedUrls = pickUploadItems()
    let filteredUrls = selectedUrls.filter { $0.lastPathComponent != ".DS_Store" }
    guard !filteredUrls.isEmpty else {
      return
    }

    for url in filteredUrls {
      try uploadItem(url: url)
    }

    // Best-effort refresh for Files/MediaStore views on Android 11+.
    _ = try? ADB.broadcastMediaScan(device: device, path: destinationPath)

    let uploadedLabel: String
    if filteredUrls.count == 1 {
      uploadedLabel = filteredUrls[0].lastPathComponent
    } else {
      uploadedLabel = "\(filteredUrls.count) items"
    }

    MiniSim.showSuccessMessage(
      title: "Upload complete",
      message: "Uploaded \(uploadedLabel) to \(destinationPath)."
    )
  }

  private func uploadItem(url: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else {
      return
    }

    if isDirectory.boolValue {
      try uploadDirectory(url: url)
    } else {
      try ADB.push(device: device, sourcePath: url.path, destinationPath: destinationPath)
    }
  }

  private func uploadDirectory(url: URL) throws {
    let baseRemoteDir = destinationPath + "/" + url.lastPathComponent
    let rootComponents = url.pathComponents
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]

    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [],
      errorHandler: { _, _ in true }
    ) else {
      return
    }

    for case let fileUrl as URL in enumerator {
      if fileUrl.lastPathComponent == ".DS_Store" {
        continue
      }

      let resourceValues = try fileUrl.resourceValues(forKeys: resourceKeys)
      guard resourceValues.isRegularFile == true else {
        continue
      }

      let fileComponents = fileUrl.pathComponents
      guard fileComponents.count >= rootComponents.count else {
        continue
      }

      let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
      guard !relativeComponents.isEmpty else {
        continue
      }

      let relativeDirComponents = Array(relativeComponents.dropLast())
      let remoteDir = ([baseRemoteDir] + relativeDirComponents).joined(separator: "/")

      try ADB.push(device: device, sourcePath: fileUrl.path, destinationPath: remoteDir)
    }
  }

  private func pickUploadItems() -> [URL] {
    let openPanelAction: () -> [URL] = {
      let panel = NSOpenPanel()
      NSApp.activate(ignoringOtherApps: true)
      panel.allowsMultipleSelection = true
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.prompt = "Upload"
      panel.message = "Choose files or folders to upload to \(self.destinationPath)."
      let response = panel.runModal()
      return response == .OK ? panel.urls : []
    }

    if Thread.isMainThread {
      return openPanelAction()
    }

    return DispatchQueue.main.sync {
      openPanelAction()
    }
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
    let selectedUrls = pickUploadItems()
    let filteredUrls = selectedUrls.filter { $0.lastPathComponent != ".DS_Store" }
    guard !filteredUrls.isEmpty else {
      return
    }

    let storageURL = try SimulatorFileProviderStorage.url(for: device)

    for url in filteredUrls {
      try uploadItem(url: url, destinationURL: storageURL)
    }

    let uploadedLabel: String
    if filteredUrls.count == 1 {
      uploadedLabel = filteredUrls[0].lastPathComponent
    } else {
      uploadedLabel = "\(filteredUrls.count) items"
    }

    MiniSim.showSuccessMessage(
      title: "Upload complete",
      message: "Uploaded \(uploadedLabel) to \(destinationLabel)."
    )
  }

  private func uploadItem(url: URL, destinationURL: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else {
      return
    }

    if isDirectory.boolValue {
      try uploadDirectory(url: url, destinationURL: destinationURL)
    } else {
      let fileDestination = destinationURL.appendingPathComponent(url.lastPathComponent, isDirectory: false)
      try copyItemReplacingIfNeeded(from: url, to: fileDestination)
    }
  }

  private func uploadDirectory(url: URL, destinationURL: URL) throws {
    let baseDestination = destinationURL.appendingPathComponent(url.lastPathComponent, isDirectory: true)
    let rootComponents = url.pathComponents
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]

    try FileManager.default.createDirectory(
      at: baseDestination,
      withIntermediateDirectories: true,
      attributes: nil
    )

    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [],
      errorHandler: { _, _ in true }
    ) else {
      return
    }

    for case let fileUrl as URL in enumerator {
      if fileUrl.lastPathComponent == ".DS_Store" {
        continue
      }

      let resourceValues = try fileUrl.resourceValues(forKeys: resourceKeys)
      guard resourceValues.isRegularFile == true else {
        continue
      }

      let fileComponents = fileUrl.pathComponents
      guard fileComponents.count >= rootComponents.count else {
        continue
      }

      let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
      guard !relativeComponents.isEmpty else {
        continue
      }

      let relativeDirComponents = Array(relativeComponents.dropLast())
      let destinationDir = relativeDirComponents.reduce(baseDestination) { partial, component in
        partial.appendingPathComponent(component, isDirectory: true)
      }

      try FileManager.default.createDirectory(
        at: destinationDir,
        withIntermediateDirectories: true,
        attributes: nil
      )

      let destinationFile = destinationDir.appendingPathComponent(fileUrl.lastPathComponent, isDirectory: false)
      try copyItemReplacingIfNeeded(from: fileUrl, to: destinationFile)
    }
  }

  private func copyItemReplacingIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  }

  private func pickUploadItems() -> [URL] {
    let openPanelAction: () -> [URL] = {
      let panel = NSOpenPanel()
      NSApp.activate(ignoringOtherApps: true)
      panel.allowsMultipleSelection = true
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.prompt = "Upload"
      panel.message = "Choose files or folders to upload to \(self.destinationLabel)."
      let response = panel.runModal()
      return response == .OK ? panel.urls : []
    }

    if Thread.isMainThread {
      return openPanelAction()
    }

    return DispatchQueue.main.sync {
      openPanelAction()
    }
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
