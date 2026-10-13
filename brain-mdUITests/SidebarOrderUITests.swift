//
//  SidebarOrderUITests.swift
//  brain-mdUITests
//
//  Dragging a note above another puts it there, switches to Custom sorting, and the order is
//  still there after a relaunch. Runs against a temporary vault, never the real one.
//

import XCTest

final class SidebarOrderUITests: XCTestCase {
    private let app = XCUIApplication()
    private var vault = ""

    /// The test runner is sandboxed and can't create files, so the vault is made beforehand (see
    /// docs/development-and-testing.md) and passed in BRAINMD_SORT_VAULT. It must contain Alpha.md,
    /// Beta.md and Gamma.md, and nothing else at the root.
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["BRAINMD_SORT_VAULT"] else {
            throw XCTSkip("Set BRAINMD_SORT_VAULT to a prepared test vault")
        }
        vault = path
        launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func launch() {
        // The arguments domain points the app at this vault and starts from Name order without
        // changing the saved settings; AI features off hides the seeded Skills folder.
        app.launchArguments = [
            "-brain_md_vault_path", vault, "-ApplePersistenceIgnoreState", "YES", "-ai_features_enabled", "NO",
            "-sidebar_sort_mode", "name", "-sidebar_folders_first", "YES",
        ]
        app.launch()
    }

    private func row(_ title: String) -> XCUIElement {
        let row = app.windows.firstMatch.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no sidebar row \(title)")
        return row
    }

    private func isAbove(_ upper: String, _ lower: String) -> Bool {
        row(upper).frame.minY < row(lower).frame.minY
    }

    func testDraggingANoteAboveAnotherKeepsThatOrder() {
        XCTAssertTrue(isAbove("Alpha", "Gamma"))
        row("Gamma").press(forDuration: 0.5, thenDragTo: row("Alpha"))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.isAbove("Gamma", "Alpha") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "Gamma didn't move above Alpha")
        XCTAssertTrue(isAbove("Alpha", "Beta"))

        // The custom order comes back after a relaunch (the sort mode itself was set by the launch
        // arguments, so the drag's switch to Custom is checked through the order file instead).
        app.terminate()
        app.launchArguments = [
            "-brain_md_vault_path", vault, "-ApplePersistenceIgnoreState", "YES", "-ai_features_enabled", "NO",
            "-sidebar_sort_mode", "custom",
        ]
        app.launch()
        XCTAssertTrue(isAbove("Gamma", "Alpha"))
        XCTAssertTrue(isAbove("Alpha", "Beta"))
    }
}
