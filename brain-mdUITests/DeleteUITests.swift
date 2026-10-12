//
//  DeleteUITests.swift
//  brain-mdUITests
//
//  Deleting from the sidebar, the way people do it: the context menu and ⌘⌫, for notes, nested
//  notes and attachments. Runs against a temporary vault, never the real one.
//

import XCTest

final class DeleteUITests: XCTestCase {
    private let app = XCUIApplication()

    /// The test runner is sandboxed and can't create files, so the vault is made beforehand (see
    /// docs/development-and-testing.md) and passed in BRAINMD_UI_VAULT. It must contain MenuNote.md,
    /// KeyNote.md, SearchNote.md, Folder/NestedNote.md, Attachments/menu-pic.png and Attachments/key-pic.png.
    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let vault = ProcessInfo.processInfo.environment["BRAINMD_UI_VAULT"] else {
            throw XCTSkip("Set BRAINMD_UI_VAULT to a prepared test vault")
        }
        // The arguments domain points the app at this vault without changing the saved setting.
        // AI features off hides the seeded Skills folder, so every test row fits in the window.
        app.launchArguments = ["-brain_md_vault_path", vault, "-ApplePersistenceIgnoreState", "YES", "-ai_features_enabled", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func row(_ title: String) -> XCUIElement {
        app.windows.firstMatch.staticTexts[title].firstMatch
    }

    private func waitUntilGone(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: row(title))], timeout: 3)
        XCTAssertEqual(result, .completed, "\(title) is still in the sidebar", file: file, line: line)
    }

    private func trashWithMenu(_ title: String) {
        XCTAssertTrue(row(title).waitForExistence(timeout: 5), "no sidebar row \(title)")
        row(title).rightClick()
        // The context menu's item, not File › Move to Trash in the menu bar.
        let item = app.menus.menuItems.matching(identifier: "Move to Trash").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "no Move to Trash for \(title)")
        item?.click()
        waitUntilGone(title)
    }

    private func trashWithKey(_ title: String, focusSearchFirst: Bool = false) {
        XCTAssertTrue(row(title).waitForExistence(timeout: 5), "no sidebar row \(title)")
        row(title).click()
        if focusSearchFirst {
            // The bug: with the note open and focus in the empty search field, ⌘⌫ did nothing.
            app.windows.firstMatch.textFields.firstMatch.click()
        }
        app.typeKey(.delete, modifierFlags: .command)
        waitUntilGone(title)
    }

    func testEveryKindOfItemGoesToTheTrash() {
        trashWithMenu("MenuNote")
        trashWithMenu("menu-pic.png")
        trashWithKey("KeyNote")
        trashWithKey("NestedNote")
        trashWithKey("key-pic.png")
        trashWithKey("SearchNote", focusSearchFirst: true)
    }
}
