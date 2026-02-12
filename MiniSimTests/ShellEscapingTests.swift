import XCTest
@testable import MiniSim

final class ShellEscapingTests: XCTestCase {
  func testEscapeShellArgumentWithSpaces() {
    let escaped = Shell.escapeShellArgument("ai assistants.jpg")
    XCTAssertEqual(escaped, "'ai assistants.jpg'")
  }

  func testEscapeShellArgumentWithSingleQuote() {
    let escaped = Shell.escapeShellArgument("mahdi's backup")
    XCTAssertEqual(escaped, "'mahdi'\"'\"'s backup'")
  }
}
