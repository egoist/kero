//
//  MainActorIsolation.swift
//  kero
//

import Foundation

/// Runs `body` as main-actor work without asking the concurrency runtime to
/// confirm the isolation first.
///
/// Only for callbacks whose main thread is structural: AppKit invoking an
/// `NSEvent` local monitor or a view method, a `NotificationCenter` observer
/// registered on `.main`, a `Timer` on the main run loop. Where the thread is
/// merely expected, keep `MainActor.assumeIsolated` — there its trap is the
/// point.
///
/// `MainActor.assumeIsolated` re-derives a guarantee the caller already has, by
/// dereferencing Swift concurrency's per-thread executor record. That is wrong
/// twice over on an input path. It costs a heap-allocated closure box, an
/// escape check and several runtime calls for every key press and pointer move.
/// And if the record is ever left stale — an Objective-C exception unwinding
/// out of a main-actor job does it, and AppKit swallows those at the top of its
/// event loop — the dereference segfaults inside `swift_getObjectType` instead
/// of trapping cleanly.
///
/// This is `MainActor.assumeIsolated`'s body with its executor check replaced by
/// a debug-only thread check: same `unsafeBitCast` of the isolated closure to an
/// unisolated one, which is representation-preserving because isolation carries
/// no runtime component in a function value. A call site that stops being
/// main-thread still trips in Debug; release builds pay nothing.
@inline(__always)
nonisolated func assumeMainActor<T>(_ body: @MainActor () -> T) -> T {
    assert(Thread.isMainThread, "assumeMainActor off the main thread")
    return withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> T).self)()
    }
}
