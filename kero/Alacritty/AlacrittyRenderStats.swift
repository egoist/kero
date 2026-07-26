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
    private var rebuiltRows = 0
    private var totalSeconds: Double = 0
    private var worstSeconds: Double = 0
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

    private func report() {
        lock.lock()
        let drawn = frames
        let skipped = skippedFrames
        let rows = rebuiltRows
        let mean = drawn > 0 ? totalSeconds / Double(drawn) * 1000 : 0
        let worst = worstSeconds * 1000
        frames = 0
        skippedFrames = 0
        rebuiltRows = 0
        totalSeconds = 0
        worstSeconds = 0
        lastReport = Date()
        lock.unlock()

        NSLog(String(
            format: "kero-render drawn=%d skipped=%d rows=%d mean=%.3fms worst=%.3fms",
            drawn, skipped, rows, mean, worst
        ))
    }
}
