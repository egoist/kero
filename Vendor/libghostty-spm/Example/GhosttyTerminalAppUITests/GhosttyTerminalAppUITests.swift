import XCTest
import AppKit

final class GhosttyTerminalAppUITests: XCTestCase {
    private var app: XCUIApplication!
    private var systemAlertMonitor: NSObjectProtocol?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        systemAlertMonitor = installSystemAlertHandler()
        app.launch()
    }

    override func tearDownWithError() throws {
        capture("final-state")
        app = nil
    }

    func testTerminalUserOperations() throws {
        let terminal = try requireTerminalInteractionTarget()

        capture("01-launch")
        clickTerminal(in: terminal)
        capture("02-focus")

        typeTerminalText("echo mac-single\n", in: terminal)
        capture("03-single-line-input")

        typeTerminalText("echo mac first line\n", in: terminal)
        typeTerminalText("echo mac second line\n", in: terminal)
        capture("04-multiple-lines")

        typeTerminalText("中文键盘测试，标点和全角字符。\n", in: terminal)
        capture("05-chinese-input")

        typeTerminalText("日本語キーボードテスト、かなと漢字。\n", in: terminal)
        capture("06-japanese-input")

        typeTerminalText("Mixed input: English 中文 日本語 123\n", in: terminal)
        capture("07-multilingual-input")

        terminal.swipeUp()
        capture("08-swipe-up")
        terminal.swipeDown()
        capture("09-swipe-down")

        app.typeKey("=", modifierFlags: .command)
        capture("10-keyboard-zoom-in")
        app.typeKey("-", modifierFlags: .command)
        capture("11-keyboard-zoom-out")

        typeTerminalText("clear\n", in: terminal)
        capture("12-clear-command")

        assertNoCopyMenuWithoutSelection(in: terminal)
        typeTerminalText("echo selection anchor\n", in: terminal)
        dragPointerSelection(in: terminal)
        capture("13-pointer-selection")
        openCopyMenuAndCopySelection(in: terminal, screenshotName: "14-pointer-copy-menu")
        longPressTerminal(in: terminal)
        capture("15-long-press")
    }

    private func requireTerminalInteractionTarget() throws -> XCUIElement {
        let terminal = app.descendants(matching: .any)["terminal.surface"].firstMatch
        if terminal.waitForExistence(timeout: 4), terminal.isHittable {
            return terminal
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        XCTAssertTrue(window.isHittable)
        return window
    }

    private func clickTerminal(in element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).click()
    }

    private func installSystemAlertHandler() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let preferredButtons = [
                "OK", "Ok", "好", "确定", "允许", "Allow", "继续", "Continue",
                "关闭", "Close", "Dismiss",
            ]
            for title in preferredButtons {
                let button = alert.buttons[title].firstMatch
                if button.exists {
                    button.click()
                    return true
                }
            }

            return false
        }
    }

    private func typeTerminalText(_ text: String, in element: XCUIElement) {
        clickTerminal(in: element)
        element.typeText(text)
    }

    private func longPressTerminal(in element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 0.7)
    }

    private func dragPointerSelection(in element: XCUIElement) {
        log("pointer-selection-coordinates", "start=(0.008, 0.10), end=(0.42, 0.10), rightClick=(0.20, 0.10)")
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.008, dy: 0.10))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.10))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func openCopyMenuAndCopySelection(in element: XCUIElement, screenshotName: String) {
        NSPasteboard.general.clearContents()
        disableSystemAlertMonitorBeforeContextMenu()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.10)).rightClick()
        let copy = copyMenuItem()
        if !copy.waitForExistence(timeout: 3) {
            capture("\(screenshotName)-missing")
            XCTFail("Copy menu item not found after pointer selection right click. Hierarchy: \(app.debugDescription)")
            return
        }
        copy.click()
        capture(screenshotName)
        let actual = copiedPasteboardText(timeout: 2)
        log("pointer-selection-pasteboard", actual ?? "<nil>")
        XCTAssertEqual(actual, "selection anchor")
    }

    private func assertNoCopyMenuWithoutSelection(in element: XCUIElement) {
        disableSystemAlertMonitorBeforeContextMenu()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.10)).rightClick()
        XCTAssertFalse(
            copyMenuItem().waitForExistence(timeout: 0.5),
            "Copy menu item appeared without an active terminal selection."
        )
    }

    private func disableSystemAlertMonitorBeforeContextMenu() {
        if let systemAlertMonitor {
            removeUIInterruptionMonitor(systemAlertMonitor)
            self.systemAlertMonitor = nil
        }
    }

    private func copyMenuItem() -> XCUIElement {
        app.menuItems["Copy"].firstMatch
    }

    private func copiedPasteboardText(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let string = NSPasteboard.general.string(forType: .string) {
                return string
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }

    private func log(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String) {
        guard let app else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
