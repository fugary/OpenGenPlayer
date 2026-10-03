import XCTest
@testable import GenPlayer

final class PlaybackAudioSessionCoordinatorTests: XCTestCase {
    private final class Backend {
        enum Failure: Error { case unavailable }
        private let lock = NSLock()
        private var eventsStorage: [String] = []
        private var activeStorage = false
        var failNextActivation = false
        var failNextDeactivation = false

        var events: [String] { lock.withLock { eventsStorage } }
        var active: Bool { lock.withLock { activeStorage } }

        func activate(knownActive: Bool) throws {
            XCTAssertFalse(Thread.isMainThread)
            try lock.withLock {
                eventsStorage.append("activate:\(knownActive)")
                if failNextActivation {
                    failNextActivation = false
                    throw Failure.unavailable
                }
                activeStorage = true
            }
        }

        func deactivate() throws {
            XCTAssertFalse(Thread.isMainThread)
            try lock.withLock {
                eventsStorage.append("deactivate")
                if failNextDeactivation {
                    failNextDeactivation = false
                    throw Failure.unavailable
                }
                activeStorage = false
            }
        }

        func coordinator() -> PlaybackAudioSessionCoordinator {
            PlaybackAudioSessionCoordinator(activate: activate, deactivate: deactivate)
        }
    }

    private func activate(_ coordinator: PlaybackAudioSessionCoordinator) async -> Bool {
        await withCheckedContinuation { continuation in
            coordinator.activate { success in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: success)
            }
        }
    }

    private func deactivate(_ coordinator: PlaybackAudioSessionCoordinator) async -> Bool {
        await withCheckedContinuation { continuation in
            coordinator.deactivate { success in
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(returning: success)
            }
        }
    }

    func testOrdinaryResumePreservesKnownActivation() async {
        let backend = Backend()
        let coordinator = backend.coordinator()
        let first = await activate(coordinator)
        let second = await activate(coordinator)
        XCTAssertTrue(first && second)
        XCTAssertEqual(backend.events, ["activate:false", "activate:true"])
    }

    func testSystemInterruptionInvalidatesCachedActivation() async {
        let backend = Backend()
        let coordinator = backend.coordinator()
        _ = await activate(coordinator)
        coordinator.invalidateActivation()
        let success = await activate(coordinator)
        XCTAssertTrue(success && backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "activate:false"])
    }

    func testBackgroundResumeRequiresActivationAgain() async {
        let backend = Backend()
        let coordinator = backend.coordinator()
        _ = await activate(coordinator)
        _ = await deactivate(coordinator)
        let success = await activate(coordinator)
        XCTAssertTrue(success && backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "deactivate", "activate:false"])
    }

    func testSlowActivationCannotOvertakeBackgroundThenResume() async {
        let backend = Backend()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "audio activation is waiting in the backend")
        let coordinator = PlaybackAudioSessionCoordinator(activate: { knownActive in
            if backend.events.isEmpty {
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
            try backend.activate(knownActive: knownActive)
        }, deactivate: backend.deactivate)
        coordinator.activate { _ in }
        await fulfillment(of: [started], timeout: 2)
        coordinator.deactivate { _ in }
        let success = await withCheckedContinuation { continuation in
            coordinator.activate { continuation.resume(returning: $0) }
            gate.signal()
        }
        XCTAssertTrue(success && backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "deactivate", "activate:false"])
    }

    func testBackgroundAfterQueuedResumeLeavesAudioInactive() async {
        let backend = Backend()
        let coordinator = backend.coordinator()
        coordinator.activate { _ in }
        let success = await deactivate(coordinator)
        XCTAssertTrue(success)
        XCTAssertFalse(backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "deactivate"])
    }

    func testFailedActivationRemainsRetryable() async {
        let backend = Backend()
        backend.failNextActivation = true
        let coordinator = backend.coordinator()
        let first = await activate(coordinator)
        let second = await activate(coordinator)
        XCTAssertFalse(first)
        XCTAssertTrue(second && backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "activate:false"])
    }

    func testFailedDeactivationDoesNotSkipNextActivation() async {
        let backend = Backend()
        backend.failNextDeactivation = true
        let coordinator = backend.coordinator()
        _ = await activate(coordinator)
        let stopped = await deactivate(coordinator)
        let resumed = await activate(coordinator)
        XCTAssertFalse(stopped)
        XCTAssertTrue(resumed)
        XCTAssertEqual(backend.events, ["activate:false", "deactivate", "activate:false"])
    }

    func testSynchronousPiPPreparationUsesSameTransitionOrder() async {
        let backend = Backend()
        let coordinator = backend.coordinator()
        _ = await activate(coordinator)
        coordinator.deactivate { _ in }
        XCTAssertTrue(coordinator.activateSynchronously())
        XCTAssertTrue(backend.active)
        XCTAssertEqual(backend.events, ["activate:false", "deactivate", "activate:false"])
    }
}
