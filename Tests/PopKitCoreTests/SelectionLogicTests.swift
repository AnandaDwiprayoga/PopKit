import XCTest
@testable import PopKitCore

final class SelectionGestureTests: XCTestCase {
    func testDragThreshold() {
        XCTAssertFalse(SelectionGesture.isSelectionDrag(from: .zero, to: CGPoint(x: 3, y: 3)))   // 4.2 px
        XCTAssertTrue(SelectionGesture.isSelectionDrag(from: .zero, to: CGPoint(x: 6, y: 0)))
        XCTAssertTrue(SelectionGesture.isSelectionDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 94)))
    }

    func testMultiClick() {
        XCTAssertFalse(SelectionGesture.isMultiClick(1))
        XCTAssertTrue(SelectionGesture.isMultiClick(2))
        XCTAssertTrue(SelectionGesture.isMultiClick(3))
    }

    func testSelectionKeys() {
        XCTAssertTrue(SelectionGesture.isSelectionKey(keyCode: 124, modifiers: .shift))                 // ⇧→
        XCTAssertTrue(SelectionGesture.isSelectionKey(keyCode: 123, modifiers: [.shift, .option]))      // ⇧⌥←
        XCTAssertTrue(SelectionGesture.isSelectionKey(keyCode: 0, modifiers: .command))                 // ⌘A
        XCTAssertFalse(SelectionGesture.isSelectionKey(keyCode: 124, modifiers: []))                    // →
        XCTAssertFalse(SelectionGesture.isSelectionKey(keyCode: 0, modifiers: []))                      // a
        XCTAssertFalse(SelectionGesture.isSelectionKey(keyCode: 0, modifiers: [.command, .shift]))      // ⇧⌘A
        XCTAssertFalse(SelectionGesture.isSelectionKey(keyCode: 8, modifiers: .command))                // ⌘C
    }
}

final class PopupPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 100, height: 40)

    func testAboveAndCentered() {
        let frame = PopupPlacement.frame(size: size, anchor: CGRect(x: 400, y: 300, width: 200, height: 20), visible: visible)
        XCTAssertEqual(frame.origin, CGPoint(x: 450, y: 326))
        XCTAssertEqual(frame.size, size)
    }

    func testFlipsBelowWhenNoRoomAbove() {
        let frame = PopupPlacement.frame(size: size, anchor: CGRect(x: 400, y: 770, width: 200, height: 20), visible: visible)
        XCTAssertEqual(frame.origin.y, 770 - 6 - 40)
    }

    func testClampsHorizontally() {
        let left = PopupPlacement.frame(size: size, anchor: CGRect(x: 0, y: 300, width: 10, height: 20), visible: visible)
        XCTAssertEqual(left.minX, 0)
        let right = PopupPlacement.frame(size: size, anchor: CGRect(x: 990, y: 300, width: 10, height: 20), visible: visible)
        XCTAssertEqual(right.maxX, 1000)
    }

    func testStaysOnScreenWhenAnchorIsTallerThanScreen() {
        let frame = PopupPlacement.frame(size: size, anchor: CGRect(x: 400, y: -50, width: 200, height: 900), visible: visible)
        XCTAssertTrue(visible.contains(frame))
    }

    func testZeroSizeAnchorAtMouse() {
        let frame = PopupPlacement.frame(size: size, anchor: CGRect(x: 500, y: 400, width: 0, height: 0), visible: visible)
        XCTAssertEqual(frame.midX, 500)
        XCTAssertEqual(frame.minY, 406)
    }
}

final class ActionAvailabilityTests: XCTestCase {
    private func action(_ id: String, _ requirements: ActionRequirements) -> PopupAction {
        PopupAction(id: id, title: id, icon: "x", requirements: requirements) { _, _ in .success }
    }

    func testRequirementsFilter() {
        let actions = [action("copy", .text), action("fix", [.text, .paste])]

        let editable = SelectionInfo(text: "hello", isEditable: true)
        XCTAssertEqual(PopupAction.available(actions, for: editable).map(\.id), ["copy", "fix"])

        let readOnly = SelectionInfo(text: "hello", isEditable: false)
        XCTAssertEqual(PopupAction.available(actions, for: readOnly).map(\.id), ["copy"])
    }

    func testOrderIsPreserved() {
        let actions = [action("b", .text), action("a", .text)]
        XCTAssertEqual(PopupAction.available(actions, for: SelectionInfo(text: "x", isEditable: false)).map(\.id), ["b", "a"])
    }

    func testWhitespaceOnlySelectionHasNoActions() {
        let actions = [action("copy", .text)]
        XCTAssertTrue(PopupAction.available(actions, for: SelectionInfo(text: " \n\t ", isEditable: true)).isEmpty)
    }
}

final class AppQuirksTests: XCTestCase {
    func testChromiumDetection() {
        XCTAssertTrue(AppQuirks.isChromium("com.google.Chrome"))
        XCTAssertTrue(AppQuirks.isChromium("company.thebrowser.Browser"))
        XCTAssertFalse(AppQuirks.isChromium("com.apple.Safari"))
        XCTAssertFalse(AppQuirks.isChromium(nil))
    }

    func testCopyFallback() {
        XCTAssertFalse(AppQuirks.allowsCopyFallback("com.apple.finder"))
        XCTAssertTrue(AppQuirks.allowsCopyFallback("com.apple.TextEdit"))
        XCTAssertTrue(AppQuirks.allowsCopyFallback(nil))
    }
}
