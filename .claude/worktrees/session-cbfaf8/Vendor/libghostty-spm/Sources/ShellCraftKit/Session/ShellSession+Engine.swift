import Foundation
import GhosttyTerminal

actor Engine {
    private enum EscapeState {
        case none
        case escape
        case csi(Data)
    }

    private let shell: ShellDefinition
    private let sessionBridge: SessionBridge
    private var startedAt = Date()
    private var currentInput = ""
    private var cursorPosition = 0
    private var isTerminated = false
    private var pendingText = Data()
    private var escapeState = EscapeState.none
    private var ignoreNextLineFeed = false
    private var hasStarted = false
    private var commandHistory: [String] = []
    private var historyIndex = -1
    private var savedInput = ""
    private var pendingResizeRedrawTask: Task<Void, Never>?
    private var renderedInputRevision: UInt64 = 0
    private var renderedInputState = TerminalRenderedInputState(
        totalLineCount: 1,
        cursorLineOffset: 0,
        cursorColumn: 1
    )
    private var terminalSize = InMemoryTerminalViewport(
        columns: 80,
        rows: 20,
        widthPixels: 0,
        heightPixels: 0
    )

    init(shell: ShellDefinition, sessionBridge: SessionBridge) {
        self.shell = shell
        self.sessionBridge = sessionBridge
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isTerminated = false
        startedAt = Date()
        send("\u{1B}[2J\u{1B}[H")
        send(shell.welcomeMessage)
        sendPrompt()
    }

    func updateSize(_ size: InMemoryTerminalViewport) {
        let previous = terminalSize
        terminalSize = size

        shellDebugLog(
            .metrics,
            "shell resize cols=\(previous.columns)x\(previous.rows) -> \(size.columns)x\(size.rows) pixels=\(size.widthPixels)x\(size.heightPixels)"
        )

        guard hasStarted, !isTerminated else { return }
        guard previous != size else { return }

        shellDebugLog(
            .actions,
            "shell redraw after resize input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        redrawInputLine()

        pendingResizeRedrawTask?.cancel()
        let expectedRevision = renderedInputRevision
        pendingResizeRedrawTask = Task { [self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            redrawInputLineIfViewportStable(
                size,
                expectedRevision: expectedRevision
            )
        }
    }

    func handleOutbound(_ data: Data) {
        guard !isTerminated else {
            return
        }

        for byte in data {
            handle(byte)
        }
        flushPendingText()
    }

    // MARK: - Byte Handling

    private func handle(_ byte: UInt8) {
        switch escapeState {
        case .escape:
            flushPendingText()
            if byte == 0x5B {
                escapeState = .csi(Data())
            } else if byte == 0x4F {
                escapeState = .csi(Data())
            } else {
                escapeState = .none
                // Meta/Option often arrives as ESC followed by an ASCII byte
                // (for example ESC-b / ESC-f word motion on macOS).
                handleMeta(byte)
            }
            return

        case var .csi(buffer):
            if (0x40 ... 0x7E).contains(byte) {
                escapeState = .none
                handleCSI(buffer, finalByte: byte)
            } else if buffer.count >= 64 {
                // Cap the CSI parameter buffer to guard against a peer that
                // sends ESC[ followed by an unbounded stream of intermediate
                // bytes, which would otherwise grow memory until the process
                // is killed.
                escapeState = .none
            } else {
                buffer.append(byte)
                escapeState = .csi(buffer)
            }
            return

        case .none:
            break
        }

        switch byte {
        case 0x1B:
            flushPendingText()
            escapeState = .escape

        case 0x01:
            flushPendingText()
            moveCursorToStart()

        case 0x02:
            flushPendingText()
            moveCursorLeft()

        case 0x03:
            flushPendingText()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("^C\r\n")
            sendPrompt()

        case 0x05:
            flushPendingText()
            moveCursorToEnd()

        case 0x06:
            flushPendingText()
            moveCursorRight()

        case 0x0C:
            flushPendingText()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case 0x0B:
            flushPendingText()
            killToEndOfLine()

        case 0x15:
            flushPendingText()
            killLine()

        case 0x17:
            flushPendingText()
            deleteBackwardShellWord()

        case 0x08, 0x7F:
            flushPendingText()
            deleteBackward()

        case 0x0D:
            flushPendingText()
            ignoreNextLineFeed = true
            submitCurrentInput()

        case 0x0A:
            flushPendingText()
            if ignoreNextLineFeed {
                ignoreNextLineFeed = false
                return
            }

            submitCurrentInput()

        case 0x09:
            flushPendingText()
            // The demo shell does not implement completion, but it also cannot
            // keep a literal HT byte in the line buffer because redraw and
            // cursor math operate on visible cell widths. Expanding tab to the
            // next visual stop keeps the host-managed shell stable while still
            // giving the key an observable effect for input testing.
            insertText(
                terminalExpandedTabText(
                    promptDisplayWidth: shell.promptDisplayWidth,
                    input: currentInput,
                    cursorPosition: cursorPosition,
                    terminalColumns: Int(terminalSize.columns)
                )
            )

        default:
            guard byte >= 0x20 else {
                return
            }

            pendingText.append(byte)
        }
    }

    private func handleCSI(_ params: Data, finalByte: UInt8) {
        // CSI params carry modifier suffixes such as `1;3D` for Alt-Left, so
        // dispatch on the decoded editing action instead of `finalByte` alone.
        switch terminalCSIEditingAction(params: params, finalByte: finalByte) {
        case .historyUp:
            navigateHistory(direction: .up)

        case .historyDown:
            navigateHistory(direction: .down)

        case .moveCursorRight:
            moveCursorRight()

        case .moveCursorLeft:
            moveCursorLeft()

        case .moveCursorBackwardWord:
            moveCursorBackwardWord()

        case .moveCursorForwardWord:
            moveCursorForwardWord()

        case .moveCursorToStart:
            moveCursorToStart()

        case .moveCursorToEnd:
            moveCursorToEnd()

        case .deleteForward:
            deleteForward()

        case .deleteForwardWord:
            deleteForwardWord()

        case nil:
            break
        }
    }

    // MARK: - Cursor Movement

    private func moveCursorLeft() {
        guard cursorPosition > 0 else { return }
        cursorPosition -= 1
        redrawInputLine()
    }

    private func moveCursorRight() {
        guard cursorPosition < currentInput.count else { return }
        cursorPosition += 1
        redrawInputLine()
    }

    private func moveCursorToStart() {
        guard cursorPosition > 0 else {
            return
        }
        cursorPosition = 0
        redrawInputLine()
    }

    private func moveCursorToEnd() {
        guard cursorPosition < currentInput.count else {
            return
        }
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    private func moveCursorBackwardWord() {
        let nextCursorPosition = terminalPreviousWordBoundary(
            in: currentInput,
            from: cursorPosition
        )
        guard nextCursorPosition != cursorPosition else { return }
        cursorPosition = nextCursorPosition
        redrawInputLine()
    }

    private func moveCursorForwardWord() {
        let nextCursorPosition = terminalNextWordBoundary(
            in: currentInput,
            from: cursorPosition
        )
        guard nextCursorPosition != cursorPosition else { return }
        cursorPosition = nextCursorPosition
        redrawInputLine()
    }

    // MARK: - Editing

    private func insertText(_ text: String) {
        let previousInput = currentInput
        let previousCursorPosition = cursorPosition
        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.insert(contentsOf: text, at: idx)
        cursorPosition += text.count

        if applyIncrementalAppendIfPossible(
            insertedText: text,
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition
        ) {
            return
        }

        redrawInputLine()
    }

    private func deleteBackward() {
        guard cursorPosition > 0 else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition - 1)
        currentInput.remove(at: idx)
        cursorPosition -= 1
        redrawInputLine()
    }

    private func deleteBackwardWord() {
        let result = terminalDeleteBackwardWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.cursorPosition != cursorPosition else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func deleteBackwardShellWord() {
        let result = terminalDeleteBackwardShellWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.cursorPosition != cursorPosition else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func deleteForward() {
        guard cursorPosition < currentInput.count else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.remove(at: idx)
        redrawInputLine()
    }

    private func deleteForwardWord() {
        let result = terminalDeleteForwardWord(
            input: currentInput,
            cursorPosition: cursorPosition
        )
        guard result.input != currentInput else { return }
        currentInput = result.input
        cursorPosition = result.cursorPosition
        redrawInputLine()
    }

    private func killLine() {
        guard !currentInput.isEmpty else {
            return
        }

        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0
        redrawInputLine()
    }

    private func killToEndOfLine() {
        guard cursorPosition < currentInput.count else { return }
        currentInput.removeSubrange(
            currentInput.index(currentInput.startIndex, offsetBy: cursorPosition) ..< currentInput.endIndex
        )
        redrawInputLine()
    }

    // MARK: - History

    private enum HistoryDirection {
        case up
        case down
    }

    private func navigateHistory(direction: HistoryDirection) {
        guard !commandHistory.isEmpty else {
            return
        }

        switch direction {
        case .up:
            if historyIndex < 0 {
                savedInput = currentInput
                historyIndex = commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return
            }

        case .down:
            guard historyIndex >= 0 else {
                return
            }
            if historyIndex < commandHistory.count - 1 {
                historyIndex += 1
            } else {
                historyIndex = -1
                currentInput = savedInput
                cursorPosition = currentInput.count
                redrawInputLine()
                return
            }
        }

        currentInput = commandHistory[historyIndex]
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    private func resetHistoryState() {
        historyIndex = -1
        savedInput = ""
    }

    // MARK: - Text Handling

    private func flushPendingText() {
        guard !pendingText.isEmpty else {
            return
        }

        let (text, leftover) = decodeUTF8Incrementally(pendingText)
        pendingText = leftover

        guard !text.isEmpty else {
            return
        }

        insertText(text)
    }

    private func submitCurrentInput() {
        send("\r\n")

        let command = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0

        if !command.isEmpty {
            commandHistory.append(command)
        }
        resetHistoryState()

        switch shell.processCommand(
            command,
            username: NSUserName(),
            terminalSize: terminalSize
        ) {
        case let .output(output):
            if !output.isEmpty {
                send(output)
            }
            sendPrompt()

        case .clear:
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case .exit:
            isTerminated = true
            send("logout\r\n")
            sessionBridge.session?.finish(
                exitCode: 0,
                runtimeMilliseconds: elapsedMilliseconds
            )
        }
    }

    private func sendPrompt() {
        send(shell.prompt)
        renderedInputState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        renderedInputRevision &+= 1
    }

    private func redrawInputLine() {
        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        let renderedEndState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: currentInput.count,
            terminalColumns: Int(terminalSize.columns)
        )
        let linesToClear = max(
            renderedInputState.totalLineCount,
            nextState.totalLineCount
        )

        shellDebugLog(
            .actions,
            "shell redraw promptWidth=\(shell.promptDisplayWidth) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition) previousLines=\(renderedInputState.totalLineCount) nextLines=\(nextState.totalLineCount)"
        )

        moveCursorToRenderedInputStart(renderedInputState)
        clearRenderedBlock(linesToClear)
        send(shell.prompt)
        send(currentInput)
        moveCursor(
            from: renderedEndState,
            to: nextState
        )
        renderedInputState = nextState
        renderedInputRevision &+= 1
    }

    private func redrawInputLineIfViewportStable(
        _ expectedViewport: InMemoryTerminalViewport,
        expectedRevision: UInt64
    ) {
        guard hasStarted, !isTerminated else { return }
        guard terminalSize == expectedViewport else { return }
        guard renderedInputRevision == expectedRevision else {
            shellDebugLog(
                .actions,
                "shell redraw settle skipped: revision changed expected=\(expectedRevision) actual=\(renderedInputRevision)"
            )
            return
        }

        shellDebugLog(
            .actions,
            "shell redraw settle viewport=\(expectedViewport.columns)x\(expectedViewport.rows) pixels=\(expectedViewport.widthPixels)x\(expectedViewport.heightPixels)"
        )
        redrawInputLine()
    }

    private func applyIncrementalAppendIfPossible(
        insertedText: String,
        previousInput: String,
        previousCursorPosition: Int
    ) -> Bool {
        guard canIncrementallyAppendInput(
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition,
            insertedText: insertedText
        ) else {
            return false
        }

        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )

        shellDebugLog(
            .actions,
            "shell incremental append text=\(shellDebugDescribe(insertedText)) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        send(insertedText)
        renderedInputState = nextState
        renderedInputRevision &+= 1
        return true
    }

    private func moveCursorToRenderedInputStart(
        _ state: TerminalRenderedInputState
    ) {
        send("\r")
        guard state.cursorLineOffset > 0 else { return }
        send("\u{1B}[\(state.cursorLineOffset)A\r")
    }

    private func clearRenderedBlock(_ count: Int) {
        guard count > 0 else { return }
        shellDebugLog(
            .actions,
            "shell clear rendered block lines=\(count)"
        )
        send("\u{1B}[J")
    }

    private func moveCursor(
        from current: TerminalRenderedInputState,
        to target: TerminalRenderedInputState
    ) {
        let rowDelta = current.cursorLineOffset - target.cursorLineOffset
        if rowDelta > 0 {
            send("\u{1B}[\(rowDelta)A")
        } else if rowDelta < 0 {
            send("\u{1B}[\(-rowDelta)B")
        }

        send("\u{1B}[\(target.cursorColumn)G")
    }

    private func send(_ string: String) {
        sessionBridge.session?.receive(string)
    }

    private func send(_ data: Data) {
        sessionBridge.session?.receive(data)
    }

    private var elapsedMilliseconds: UInt64 {
        UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
    }

    private func handleMeta(_ byte: UInt8) {
        switch terminalMetaEditingAction(for: byte) {
        case .moveBackwardWord:
            moveCursorBackwardWord()

        case .moveForwardWord:
            moveCursorForwardWord()

        case .deleteBackwardWord:
            deleteBackwardWord()

        case .deleteForwardWord:
            deleteForwardWord()

        case nil:
            break
        }
    }
}

enum TerminalMetaEditingAction: Equatable {
    case moveBackwardWord
    case moveForwardWord
    case deleteBackwardWord
    case deleteForwardWord
}

enum TerminalCSIEditingAction: Equatable {
    case historyUp
    case historyDown
    case moveCursorLeft
    case moveCursorRight
    case moveCursorBackwardWord
    case moveCursorForwardWord
    case moveCursorToStart
    case moveCursorToEnd
    case deleteForward
    case deleteForwardWord
}

func terminalMetaEditingAction(for byte: UInt8) -> TerminalMetaEditingAction? {
    switch byte {
    case 0x08, 0x7F:
        .deleteBackwardWord
    case 0x62:
        .moveBackwardWord
    case 0x64:
        .deleteForwardWord
    case 0x66:
        .moveForwardWord
    default:
        nil
    }
}

func terminalCSIEditingAction(
    params: Data,
    finalByte: UInt8
) -> TerminalCSIEditingAction? {
    switch finalByte {
    case 0x41: // A - Up
        return .historyUp

    case 0x42: // B - Down
        return .historyDown

    case 0x43: // C - Right
        if terminalCSIHasAltModifier(params) {
            return .moveCursorForwardWord
        }
        return .moveCursorRight

    case 0x44: // D - Left
        if terminalCSIHasAltModifier(params) {
            return .moveCursorBackwardWord
        }
        return .moveCursorLeft

    case 0x48: // H - Home
        return .moveCursorToStart

    case 0x46: // F - End
        return .moveCursorToEnd

    case 0x7E: // ~ - Extended keys
        guard let csiParams = terminalCSIParameters(params) else { return nil }
        guard csiParams.first == 3 else { return nil }
        if csiParams.hasAltModifier {
            return .deleteForwardWord
        }
        return .deleteForward

    default:
        return nil
    }
}

func terminalCSIHasAltModifier(_ params: Data) -> Bool {
    terminalCSIParameters(params)?.hasAltModifier == true
}

func terminalPreviousWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalPreviousBoundary(
        in: input,
        from: cursorPosition,
        skippingTrailingCharactersWhere: { !$0.isTerminalWordCharacter },
        consumingCharactersWhere: { $0.isTerminalWordCharacter }
    )
}

func terminalNextWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalNextBoundary(
        in: input,
        from: cursorPosition,
        skippingLeadingCharactersWhere: { !$0.isTerminalWordCharacter },
        consumingCharactersWhere: { $0.isTerminalWordCharacter }
    )
}

func terminalPreviousShellWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalPreviousBoundary(
        in: input,
        from: cursorPosition,
        skippingTrailingCharactersWhere: { $0.isTerminalWordWhitespace },
        consumingCharactersWhere: { !$0.isTerminalWordWhitespace }
    )
}

func terminalNextShellWordBoundary(
    in input: String,
    from cursorPosition: Int
) -> Int {
    terminalNextBoundary(
        in: input,
        from: cursorPosition,
        skippingLeadingCharactersWhere: { $0.isTerminalWordWhitespace },
        consumingCharactersWhere: { !$0.isTerminalWordWhitespace }
    )
}

func terminalDeleteBackwardWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let boundary = terminalPreviousWordBoundary(
        in: input,
        from: clampedCursorPosition
    )
    guard boundary < clampedCursorPosition else {
        return (input, clampedCursorPosition)
    }

    var updatedInput = input
    let start = updatedInput.index(updatedInput.startIndex, offsetBy: boundary)
    let end = updatedInput.index(
        updatedInput.startIndex,
        offsetBy: clampedCursorPosition
    )
    updatedInput.removeSubrange(start ..< end)
    return (updatedInput, boundary)
}

func terminalDeleteForwardWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let boundary = terminalNextWordBoundary(
        in: input,
        from: clampedCursorPosition
    )
    guard clampedCursorPosition < boundary else {
        return (input, clampedCursorPosition)
    }

    var updatedInput = input
    let start = updatedInput.index(
        updatedInput.startIndex,
        offsetBy: clampedCursorPosition
    )
    let end = updatedInput.index(updatedInput.startIndex, offsetBy: boundary)
    updatedInput.removeSubrange(start ..< end)
    return (updatedInput, clampedCursorPosition)
}

func terminalDeleteBackwardShellWord(
    input: String,
    cursorPosition: Int
) -> (input: String, cursorPosition: Int) {
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let boundary = terminalPreviousShellWordBoundary(
        in: input,
        from: clampedCursorPosition
    )
    guard boundary < clampedCursorPosition else {
        return (input, clampedCursorPosition)
    }

    var updatedInput = input
    let start = updatedInput.index(updatedInput.startIndex, offsetBy: boundary)
    let end = updatedInput.index(
        updatedInput.startIndex,
        offsetBy: clampedCursorPosition
    )
    updatedInput.removeSubrange(start ..< end)
    return (updatedInput, boundary)
}

func terminalCursorColumn(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int
) -> Int {
    terminalRenderedInputState(
        promptDisplayWidth: promptDisplayWidth,
        input: input,
        cursorPosition: cursorPosition,
        terminalColumns: .max
    ).cursorColumn
}

