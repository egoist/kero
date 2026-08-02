//
//  AlacrittyRenderStats.swift
//  kero
//

import Foundation

/// Frame timing for the Alacritty backend, reported when `KERO_RENDER_STATS`
/// is set in the environment.
///
/// This exists because "the GPU is faster" is a claim worth checking rather
/// than assuming: it measures the two things that actually decide how a
/// terminal feels — how long a frame takes to build and submit, and how many
/// frames are avoided entirely because nothing changed.
final class AlacrittyRenderStats: @unchecked Sendable {
    static let shared = AlacrittyRenderStats()

    private static let isEnabled = ProcessInfo.processInfo.environment["KERO_RENDER_STATS"] != nil

    private let lock = NSLock()
    private var frames = 0
    private var skippedFrames = 0
    private var deferredFrames = 0
    private var suppressedFrames = 0
    private var wakeups = 0
    private var rebuiltRows = 0
    private var totalSeconds: Double = 0
    private var worstSeconds: Double = 0
    private var snapshotSeconds: Double = 0
    private var worstSnapshotSeconds: Double = 0
    private var snapshots = 0
    private var lastReport = Date()

    func frame(seconds: Double) {
        guard Self.isEnabled else { return }
        lock.lock()
        frames += 1
        totalSeconds += seconds
        worstSeconds = max(worstSeconds, seconds)
        let due = Date().timeIntervalSince(lastReport) >= 1
        lock.unlock()
        if due { report() }
    }

    /// Rows actually rebuilt this frame. The gap between this and the grid
    /// height is what row-level damage buys.
    func rebuilt(rows: Int) {
        guard Self.isEnabled else { return }
        lock.lock()
        rebuiltRows += rows
        lock.unlock()
    }

    func skipped() {
        guard Self.isEnabled else { return }
        lock.lock()
        skippedFrames += 1
        lock.unlock()
    }

    /// Frames dropped because the GPU had not caught up. Their damage is still
    /// waiting in the emulator, so a high count means output arrived faster than
    /// the display could show it, not that anything was lost.
    func deferred() {
        guard Self.isEnabled else { return }
        lock.lock()
        deferredFrames += 1
        lock.unlock()
    }

    /// Frames withheld because the program was mid-synchronized-update. Counted
    /// because they are otherwise invisible: a screen that only refreshes a few
    /// times a second looks like slow rendering, when the terminal is in fact
    /// being told not to draw yet.
    func suppressed() {
        guard Self.isEnabled else { return }
        lock.lock()
        suppressedFrames += 1
        lock.unlock()
    }

    /// Wakeups the emulator sent. Compared against `drawn`, this separates "the
    /// program is not producing output" from "output is not reaching the screen".
    func wakeup() {
        guard Self.isEnabled else { return }
        lock.lock()
        wakeups += 1
        lock.unlock()
    }

    /// Time inside `kero_alacritty_snapshot`, which both exports the grid and
    /// waits for the terminal lock the PTY thread parses under. Tracked apart
    /// from the frame total so contention is distinguishable from draw cost.
    func snapshot(seconds: Double) {
        guard Self.isEnabled else { return }
        lock.lock()
        snapshots += 1
        snapshotSeconds += seconds
        worstSnapshotSeconds = max(worstSnapshotSeconds, seconds)
        lock.unlock()
    }

    private func report() {
        lock.lock()
        let drawn = frames
        let skipped = skippedFrames
        let deferred = deferredFrames
        let suppressed = suppressedFrames
        let woke = wakeups
        let rows = rebuiltRows
        let mean = drawn > 0 ? totalSeconds / Double(drawn) * 1000 : 0
        let worst = worstSeconds * 1000
        let snapshotMean = snapshots > 0 ? snapshotSeconds / Double(snapshots) * 1000 : 0
        let snapshotWorst = worstSnapshotSeconds * 1000
        frames = 0
        skippedFrames = 0
        deferredFrames = 0
        suppressedFrames = 0
        wakeups = 0
        rebuiltRows = 0
        totalSeconds = 0
        worstSeconds = 0
        snapshots = 0
        snapshotSeconds = 0
        worstSnapshotSeconds = 0
        lastReport = Date()
        lock.unlock()

        NSLog(String(
            format: """
                kero-render woke=%d drawn=%d skipped=%d deferred=%d suppressed=%d rows=%d \
                mean=%.3fms worst=%.3fms snapshot=%.3fms/%.3fms
                """,
            woke, drawn, skipped, deferred, suppressed, rows, mean, worst,
            snapshotMean, snapshotWorst
        ))
    }
}
