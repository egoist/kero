@testable import GhosttyTerminal
import Darwin
import Foundation
import GhosttyKit
import Testing

struct InMemoryTerminalSessionOutputQueueTests {
    @Test
    func `receive returns before surface write completes`() {
        let writeStarted = DispatchSemaphore(value: 0)
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let session = makeSession { _, _ in
            writeStarted.signal()
            allowWriteToFinish.wait()
        }
        session.setSurface(testSurface(1))

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            allowWriteToFinish.signal()
        }

        let start = ProcessInfo.processInfo.systemUptime
        session.receive(Data("hello".utf8))
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 0.2)
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)
        allowWriteToFinish.signal()
        session.waitForPendingOutput()
    }

    @Test
    func `writes and process exit preserve enqueue order`() {
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            },
            processExit: { _, exitCode, runtimeMilliseconds in
                events.append("exit:\(exitCode):\(runtimeMilliseconds)")
            }
        )
        session.setSurface(testSurface(2))

        session.receive("first")
        session.receive("second")
        session.finish(exitCode: 7, runtimeMilliseconds: 42)
        session.waitForPendingOutput()

        #expect(events.values == ["first", "second", "exit:7:42"])
    }

    @Test
    func `surface teardown waits for active write and drops queued stale writes`() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWriteToFinish = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let writes = LockedValues<String>()
        let surface = SendableSurface(testSurface(3))
        let session = makeSession { _, data in
            let value = String(decoding: data, as: UTF8.self)
            writes.append(value)
            if value == "first" {
                firstWriteStarted.signal()
                allowFirstWriteToFinish.wait()
            }
        }
        session.setSurface(surface.rawValue)
        session.receive("first")
        session.receive("stale")
        #expect(firstWriteStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            session.clearSurface(ifMatches: surface.rawValue)
            clearFinished.signal()
        }

        let clearDeadline = ProcessInfo.processInfo.systemUptime + 1
        while session.currentSurface != nil,
              ProcessInfo.processInfo.systemUptime < clearDeadline
        {
            sched_yield()
        }
        #expect(session.currentSurface == nil)

        allowFirstWriteToFinish.signal()
        #expect(clearFinished.wait(timeout: .now() + 1) == .success)
        session.waitForPendingOutput()

        #expect(writes.values == ["first"])
    }

    @Test
    func `blocked session does not block another session`() {
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let allowFirstWriteToFinish = DispatchSemaphore(value: 0)
        let secondWriteFinished = DispatchSemaphore(value: 0)
        let firstSession = makeSession { _, _ in
            firstWriteStarted.signal()
            allowFirstWriteToFinish.wait()
        }
        let secondSession = makeSession { _, _ in
            secondWriteFinished.signal()
        }
        firstSession.setSurface(testSurface(4))
        secondSession.setSurface(testSurface(5))

        firstSession.receive("blocked")
        #expect(firstWriteStarted.wait(timeout: .now() + 1) == .success)
        secondSession.receive("independent")

        #expect(secondWriteFinished.wait(timeout: .now() + 1) == .success)
        allowFirstWriteToFinish.signal()
        firstSession.waitForPendingOutput()
        secondSession.waitForPendingOutput()
    }
}

private func makeSession(
    surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write
) -> InMemoryTerminalSession {
    InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in },
        surfaceWrite: surfaceWrite
    )
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private struct SendableSurface: @unchecked Sendable {
    let rawValue: ghostty_surface_t

    init(_ rawValue: ghostty_surface_t) {
        self.rawValue = rawValue
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