struct TerminalRenderedInputState: Equatable {
    let totalLineCount: Int
    let cursorLineOffset: Int
    let cursorColumn: Int
}

func terminalRenderedInputState(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int,
    terminalColumns: Int
) -> TerminalRenderedInputState {
    let columns = max(terminalColumns, 1)
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let totalWidth = promptDisplayWidth + input.terminalDisplayWidth
    let cursorWidth = promptDisplayWidth
        + String(input.prefix(clampedCursorPosition)).terminalDisplayWidth
    let hasTrailingContent = cursorWidth < totalWidth

    let cursorLineOffset: Int
    let cursorColumn: Int

    if cursorWidth <= 0 {
        cursorLineOffset = 0
        cursorColumn = 1
    } else if cursorWidth % columns == 0, !hasTrailingContent {
        cursorLineOffset = max((cursorWidth / columns) - 1, 0)
        cursorColumn = columns
    } else {
        cursorLineOffset = cursorWidth / columns
        cursorColumn = (cursorWidth % columns) + 1
    }

    return TerminalRenderedInputState(
        totalLineCount: wrappedTerminalLineCount(
            displayWidth: totalWidth,
            terminalColumns: columns
        ),
        cursorLineOffset: cursorLineOffset,
        cursorColumn: cursorColumn
    )
}

