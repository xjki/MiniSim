import AppKit
import Foundation
import OSLog

enum UploadMissingScope {
  case singleSelection
  case multipleSelection
  case directoryContents
}


enum UploadMissingDecision {
  case cancel
  case ignore
}


struct UploadMissingContext {
  let url: URL
  let scope: UploadMissingScope
  let destinationLabel: String
}


struct UploadFileReference {
  let sourceURL: URL
  let rootDirectoryName: String?
  let relativeDirectoryComponents: [String]
}


struct UploadProcessingResult {
  let uploadedCount: Int
  let singleUploadedItemName: String?
  let canceled: Bool
}


struct AndroidUploadPathBuilder {
  // Some manufacturers have different naming of internal-storage /sdcard/Download folder
  static let primaryDestinationPath = "/sdcard/Download"
  static let fallbackDestinationPath = "/sdcard/Downloads"
    
  static func destinationFilePath(for file: UploadFileReference, destinationPath: String) -> String {
    let remoteDir = remoteDirectory(for: file, destinationPath: destinationPath)
    return remoteDir + "/" + file.sourceURL.lastPathComponent
  }

  static func remoteDirectory(for file: UploadFileReference, destinationPath: String) -> String {
    var components = [destinationPath]
    if let rootDirectoryName = file.rootDirectoryName {
      components.append(rootDirectoryName)
    }
    if !file.relativeDirectoryComponents.isEmpty {
      components.append(contentsOf: file.relativeDirectoryComponents)
    }
    return components.joined(separator: "/")
  }
}


struct UploadHelpers {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MiniSim",
    category: "Upload"
  )

  static func pickUploadItems(prompt: String, message: String) -> [URL] {
    let openPanelAction: () -> [URL] = {
      let panel = NSOpenPanel()
      NSApp.activate(ignoringOtherApps: true)
      panel.allowsMultipleSelection = true
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.prompt = prompt
      panel.message = message
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

  static func processUploadItems(
    selectedUrls: [URL],
    destinationLabel: String,
    missingItemHandler: (UploadMissingContext) -> UploadMissingDecision = UploadHelpers.promptForMissingItem,
    directoryStartHandler: ((URL) throws -> Void)? = nil,
    fileHandler: (UploadFileReference) throws -> Void
  ) throws -> UploadProcessingResult {
    let filteredUrls = selectedUrls.filter { $0.lastPathComponent != ".DS_Store" }
    guard !filteredUrls.isEmpty else {
      return UploadProcessingResult(uploadedCount: 0, singleUploadedItemName: nil, canceled: false)
    }

    let isSingleSelection = filteredUrls.count == 1
    var uploadedCount = 0
    var singleUploadedItemName: String?
    var missingDecision: UploadMissingDecision?

    func shouldContinueAfterMissing(url: URL, scope: UploadMissingScope) -> Bool {
      logger.warning("Upload source missing: \(url.path, privacy: .public)")
      if let decision = missingDecision {
        return decision == .ignore
      }

      let decision = missingItemHandler(
        UploadMissingContext(url: url, scope: scope, destinationLabel: destinationLabel)
      )
      if decision == .ignore && scope != .singleSelection {
        missingDecision = .ignore
      }
      return decision == .ignore
    }

    func handleFile(_ file: UploadFileReference) throws {
      try fileHandler(file)
      uploadedCount += 1
      if uploadedCount == 1 {
        singleUploadedItemName = file.sourceURL.lastPathComponent
      } else {
        singleUploadedItemName = nil
      }
    }

    for url in filteredUrls {
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      guard exists else {
        let scope: UploadMissingScope = isSingleSelection ? .singleSelection : .multipleSelection
        if !shouldContinueAfterMissing(url: url, scope: scope) {
          return UploadProcessingResult(
            uploadedCount: uploadedCount,
            singleUploadedItemName: singleUploadedItemName,
            canceled: true
          )
        }
        continue
      }

      if isDirectory.boolValue {
        try directoryStartHandler?(url)
        let canceled = try processDirectory(
          directoryURL: url,
          shouldContinueAfterMissing: shouldContinueAfterMissing,
          fileHandler: handleFile
        )
        if canceled {
          return UploadProcessingResult(
            uploadedCount: uploadedCount,
            singleUploadedItemName: singleUploadedItemName,
            canceled: true
          )
        }
      } else {
        try handleFile(
          UploadFileReference(
            sourceURL: url,
            rootDirectoryName: nil,
            relativeDirectoryComponents: []
          )
        )
      }
    }

    return UploadProcessingResult(
      uploadedCount: uploadedCount,
      singleUploadedItemName: singleUploadedItemName,
      canceled: false
    )
  }

  static func promptForMissingItem(_ context: UploadMissingContext) -> UploadMissingDecision {
    let title = "File not found"
    let path = context.url.path

    switch context.scope {
    case .singleSelection:
      let message = "Selected item could not be found:\n\(path)\nUpload canceled."
      _ = NSAlert.showWarningDialog(
        title: title,
        message: message,
        primaryButton: "Cancel",
        secondaryButton: nil
      )
      return .cancel
    case .multipleSelection, .directoryContents:
      let message = "Missing item while uploading to \(context.destinationLabel):\n\(path)\nIgnore and Continue will skip this item."
      let response = NSAlert.showWarningDialog(
        title: title,
        message: message,
        primaryButton: "Cancel",
        secondaryButton: "Ignore and Continue"
      )
      return response == .alertSecondButtonReturn ? .ignore : .cancel
    }
  }

  private static func processDirectory(
    directoryURL: URL,
    shouldContinueAfterMissing: (URL, UploadMissingScope) -> Bool,
    fileHandler: (UploadFileReference) throws -> Void
  ) throws -> Bool {
    let rootDirectoryName = directoryURL.lastPathComponent
    let rootPath = directoryURL.standardizedFileURL.path
    let rootPathWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]

    guard let enumerator = FileManager.default.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [],
      errorHandler: { url, error in
        logger.error(
          "Upload enumeration error at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return true
      }
    ) else {
      logger.warning("Upload directory enumerator missing for \(directoryURL.path, privacy: .public)")
      return false
    }

    for case let fileUrl as URL in enumerator {
      if fileUrl.lastPathComponent == ".DS_Store" {
        continue
      }

      let resourceValues: URLResourceValues
      do {
        resourceValues = try fileUrl.resourceValues(forKeys: resourceKeys)
      } catch {
        logger.warning(
          "Upload source missing or unreadable: \(fileUrl.path, privacy: .public) error: \(error.localizedDescription, privacy: .public)"
        )
        if !shouldContinueAfterMissing(fileUrl, .directoryContents) {
          return true
        }
        continue
      }

      guard resourceValues.isRegularFile == true else {
        continue
      }

      let filePath = fileUrl.standardizedFileURL.path
      guard filePath.hasPrefix(rootPathWithSlash) else {
        continue
      }
      let relativePath = String(filePath.dropFirst(rootPathWithSlash.count))
      let relativeComponents = relativePath.split(separator: "/").map(String.init)
      guard !relativeComponents.isEmpty else { continue }
      let relativeDirComponents = Array(relativeComponents.dropLast())

      try fileHandler(
        UploadFileReference(
          sourceURL: fileUrl,
          rootDirectoryName: rootDirectoryName,
          relativeDirectoryComponents: relativeDirComponents
        )
      )
    }

    return false
  }
}
