//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private static let slowSurfaceWriteThreshold: TimeInterval = 0.5

    private let resizeLock = NSLock()
    private let surfaceAccess: InMemoryTerminalSurfaceAccess
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: Self.writeToSurface,
            processExit: Self.reportProcessExit
        )
    }

    init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
        surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write,
        processExit: @escaping InMemoryTerminalSurfaceAccess.ProcessExit =
            InMemoryTerminalSession.reportProcessExit
    ) {
        writeHandler = write
        resizeHandler = resize
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: surfaceWrite,
            processExit: processExit
        )
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        surfaceAccess.setSurface(surface)
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        guard surfaceAccess.clearSurface(ifMatches: expectedSurface) else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surfaceAccess.currentSurface == nil ? "nil" : "set")"
            )
            return
        }

        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        surfaceAccess.currentSurface
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe: keeps the surface alive for the duration of the read,
    /// preventing access against a surface mid-replacement.
    public func readViewportText() -> String? {
        surfaceAccess.withCurrentSurface { surface in
            let topLeft = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            )
            let bottomRight = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            )
            let selection = ghostty_selection_s(
                top_left: topLeft,
                bottom_right: bottomRight,
                rectangle: false
            )

            var out = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &out) else {
                return nil
            }
            defer { ghostty_surface_free_text(surface, &out) }

            guard let textPtr = out.text, out.text_len > 0 else {
                return ""
            }
            let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                .map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        } ?? nil
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Enqueue data for the terminal from the host backend.
    ///
    /// Writes are processed in order on a per-session serial queue so parsing
    /// cannot block the caller or the main thread.
    public func receive(_ data: Data) {
        guard surfaceAccess.enqueueWrite(data) else {
            TerminalDebugLog.log(
                .output,
                "terminal <- host dropped \(TerminalDebugLog.describe(data))"
            )
            return
        }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Enqueue a host-managed process exit after all previously received data.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        guard surfaceAccess.enqueueProcessExit(
            exitCode: exitCode,
            runtimeMilliseconds: runtimeMilliseconds
        ) else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        resizeLock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }

    func waitForPendingOutput() {
        surfaceAccess.waitForPendingOutput()
    }

    private static func writeToSurface(_ surface: ghostty_surface_t, _ data: Data) {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let duration = ProcessInfo.processInfo.systemUptime - start
            if duration >= slowSurfaceWriteThreshold {
                TerminalDebugLog.log(
                    .output,
                    "surface write slow bytes=\(data.count) duration=\(String(format: "%.3f", duration))s"
                )
            }
        }

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    private static func reportProcessExit(
        _ surface: ghostty_surface_t,
        _ exitCode: UInt32,
        _ runtimeMilliseconds: UInt64
    ) {
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }
}