func wrappedTerminalLineCount(
    displayWidth: Int,
    terminalColumns: Int
) -> Int {
    let columns = max(terminalColumns, 1)
    return max(1, (max(displayWidth, 1) - 1) / columns + 1)
}

func terminalExpandedTabText(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int,
    terminalColumns: Int,
    tabWidth: Int = 8
) -> String {
    let cursorColumn = terminalRenderedInputState(
        promptDisplayWidth: promptDisplayWidth,
        input: input,
        cursorPosition: cursorPosition,
        terminalColumns: terminalColumns
    ).cursorColumn
    let zeroBasedColumn = max(cursorColumn - 1, 0)
    let spacesUntilNextStop = max(1, tabWidth - (zeroBasedColumn % tabWidth))
    return String(repeating: " ", count: spacesUntilNextStop)
}

func canIncrementallyAppendInput(
    previousInput: String,
    previousCursorPosition: Int,
    insertedText: String
) -> Bool {
    guard !insertedText.isEmpty else { return false }
    guard previousCursorPosition == previousInput.count else { return false }
    return insertedText.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}

private extension Character {
    var isTerminalWordWhitespace: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    var isTerminalWordCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
        }
    }
}

private struct TerminalCSIParameters {
    let values: [Int]

    var first: Int? {
        values.first
    }

