import XCTest

#if targetEnvironment(macCatalyst)
    import AppKit
#endif

#if canImport(UIKit)
    import UIKit
#endif

final class MobileGhosttyAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        installSystemAlertHandler()
        #if !targetEnvironment(macCatalyst)
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCUIDevice.shared.orientation = .landscapeLeft
            }
        #endif
        app.launch()
    }

    override func tearDownWithError() throws {
        capture("final-state")
        app = nil
    }

    func testTerminalUserOperations() throws {
        let terminal = try requireTerminalInteractionTarget()

        capture("01-launch")
        typeTerminalText("echo ui-single\n", in: terminal)
        capture("02-single-line-input")

        typeTerminalText("echo first line\n", in: terminal)
        typeTerminalText("echo second line\n", in: terminal)
        capture("03-multiple-lines")

        typeTerminalText("中文键盘测试，标点和全角字符。\n", in: terminal)
        capture("04-chinese-input")

        typeTerminalText("日本語キーボードテスト、かなと漢字。\n", in: terminal)
        capture("05-japanese-input")

        typeTerminalText("Mixed input: English 中文 日本語 123\n", in: terminal)
        capture("06-multilingual-input")

        tapTerminal(in: terminal)
        capture("07-tap-dismiss-keyboard")
        tapTerminal(in: terminal)
        capture("08-tap-refocus")

        typeTerminalText("help\n", in: terminal)
        capture("09-help-output")

        terminal.swipeUp()
        capture("10-swipe-up")
        terminal.swipeDown()
        capture("11-swipe-down")

        #if targetEnvironment(macCatalyst)
            app.typeKey("=", modifierFlags: .command)
        #else
            terminal.pinch(withScale: 1.25, velocity: 1.0)
        #endif
        capture("12-zoom-in")
        // Use the keyboard zoom-out path on iOS because XCTest's second
        // pinch in one test session can report an invalid coordinate.
        app.typeKey("-", modifierFlags: .command)
        capture("13-zoom-out")

        typeTerminalText("clear\n", in: terminal)
        capture("14-clear-command")

        let pointerSelectionCommand: String
        #if targetEnvironment(macCatalyst)
            pointerSelectionCommand = "echo \(catalystPointerSelectionPrefix)\(expectedPointerSelection)\n"
        #else
            pointerSelectionCommand = isIPad
                ? "echo \(iPadPointerSelectionPrefix)\(expectedPointerSelection)\n"
                : "echo \(expectedPointerSelection)\n"
        #endif
        typeTerminalText(pointerSelectionCommand, in: terminal)
        #if targetEnvironment(macCatalyst)
            dragPointerSelection(in: terminal)
            capture("15-pointer-selection-catalyst")
            openCopyMenuAndCopySelection(in: terminal, screenshotName: "16-pointer-copy-menu-catalyst")
            longPressTerminal(in: terminal)
            capture("17-long-press-catalyst")
        #else
            if isIPad {
                longPressTerminal(in: terminal, offset: CGVector(dx: 0.35, dy: 0.18))
                XCTAssertTrue(selectionTextView().waitForExistence(timeout: 4))
                capture("15-long-press-selection")
                dismissSelectionSheet()

                hideSoftwareKeyboardIfVisible()
                capture("16-ipad-keyboard-hidden-before-pointer")
                dragIPadPointerSelection(in: terminal)
                capture("17-ipad-pointer-selection")
                openCopyMenuAndCopySelection(
                    in: terminal,
                    screenshotName: "18-ipad-pointer-copy-menu",
                    rightClickOffset: CGVector(dx: 0.10, dy: 0.035)
                )
            } else {
                longPressTerminal(in: terminal, offset: CGVector(dx: 0.35, dy: 0.18))
                XCTAssertTrue(selectionTextView().waitForExistence(timeout: 4))
                capture("15-long-press-selection")
            }
        #endif

        #if !targetEnvironment(macCatalyst)
            if isIPad {
                tapTerminal(in: terminal)
                tapAccessoryButton("Tab", screenshotName: "16-accessory-tab")
                tapAccessoryButton("Esc", screenshotName: "17-accessory-esc")
                tapAccessoryButton("Right", screenshotName: "18-accessory-right")
            }
        #endif

        #if targetEnvironment(macCatalyst)
            openThemeMenuAndSelectPopularTheme()
            capture("19-theme-menu-selection")
        #else
            if isIPad {
                openThemeMenuAndSelectPopularTheme()
                capture("19-theme-menu-selection")
            }
        #endif
    }

    private func installSystemAlertHandler() {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let preferredButtons = [
                "OK", "Ok", "好", "确定", "允许", "Allow", "继续", "Continue",
                "关闭", "Close", "Dismiss",
            ]
            for title in preferredButtons {
                let button = alert.buttons[title].firstMatch
                if button.exists {
                    self.activateInterruptionButton(button)
                    return true
                }
            }

            let firstButton = alert.buttons.firstMatch
            guard firstButton.exists else { return false }
            if firstButton.identifier == "InputSource" ||
                firstButton.label.hasPrefix("com.apple.inputmethod.")
            {
                self.app.typeKey(.escape, modifierFlags: [])
                return true
            }
            self.activateInterruptionButton(firstButton)
            return true
        }
    }

    private func activateInterruptionButton(_ button: XCUIElement) {
        #if targetEnvironment(macCatalyst)
            button.click()
        #else
            button.tap()
        #endif
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

    private func tapTerminal(in element: XCUIElement) {
        let coordinate = element.coordinate(withNormalizedOffset: terminalInteractionOffset)
        #if targetEnvironment(macCatalyst)
            coordinate.click()
        #else
            if isIPad {
                coordinate.tap()
            } else {
                coordinate.press(forDuration: 0.01)
            }
        #endif
    }

    private func typeTerminalText(_ text: String, in element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
            element.coordinate(withNormalizedOffset: terminalInteractionOffset).click()
            app.typeText(text)
        #else
            if !isIPad, !prepareTerminalForTyping(element) {
                return
            }
            element.typeText(text)
        #endif
    }

    #if !targetEnvironment(macCatalyst)
        private func prepareTerminalForTyping(_ element: XCUIElement) -> Bool {
            if selectionTextView().exists {
                dismissSelectionSheet()
            }
            if waitForKeyboardFocus(in: element, timeout: 0.5) {
                return true
            }

            for _ in 0 ..< 2 {
                tapTerminal(in: element)
                if selectionTextView().waitForExistence(timeout: 0.25) {
                    dismissSelectionSheet()
                }
                if waitForKeyboardFocus(in: element, timeout: 2) {
                    return true
                }
            }
            XCTFail("Terminal did not acquire keyboard focus before typing")
            return false
        }

        private func waitForKeyboardFocus(
            in element: XCUIElement,
            timeout: TimeInterval
        ) -> Bool {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                object: element
            )
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
    #endif

    private func longPressTerminal(in element: XCUIElement, offset: CGVector? = nil) {
        element.coordinate(withNormalizedOffset: offset ?? terminalInteractionOffset).press(forDuration: 0.7)
    }

    #if targetEnvironment(macCatalyst)
        private func dragPointerSelection(in element: XCUIElement) {
            log("pointer-selection-coordinates", "start=(0.008, 0.045), end=(0.42, 0.045), rightClick=(0.20, 0.045)")
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.008, dy: 0.045))
            let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.045))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    #else
        private var isIPad: Bool {
            UIDevice.current.userInterfaceIdiom == .pad
        }

        private func dragIPadPointerSelection(in element: XCUIElement) {
            log(
                "ipad-pointer-selection-coordinates",
                "frame=\(element.frame) command=echo \(iPadPointerSelectionPrefix)\(expectedPointerSelection) start=(0.015, 0.035), end=(0.205, 0.035), rightClick=(0.10, 0.035)"
            )
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.035))
            let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.205, dy: 0.035))
            start.click(forDuration: 0.1, thenDragTo: end)
        }

        private func hideSoftwareKeyboardIfVisible() {
            let hideKeyboard = app.buttons["Hide keyboard"].firstMatch
            if hideKeyboard.waitForExistence(timeout: 1), hideKeyboard.isHittable {
                hideKeyboard.tap()
                XCTAssertFalse(hideKeyboard.waitForExistence(timeout: 2))
            }
        }
    #endif

    private func openCopyMenuAndCopySelection(
        in element: XCUIElement,
        screenshotName: String,
        rightClickOffset: CGVector? = nil
    ) {
        UIPasteboard.general.string = nil
        let offset = rightClickOffset ?? CGVector(dx: 0.20, dy: 0.045)
        log("pointer-copy-menu-coordinate", "frame=\(element.frame) rightClick=(\(offset.dx), \(offset.dy))")
        element.coordinate(withNormalizedOffset: offset).rightClick()
        let copy = copyMenuItem()
        if !copy.waitForExistence(timeout: 3) {
            capture("\(screenshotName)-missing")
            XCTFail("Copy menu item not found after pointer selection right click. Hierarchy: \(app.debugDescription)")
            return
        }
        capture(screenshotName)
        activateCopyMenuItem(copy)
        let actual = copiedSelectionText(in: element, timeout: 2)
        log("pointer-selection-pasteboard", actual ?? "<nil>")
        XCTAssertEqual(actual, expectedPointerSelection)
    }

    private func activateCopyMenuItem(_ copy: XCUIElement) {
        #if targetEnvironment(macCatalyst)
            copy.click()
        #else
            copy.tap()
        #endif
    }

    private func copyMenuItem() -> XCUIElement {
        #if targetEnvironment(macCatalyst)
            app.menuItems["Copy"].firstMatch
        #else
            app.buttons["Copy"].firstMatch
        #endif
    }

    private func copiedSelectionText(in element: XCUIElement, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let string = copiedSelectionTextSnapshot(in: element, timeout: 0.25) {
                return string
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }

    private func copiedSelectionTextSnapshot(in element: XCUIElement, timeout: TimeInterval) -> String? {
        #if !targetEnvironment(macCatalyst)
            return element.value as? String
        #else
            _ = timeout
            return UIPasteboard.general.string
        #endif
    }

    private func log(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if targetEnvironment(macCatalyst)
        private var isIPad: Bool {
            false
        }
    #endif

    private var terminalInteractionOffset: CGVector {
        CGVector(dx: 0.5, dy: 0.55)
    }

    private func tapAccessoryButton(_ label: String, screenshotName: String) {
        dismissKeyboardOnboardingIfVisible()
        let button = app.buttons[label]
        guard button.waitForExistence(timeout: 2), button.isHittable else {
            capture("\(screenshotName)-not-visible")
            return
        }
        button.tap()
        capture(screenshotName)
    }

    private func dismissKeyboardOnboardingIfVisible() {
        let continueButton = app.buttons["Continue"].firstMatch
        guard continueButton.waitForExistence(timeout: 1), continueButton.isHittable else {
            return
        }
        #if targetEnvironment(macCatalyst)
            continueButton.click()
        #else
            continueButton.tap()
        #endif
    }

    private func openThemeMenuAndSelectPopularTheme() {
        let themeButton = app.buttons["terminal.themeButton"].firstMatch
        guard themeButton.waitForExistence(timeout: 2), themeButton.isHittable else {
            capture("theme-button-not-visible")
            return
        }
        themeButton.tap()
        capture("theme-menu-open")

        let popular = app.buttons["Popular"].firstMatch
        if popular.waitForExistence(timeout: 1), popular.isHittable {
            popular.tap()
            capture("theme-menu-popular")
        }

        let dracula = app.buttons["Dracula"].firstMatch
        if dracula.waitForExistence(timeout: 2), dracula.isHittable {
            dracula.tap()
        } else {
            capture("theme-dracula-not-visible")
            dismissOpenMenu()
        }
    }

    private func dismissOpenMenu() {
        #if targetEnvironment(macCatalyst)
            app.typeKey(.escape, modifierFlags: [])
        #else
            let window = app.windows.firstMatch
            guard window.exists else { return }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        #endif
    }

    private func dismissSelectionSheet() {
        let done = app.buttons["terminal.selectionDoneButton"].firstMatch
        if done.waitForExistence(timeout: 2), done.isHittable {
            done.tap()
            XCTAssertTrue(selectionTextView().waitForNonExistence(timeout: 3))
        }
    }

    private func selectionTextView() -> XCUIElement {
        app.textViews["terminal.selectionTextView"].firstMatch
    }

    private func capture(_ name: String) {
        guard let app else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var expectedPointerSelection: String {
        "selection anchor"
    }

    private var iPadPointerSelectionPrefix: String {
        // iPadOS/XCTest clamps the indirect pointer drag start a couple of
        // cells inside the view edge. The prefix keeps the single fixed drag
        // selecting the same expected terminal text without retries.
        "xx"
    }

    #if targetEnvironment(macCatalyst)
        private var catalystPointerSelectionPrefix: String {
            // Mac Catalyst clamps the left-edge pointer drag inside the first
            // text cell on GitHub runners. The prefix keeps the copied text
            // anchored to the same expected selection.
            "x"
        }
    #endif
}
