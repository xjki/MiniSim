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