    var hasAltModifier: Bool {
        guard let last = values.last, values.count > 1 else { return false }
        // Decode the xterm-style CSI modifier suffix (`CSI 1;<mod><final>` or
        // `CSI 3;<mod>~`) where the trailing parameter stores 1 + bitmask.
        // Bit 1 is Shift, bit 2 is Alt, and bit 4 is Control.
        return max(last - 1, 0) & 0x2 != 0
    }
}

private func terminalCSIParameters(_ params: Data) -> TerminalCSIParameters? {
    guard !params.isEmpty else { return TerminalCSIParameters(values: []) }
    guard let ascii = String(data: params, encoding: .ascii) else { return nil }
    let components = ascii.split(separator: ";")
    let values = components.compactMap { Int($0) }
    guard values.count == components.count else { return nil }
    return TerminalCSIParameters(values: values)
}

private func terminalPreviousBoundary(
    in input: String,
    from cursorPosition: Int,
    skippingTrailingCharactersWhere shouldSkipTrailing: (Character) -> Bool,
    consumingCharactersWhere shouldConsume: (Character) -> Bool
) -> Int {
    var index = input.index(
        input.startIndex,
        offsetBy: min(max(cursorPosition, 0), input.count)
    )
    while index > input.startIndex {
        let previous = input.index(before: index)
        guard shouldSkipTrailing(input[previous]) else { break }
        index = previous
    }
    while index > input.startIndex {
        let previous = input.index(before: index)
        guard shouldConsume(input[previous]) else { break }
        index = previous
    }
    return input.distance(from: input.startIndex, to: index)
}

