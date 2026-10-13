@testable import FluidVoice_Debug
import XCTest

private final class KeychainServiceBox: @unchecked Sendable {
    let service: KeychainService

    init(_ service: KeychainService) {
        self.service = service
    }
}

final class KeychainServiceCacheTests: XCTestCase {
    func testConcurrentStoresDoNotLoseUpdates() throws {
        let storageLock = NSLock()
        var storage: [String: String] = [:]
        let service = KeychainService(
            testingLoad: { storageLock.withLock { storage } },
            testingSave: { values in storageLock.withLock { storage = values } }
        )
        let box = KeychainServiceBox(service)
        let count = 200

        DispatchQueue.concurrentPerform(iterations: count) { index in
            try? box.service.storeKey("value-\(index)", for: "provider-\(index)")
        }

        XCTAssertEqual(try service.fetchAllKeys().count, count)
    }

    func testFailedLoadIsRetriedInsteadOfCached() throws {
        struct ExpectedFailure: Error {}

        var loadCount = 0
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                if loadCount == 1 { throw ExpectedFailure() }
                return ["openai": "secret"]
            },
            testingSave: { _ in }
        )

        XCTAssertThrowsError(try service.fetchAllKeys())
        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "secret"])
        XCTAssertEqual(loadCount, 2)
    }

    func testFetchAllKeysLoadsOncePerProcess() throws {
        var loadCount = 0
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                return ["openai": "secret"]
            },
            testingSave: { _ in }
        )

        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "secret"])
        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "secret"])
        XCTAssertEqual(loadCount, 1)
    }

    func testSuccessfulStoreVerifiesThenCacheAvoidsFurtherReads() throws {
        var loadCount = 0
        var stored: [String: String] = ["openai": "old"]
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                return stored
            },
            testingSave: { stored = $0 }
        )

        try service.storeKey(" new ", for: "groq")

        XCTAssertEqual(stored, ["openai": "old", "groq": "new"])
        XCTAssertEqual(try service.fetchAllKeys(), stored)
        XCTAssertEqual(loadCount, 2)
    }

    func testFailedStoreKeepsPreviouslyLoadedCache() throws {
        struct ExpectedFailure: Error {}

        var loadCount = 0
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                return ["openai": "old"]
            },
            testingSave: { _ in throw ExpectedFailure() }
        )

        XCTAssertThrowsError(try service.storeKey("new", for: "groq"))
        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "old"])
        XCTAssertEqual(loadCount, 1)
    }

    func testDeleteVerifiesThenCacheAvoidsFurtherReads() throws {
        var loadCount = 0
        var stored: [String: String] = ["openai": "secret", "groq": "secret"]
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                return stored
            },
            testingSave: { stored = $0 }
        )

        try service.deleteKey(for: "openai")

        XCTAssertEqual(stored, ["groq": "secret"])
        XCTAssertEqual(try service.fetchAllKeys(), stored)
        XCTAssertEqual(loadCount, 2)
    }

    func testStoreRefreshesBeforeMergingExternalChanges() throws {
        var storage = ["openai": "old"]
        let service = KeychainService(
            testingLoad: { storage },
            testingSave: { storage = $0 }
        )

        XCTAssertEqual(try service.fetchAllKeys(), storage)
        storage["anthropic"] = "external"

        try service.storeKey("new", for: "groq")

        XCTAssertEqual(
            storage,
            ["openai": "old", "anthropic": "external", "groq": "new"]
        )
        XCTAssertEqual(try service.fetchAllKeys(), storage)
    }

    func testExplicitRefreshObservesExternalChanges() throws {
        var loadCount = 0
        var storage = ["openai": "old"]
        let service = KeychainService(
            testingLoad: {
                loadCount += 1
                return storage
            },
            testingSave: { storage = $0 }
        )

        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "old"])
        storage["openai"] = "external"

        try service.refreshCachedKeys()

        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "external"])
        XCTAssertEqual(loadCount, 2)
    }

    func testCachedReadDoesNotWaitForBlockedRefresh() throws {
        let stateLock = NSLock()
        var loadCount = 0
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshFinished = self.expectation(description: "refresh finished")
        let service = KeychainService(
            testingLoad: {
                let currentLoad = stateLock.withLock {
                    loadCount += 1
                    return loadCount
                }
                if currentLoad > 1 {
                    refreshStarted.signal()
                    releaseRefresh.wait()
                }
                return ["openai": currentLoad == 1 ? "cached" : "refreshed"]
            },
            testingSave: { _ in }
        )
        let box = KeychainServiceBox(service)

        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "cached"])
        DispatchQueue.global(qos: .utility).async {
            try? box.service.refreshCachedKeys()
            refreshFinished.fulfill()
        }
        XCTAssertEqual(refreshStarted.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "cached"])

        releaseRefresh.signal()
        self.wait(for: [refreshFinished], timeout: 1)
        XCTAssertEqual(try service.fetchAllKeys(), ["openai": "refreshed"])
    }

    func testBlockedColdLoadAllowsMainContinuationAndCacheOnlyRead() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = self.expectation(description: "owned load completes")
        let mainContinued = self.expectation(description: "main continues while worker is blocked")
        let service = KeychainService(testingLoad: {
            XCTAssertFalse(Thread.isMainThread)
            started.signal()
            release.wait()
            return ["fixture": "synthetic-key"]
        }, testingSave: { _ in XCTFail("Read-only startup must not write") })
        XCTAssertTrue(service.loadInBackground { result in
            XCTAssertEqual(try? result.get(), ["fixture": "synthetic-key"])
            finished.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(service.readiness, .pending)
        XCTAssertNil(service.cachedKeys)
        XCTAssertNil(service.loadedKeys)
        DispatchQueue.main.async {
            XCTAssertNil(service.cachedKeys)
            mainContinued.fulfill()
        }
        self.wait(for: [mainContinued], timeout: 1)
        release.signal()
        self.wait(for: [finished], timeout: 1)
        XCTAssertEqual(service.readiness, .loaded)
        XCTAssertEqual(service.cachedKeys, ["fixture": "synthetic-key"])
    }

    func testStartupLoadCoalescesAndCallbackMayReenterCache() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = self.expectation(description: "single owned load")
        var loads = 0
        let service = KeychainService(testingLoad: {
            loads += 1
            started.signal()
            release.wait()
            return [:]
        }, testingSave: { _ in XCTFail("Unexpected write") })
        XCTAssertTrue(service.loadInBackground { _ in
            // The callback must run after releasing both worker state/cache locks.
            XCTAssertEqual(service.cachedKeys, [:])
            XCTAssertEqual(service.readiness, .loaded)
            finished.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        for _ in 0..<100 {
            XCTAssertFalse(service.loadInBackground { _ in XCTFail("Coalesced callback must not be admitted") })
        }
        release.signal()
        self.wait(for: [finished], timeout: 1)
        XCTAssertEqual(loads, 1)
    }

    func testUnavailableColdLoadIsUnknownAndCanRetry() {
        enum Failure: Error { case synthetic }
        var attempts = 0
        let service = KeychainService(testingLoad: {
            attempts += 1
            if attempts == 1 { throw Failure.synthetic }
            return [:]
        }, testingSave: { _ in XCTFail("Failed load must not write") })
        let failed = self.expectation(description: "unavailable")
        service.loadInBackground { result in
            if case .success = result { XCTFail("Expected failed credential operation") }
            failed.fulfill()
        }
        self.wait(for: [failed], timeout: 1)
        XCTAssertEqual(service.readiness, .unavailable)
        XCTAssertNil(service.cachedKeys)
        let retried = self.expectation(description: "loaded empty")
        service.loadInBackground { result in
            XCTAssertEqual(try? result.get(), [:])
            retried.fulfill()
        }
        self.wait(for: [retried], timeout: 1)
        XCTAssertEqual(service.readiness, .loaded)
        XCTAssertEqual(service.cachedKeys, [:])
        XCTAssertEqual(service.loadedKeys, [:])
        XCTAssertEqual(attempts, 2)
    }

    func testFailedAggregateLoadNeverWritesOrDeletesLegacyEntries() {
        enum Failure: Error { case synthetic }
        var saves = 0
        var cleanup = 0
        var legacyReads = 0
        let service = KeychainService(testingLoad: { throw Failure.synthetic }, testingSave: { _ in saves += 1 },
            testingLegacyLoad: { legacyReads += 1; return ["legacy": "synthetic-old"] },
            testingLegacyRemove: { _ in cleanup += 1 })
        let finished = self.expectation(description: "migration failed")
        service.loadInBackground(migrating: ["defaults": "synthetic-default"]) { result in
            if case .success = result { XCTFail("Expected failed credential operation") }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 1)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(legacyReads, 0)
        XCTAssertEqual(cleanup, 0)
        XCTAssertNil(service.cachedKeys)
    }

    func testMigrationPersistsAndVerifiesBeforeLegacyCleanup() {
        var storage = ["existing": "synthetic-current"]
        var operations: [String] = []
        var policies: [Bool] = []
        let service = KeychainService(testingLoad: { operations.append("read"); return storage },
            testingSave: { operations.append("save"); storage = $0 },
            testingLegacyLoad: { operations.append("legacy"); return ["legacy": " synthetic-old \n"] },
            testingLegacyRemove: { ids in
                operations.append("cleanup")
                XCTAssertEqual(ids, ["legacy"])
                XCTAssertEqual(storage["legacy"], "synthetic-old")
            }, testingAccess: { policies.append($0) })
        let finished = self.expectation(description: "verified migration")
        service.loadInBackground(migrating: ["defaults": "synthetic-default"]) { result in
            XCTAssertEqual(try? result.get(), ["existing": "synthetic-current", "legacy": "synthetic-old", "defaults": "synthetic-default"])
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 1)
        XCTAssertEqual(operations, ["read", "legacy", "save", "read", "cleanup"])
        XCTAssertEqual(policies, [false, false, false, false, false])
    }

    func testFailedPersistAndFailedVerificationBothRetainLegacy() {
        enum Failure: Error { case synthetic }
        for failsWrite in [true, false] {
            var cleanup = 0
            let service = KeychainService(testingLoad: { ["existing": "synthetic-current"] },
                testingSave: { _ in if failsWrite { throw Failure.synthetic } },
                testingLegacyLoad: { ["legacy": "synthetic-old"] },
                testingLegacyRemove: { _ in cleanup += 1 })
            let finished = self.expectation(description: "preservation on failure")
            service.loadInBackground(migrating: ["defaults": "synthetic-default"]) { result in
                if case .success = result { XCTFail("Expected failed credential operation") }
                finished.fulfill()
            }
            self.wait(for: [finished], timeout: 1)
            XCTAssertEqual(cleanup, 0)
            XCTAssertNil(service.cachedKeys)
            XCTAssertEqual(service.readiness, .unavailable)
        }
    }

    func testUserActionUsesWorkerAndPreservesUnknownAndExternalKeys() {
        var storage = ["unknown": "synthetic-secret", "known": "external-edit"]
        var policies: [Bool] = []
        let service = KeychainService(testingLoad: {
            XCTAssertFalse(Thread.isMainThread)
            return storage
        }, testingSave: { storage = $0 }, testingAccess: { policies.append($0) })
        let finished = self.expectation(description: "explicit save")
        Task {
            do {
                let result = try await service.saveForUserAction(
                    ["new": "synthetic-new", "known": "prior"], replacing: ["known": "prior"]
                )
                XCTAssertEqual(result.keys, ["unknown": "synthetic-secret", "known": "external-edit", "new": "synthetic-new"])
                XCTAssertEqual(service.cachedKeys, result.keys)
            } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 2)
        XCTAssertTrue(policies.allSatisfy { $0 })
        XCTAssertEqual(policies.count, 4)
    }

    func testExplicitReadAndDeleteAreJoinedAndKeepOtherCredentials() {
        var storage = ["remove": "synthetic-remove", "other": "synthetic-keep"]
        let service = KeychainService(testingLoad: { storage }, testingSave: { storage = $0 })
        let finished = self.expectation(description: "explicit read/delete")
        Task {
            do {
                let loaded = try await service.loadForUserAction()
                XCTAssertEqual(loaded, storage)
                let result = try await service.saveForUserAction([:], replacing: [:], removing: ["remove"])
                XCTAssertEqual(result.keys, ["other": "synthetic-keep"])
            } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 2)
    }


    func testFailedBackgroundRefreshRetainsCacheButDoesNotReportLoadedEmpty() throws {
        enum Failure: Error { case synthetic }
        var reads = 0
        let service = KeychainService(testingLoad: {
            reads += 1
            if reads > 1 { throw Failure.synthetic }
            return ["known": "synthetic-cached"]
        }, testingSave: { _ in XCTFail("Read failure must not write") })
        XCTAssertEqual(try service.fetchAllKeys(), ["known": "synthetic-cached"])
        let finished = self.expectation(description: "unavailable refresh")
        service.loadInBackground { result in
            if case .success = result { XCTFail("Expected failed refresh") }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 1)
        XCTAssertEqual(service.cachedKeys, ["known": "synthetic-cached"])
        XCTAssertNil(service.loadedKeys)
        XCTAssertEqual(service.readiness, .unavailable)
        XCTAssertEqual(reads, 2)
    }


    func testExplicitSaveRequiresSuccessfulAuthoritativeLoadBeforeWriting() {
        enum Failure: Error { case synthetic }
        let service = KeychainService(testingLoad: { throw Failure.synthetic },
            testingSave: { _ in XCTFail("Unknown aggregate must not be replaced") },
            testingLegacyLoad: { XCTFail("Failed aggregate read must abort migration"); return [:] })
        let finished = self.expectation(description: "explicit save fails closed")
        Task {
            do {
                _ = try await service.saveForUserAction(["new": "synthetic-new"], replacing: [:])
                XCTFail("Expected unavailable credentials")
            } catch { }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 2)
        XCTAssertNil(service.cachedKeys)
        XCTAssertNil(service.loadedKeys)
        XCTAssertEqual(service.readiness, .unavailable)
    }

    func testMigrationVerificationIsRetainedSeparatelyFromLaterUserEdit() {
        var storage = ["existing": "synthetic-keep"]
        let service = KeychainService(testingLoad: { storage }, testingSave: { storage = $0 })
        let finished = self.expectation(description: "migration then edit")
        Task {
            do {
                let result = try await service.saveForUserAction(
                    ["target": "synthetic-edited"], replacing: ["target": "synthetic-legacy"],
                    migrating: ["target": "synthetic-legacy"]
                )
                XCTAssertEqual(result.migratedKeys["target"], "synthetic-legacy")
                XCTAssertEqual(result.keys["target"], "synthetic-edited")
                XCTAssertEqual(result.keys["existing"], "synthetic-keep")
                XCTAssertEqual(storage, result.keys)
            } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 2)
    }

}
