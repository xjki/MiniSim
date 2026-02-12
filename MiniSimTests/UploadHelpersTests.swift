@testable import MiniSim
import XCTest

class UploadHelpersTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
    return directoryURL
  }

  func testProcessUploadItemsSingleMissingCancels() throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let missingURL = tempDir.appendingPathComponent("missing.txt")
    var contexts: [UploadMissingContext] = []

    let result = try UploadHelpers.processUploadItems(
      selectedUrls: [missingURL],
      destinationLabel: "Downloads",
      missingItemHandler: { context in
        contexts.append(context)
        return .cancel
      },
      fileHandler: { _ in
        XCTFail("fileHandler should not be called for missing file")
      }
    )

    XCTAssertTrue(result.canceled)
    XCTAssertEqual(result.uploadedCount, 0)
    XCTAssertEqual(contexts.count, 1)
    XCTAssertEqual(contexts.first?.scope, .singleSelection)
  }

  func testProcessUploadItemsMultipleMissingIgnoreContinues() throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let existingURL = tempDir.appendingPathComponent("exists.txt")
    try Data("ok".utf8).write(to: existingURL)

    let missingURL = tempDir.appendingPathComponent("missing.txt")
    var contexts: [UploadMissingContext] = []
    var handledFiles: [URL] = []

    let result = try UploadHelpers.processUploadItems(
      selectedUrls: [missingURL, existingURL],
      destinationLabel: "Downloads",
      missingItemHandler: { context in
        contexts.append(context)
        return .ignore
      },
      fileHandler: { file in
        handledFiles.append(file.sourceURL)
      }
    )

    XCTAssertFalse(result.canceled)
    XCTAssertEqual(result.uploadedCount, 1)
    XCTAssertEqual(handledFiles, [existingURL])
    XCTAssertEqual(contexts.first?.scope, .multipleSelection)
  }

  func testProcessUploadItemsDirectoryReportsRelativeComponents() throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rootDir = tempDir.appendingPathComponent("Root", isDirectory: true)
    let subDir = rootDir.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: nil)

    let fileURL = subDir.appendingPathComponent("file.txt")
    try Data("data".utf8).write(to: fileURL)

    var capturedFile: UploadFileReference?

    let result = try UploadHelpers.processUploadItems(
      selectedUrls: [rootDir],
      destinationLabel: "Local Files",
      missingItemHandler: { _ in .ignore },
      fileHandler: { file in
        capturedFile = file
      }
    )

    XCTAssertFalse(result.canceled)
    XCTAssertEqual(result.uploadedCount, 1)
    XCTAssertEqual(capturedFile?.rootDirectoryName, "Root")
    XCTAssertEqual(capturedFile?.relativeDirectoryComponents, ["Sub"])
  }

  func testAndroidUploadPathBuilderPreservesSpaces() {
    let file = UploadFileReference(
      sourceURL: URL(fileURLWithPath: "/tmp/ai assistants.jpg"),
      rootDirectoryName: "My Folder",
      relativeDirectoryComponents: ["Sub Folder"]
    )

    let destination = AndroidUploadPathBuilder.destinationFilePath(
      for: file,
      destinationPath: "/sdcard/Download"
    )

    XCTAssertEqual(destination, "/sdcard/Download/My Folder/Sub Folder/ai assistants.jpg")
  }
}