private func terminalNextBoundary(
    in input: String,
    from cursorPosition: Int,
    skippingLeadingCharactersWhere shouldSkipLeading: (Character) -> Bool,
    consumingCharactersWhere shouldConsume: (Character) -> Bool
) -> Int {
    var index = input.index(
        input.startIndex,
        offsetBy: min(max(cursorPosition, 0), input.count)
    )
    while index < input.endIndex, shouldSkipLeading(input[index]) {
        index = input.index(after: index)
    }
    while index < input.endIndex, shouldConsume(input[index]) {
        index = input.index(after: index)
    }
    return input.distance(from: input.startIndex, to: index)
}

/// Decode as many complete UTF-8 characters as possible from raw bytes.
///
/// Returns the decoded text and any trailing bytes that form an incomplete
/// (but potentially valid) UTF-8 sequence. Invalid bytes are skipped
/// immediately — only genuinely incomplete tails are retained as leftover.
func decodeUTF8Incrementally(_ data: Data) -> (String, Data) {
    var decoded = ""
    var i = data.startIndex

    while i < data.endIndex {
        let byte = data[i]

        let sequenceLength: Int
        switch byte {
        case 0x00 ... 0x7F: sequenceLength = 1
        case 0xC2 ... 0xDF: sequenceLength = 2
        case 0xE0 ... 0xEF: sequenceLength = 3
        case 0xF0 ... 0xF4: sequenceLength = 4
        default:
            i += 1
            continue
        }

        let remaining = data.endIndex - i
        if remaining < sequenceLength {
            // Verify trailing bytes are valid continuations (0x80-0xBF).
            // If any trailing byte is NOT a continuation, the sequence can
            // never be completed — skip the lead byte and keep scanning.
            var validPrefix = true
            for j in (i + 1) ..< data.endIndex {
                if data[j] & 0xC0 != 0x80 {
                    validPrefix = false
                    break
                }
            }
            if validPrefix {
                break
            }
            i += 1
            continue
        }

        let slice = data[i ..< i + sequenceLength]
        if let char = String(data: Data(slice), encoding: .utf8) {
            decoded += char
            i += sequenceLength
        } else {
            i += 1
        }
    }

    let leftover = i < data.endIndex ? Data(data[i...]) : Data()
    return (decoded, leftover)
}

private func shellDebugLog(
    _ category: TerminalDebugCategory,
    _ message: @autoclosure () -> String
) {
    guard TerminalDebugLog.isEnabled else { return }
    guard TerminalDebugLog.categories.contains(category) else { return }
    TerminalDebugLog.sink("[ShellCraftKit] \(message())")
}

private func shellDebugDescribe(_ string: String?) -> String {
    guard let string else { return "nil" }
    let truncated = String(string.prefix(96))
    let escaped = truncated
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\u{1B}", with: "\\e")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    let suffix = string.count > truncated.count ? "..." : ""
    return "\"\(escaped)\(suffix)\""
}
