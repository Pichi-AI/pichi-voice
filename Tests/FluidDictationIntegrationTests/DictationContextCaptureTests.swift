import ApplicationServices
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DictationContextCaptureTests: XCTestCase {
    func testContextDefaultsOffAndDoesNotStartCaptureWhileDisabled() {
        let key = "DictationScreenContextEnabled"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        let settings = SettingsStore.shared
        XCTAssertFalse(settings.dictationScreenContextEnabled)
        settings.dictationScreenContextEnabled = true
        XCTAssertTrue(settings.dictationScreenContextEnabled)
        settings.dictationScreenContextEnabled = false
        XCTAssertNil(DictationContextCapture.start(target: self.target(), textBeforeCursor: "private", settings: settings))
    }

    func testDisabledContextReadsNeitherCursorNorScreen() async {
        let request = self.request(isEnabled: false)
        let context = await DictationContextReader.read(request) { _, _ in
            XCTFail("Screen context Off must prevent screenshots")
            return ["unexpected screen text"]
        }
        XCTAssertNil(context)
    }

    func testEnabledContextAutomaticallyUsesOCRWhenAppTextIsMissing() async {
        let request = DictationContextReader.Request(
            pid: 999_999,
            bundleID: "test.context",
            window: AXUIElementCreateApplication(999_999),
            element: nil,
            textBeforeCursor: "Known cursor text",
            isEnabled: true
        )
        let context = await DictationContextReader.read(request, readElement: { _ in
            .init(role: "AXWindow", isSecure: false, texts: [], frame: nil, children: [], hasCompletePrivacyMetadata: true)
        }) { _, window in
            XCTAssertNotNil(window)
            return ["A name from the target window"]
        }
        XCTAssertEqual(context?.textBeforeCursor, "Known cursor text")
        XCTAssertEqual(context?.screenText, ["A name from the target window"])
    }

    func testAttributeDecoderDoesNotTreatFailedContainerChildrenAsEmpty() async {
        for role in ["AXWindow", "AXGroup"] {
            let failures = [self.attributeError(.cannotComplete), self.attributeError(.invalidUIElement), self.attributeError(.failure), NSNull()]
            for failure in failures {
                var attributes = self.accessibilityAttributes(role: role)
                attributes[7] = failure
                let item = DictationContextReader.decodeElementText(attributes)
                XCTAssertEqual(item?.role, role)
                XCTAssertEqual(item?.hasCompletePrivacyMetadata, false)
                await self.assertDecodedNodeSuppressesOCR(item)
            }
        }
    }

    func testAttributeDecoderAcceptsTypedEmptyChildren() async {
        let item = DictationContextReader.decodeElementText(self.accessibilityAttributes(role: "AXWindow"))
        XCTAssertEqual(item?.hasCompletePrivacyMetadata, true)
        let fixture = ContextAccessibilityFixture()
        let lines = await DictationContextReader.recognizeWindowIfSafe(
            pid: 999_999, window: fixture.window, wordCount: 0,
            hasCompletePrivacyMetadata: item?.hasCompletePrivacyMetadata == true
        ) { _, _ in ["Public OCR fallback"] }
        XCTAssertEqual(lines, ["Public OCR fallback"])
    }

    func testAttributeDecoderAllowsMissingNonTextSubroleAndOptionalAttributes() async {
        let absentSubroles = [self.attributeError(.attributeUnsupported), self.attributeError(.noValue), NSNull()]
        for absent in absentSubroles {
            var attributes = self.accessibilityAttributes(role: "AXWindow")
            attributes[1] = absent
            for index in [2, 3, 4, 5, 6, 8] { attributes[index] = self.attributeError(.attributeUnsupported) }
            let item = DictationContextReader.decodeElementText(attributes)
            XCTAssertEqual(item?.hasCompletePrivacyMetadata, true)
            XCTAssertEqual(item?.texts, [])
            let fixture = ContextAccessibilityFixture()
            let lines = await DictationContextReader.recognizeWindowIfSafe(
                pid: 999_999, window: fixture.window, wordCount: 0,
                hasCompletePrivacyMetadata: item?.hasCompletePrivacyMetadata == true
            ) { _, _ in ["Public OCR fallback"] }
            XCTAssertEqual(lines, ["Public OCR fallback"])
        }
    }

    func testAttributeDecoderDoesNotAssumeUnsupportedStaticTextHasNoChildren() async {
        var attributes = self.accessibilityAttributes(role: "AXStaticText")
        attributes[1] = self.attributeError(.attributeUnsupported)
        attributes[7] = self.attributeError(.attributeUnsupported)
        let item = DictationContextReader.decodeElementText(attributes)
        XCTAssertEqual(item?.texts, ["Public label"])
        XCTAssertEqual(item?.hasCompletePrivacyMetadata, false, "Unsupported children are not a successful empty children array")
        await self.assertDecodedNodeSuppressesOCR(item)
    }

    func testAttributeDecoderDropsTextEntryValuesWhenSubroleIsUncertain() async {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            let failures = [self.attributeError(.cannotComplete), self.attributeError(.attributeUnsupported), self.attributeError(.noValue), self.attributeError(.failure), NSNull()]
            for failure in failures {
                var attributes = self.accessibilityAttributes(role: role)
                attributes[1] = failure
                attributes[2] = "Protected value" as NSString
                attributes[3] = "Protected title" as NSString
                attributes[7] = [ContextAccessibilityFixture().field] as NSArray
                let item = DictationContextReader.decodeElementText(attributes)
                XCTAssertEqual(item?.hasCompletePrivacyMetadata, false)
                XCTAssertEqual(item?.texts, [], "An unknown security subrole must not publish a field value or title")
                XCTAssertEqual(item?.children.count, 0, "Do not descend inside a field that might be secure")
                await self.assertDecodedNodeSuppressesOCR(item)
            }
        }
    }

    func testSecureSiblingPreventsWholeWindowOCR() async {
        let fixture = ContextAccessibilityFixture()
        let request = fixture.request
        let context = await DictationContextReader.read(request, readElement: { element in
            if CFEqual(element, fixture.window) {
                return .init(role: "AXWindow", isSecure: false, texts: [], frame: nil, children: [fixture.field, fixture.sibling], hasCompletePrivacyMetadata: true)
            }
            if CFEqual(element, fixture.field) {
                return .init(role: "AXTextField", isSecure: false, texts: ["Public field"], frame: nil, children: [], hasCompletePrivacyMetadata: true)
            }
            return .init(role: "AXSecureTextField", isSecure: true, texts: ["Protected secret"], frame: nil, children: [], hasCompletePrivacyMetadata: true)
        }) { _, _ in
            XCTFail("A secure sibling must suppress whole-window OCR in an ordinary app")
            return ["Protected secret from screenshot"]
        }
        XCTAssertEqual(context?.textBeforeCursor, "Public cursor")
        XCTAssertEqual(context?.screenText, ["Public field"])
    }

    func testUnknownDescendantPreventsWholeWindowOCR() async {
        let fixture = ContextAccessibilityFixture()
        for hasUnknownRole in [false, true] {
            let context = await DictationContextReader.read(fixture.request, readElement: { element in
                if CFEqual(element, fixture.window) {
                    return .init(role: "AXWindow", isSecure: false, texts: ["Public label"], frame: nil, children: [fixture.sibling], hasCompletePrivacyMetadata: true)
                }
                return hasUnknownRole ? .init(role: "", isSecure: false, texts: [], frame: nil, children: [], hasCompletePrivacyMetadata: true) : nil
            }) { _, _ in
                XCTFail("An unreadable descendant cannot establish that whole-window OCR is safe")
                return ["Unexpected screenshot"]
            }
            XCTAssertEqual(context?.textBeforeCursor, "Public cursor")
            XCTAssertEqual(context?.screenText, ["Public label"])
        }
    }

    func testTruncatedAccessibilityWalkPreventsWholeWindowOCR() async {
        let fixture = ContextAccessibilityFixture()
        let context = await DictationContextReader.read(fixture.request, readElement: { element in
            .init(role: "AXWindow", isSecure: false, texts: [], frame: nil,
                  children: CFEqual(element, fixture.window) ? Array(repeating: fixture.sibling, count: 4001) : [], hasCompletePrivacyMetadata: true)
        }) { _, _ in
            XCTFail("A bounded walk that omitted children must not admit a screenshot")
            return ["Unexpected screenshot"]
        }
        XCTAssertEqual(context?.textBeforeCursor, "Public cursor")
        XCTAssertNil(context?.screenText)
    }

    func testMissingCapturedWindowNeverFallsBackToAnotherWindow() async {
        let context = await DictationContextReader.read(self.request(isEnabled: true)) { _, _ in
            XCTFail("A missing target window must not fall back to another window")
            return ["unexpected screen text"]
        }
        XCTAssertNil(context?.screenText)
    }

    func testPasswordManagerDropsCursorAndScreenContext() async {
        let context = await DictationContextReader.read(self.request(bundleID: "com.1password", isEnabled: true)) { _, _ in
            XCTFail("Private apps must not invoke OCR")
            return []
        }
        XCTAssertNil(context)
    }

    func testCursorContextIsBounded() async {
        let request = DictationContextReader.Request(
            pid: 999_999,
            bundleID: "test.context",
            window: nil,
            element: nil,
            textBeforeCursor: String(repeating: "a", count: 2100) + "end",
            isEnabled: true
        )
        let context = await DictationContextReader.read(request)
        XCTAssertEqual(context?.textBeforeCursor?.count, 2000)
        XCTAssertTrue(context?.textBeforeCursor?.hasSuffix("end") == true)
    }

    func testOCRSelectsOnlyTheMatchingAppWindow() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let windows = [
            self.windowInfo(id: 1, pid: 999, frame: frame),
            self.windowInfo(id: 2, frame: frame.offsetBy(dx: 200, dy: 0)),
            self.windowInfo(id: 3, frame: frame, layer: 1),
            self.windowInfo(id: 4, frame: frame),
        ]
        XCTAssertEqual(DictationContextReader.windowID(pid: 101, frame: frame, windows: windows), 4)
    }

    func testOCRSkipsIdenticalWindowsRegardlessOfStackingOrder() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let first = self.windowInfo(id: 1, frame: frame)
        let second = self.windowInfo(id: 2, frame: frame)
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: [first, second]))
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: [second, first]))
    }

    func testOCRSkipsWindowsThatAreAmbiguousWithinBoundsTolerance() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let windows = [self.windowInfo(id: 1, frame: frame), self.windowInfo(id: 2, frame: frame.offsetBy(dx: 1, dy: 1))]
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: windows))
    }

    func testOCRDoesNotUseAnotherWindowAfterTargetDisappears() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let remaining = [self.windowInfo(id: 2, frame: frame.offsetBy(dx: 200, dy: 0))]
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: remaining))
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: nil, windows: remaining))
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: .zero, windows: remaining))
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: []))
    }

    func testOCRSkipsIncompleteWindowMetadata() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        var missingID = self.windowInfo(id: 1, frame: frame)
        missingID.removeValue(forKey: kCGWindowNumber as String)
        var missingBounds = self.windowInfo(id: 2, frame: frame)
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: [missingID]))
        XCTAssertNil(DictationContextReader.windowID(pid: 101, frame: frame, windows: [missingBounds]))
    }

    func testShortScrolledFieldIncludesOnlyVisibleWords() {
        let value = "hidden above\nVisible name\nhidden below"
        let range = (value as NSString).range(of: "Visible name")
        XCTAssertEqual(DictationContextReader.textEntryValue(value, visibleRange: CFRange(location: range.location, length: range.length)), "Visible name")
    }

    func testLongScrolledFieldIncludesOnlyVisibleWords() {
        let value = String(repeating: "hidden ", count: 1000) + "Visible name"
        let range = (value as NSString).range(of: "Visible name")
        XCTAssertEqual(DictationContextReader.textEntryValue(value, visibleRange: CFRange(location: range.location, length: range.length)), "Visible name")
    }

    func testVisibleRangeUsesUTF16Offsets() {
        let value = "👋 hidden\nZoë 🐈\nhidden"
        let range = (value as NSString).range(of: "Zoë 🐈")
        XCTAssertEqual(DictationContextReader.textEntryValue(value, visibleRange: CFRange(location: range.location, length: range.length)), "Zoë 🐈")
    }

    func testEmptyOrInvalidVisibleRangeNeverExposesTheFullValue() {
        for range in [
            CFRange(location: 0, length: 0), CFRange(location: -1, length: 1),
            CFRange(location: 0, length: -1), CFRange(location: 99, length: 1),
            CFRange(location: 5, length: Int.max), CFRange(location: Int.max, length: 1),
        ] {
            XCTAssertEqual(DictationContextReader.textEntryValue("hidden text", visibleRange: range), "")
        }
    }

    func testMissingVisibleRangeKeepsOnlyTheBoundedFallback() {
        XCTAssertEqual(DictationContextReader.textEntryValue("Short field", visibleRange: nil), "Short field")
        XCTAssertEqual(DictationContextReader.textEntryValue(String(repeating: "x", count: 4001), visibleRange: nil), "")
    }

    func testReadyContextReturnsAndCancelsItsTimeout() async throws {
        let expected = DictationTypingContext(textBeforeCursor: "ready", screenText: ["visible"])
        let task = Task<DictationTypingContext?, Never> { expected }
        _ = await task.value
        let capture = DictationContextCapture(target: self.target(), task: task)
        let result = await capture.result(timeout: .milliseconds(100))
        XCTAssertEqual(result, expected)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(task.isCancelled, "A finished read must not retain an active timeout")
    }

    func testCancellationBeforeWaitingDropsReadyContext() async {
        let task = Task<DictationTypingContext?, Never> { .init(textBeforeCursor: "stale", screenText: nil) }
        _ = await task.value
        let capture = DictationContextCapture(target: self.target(), task: task)
        capture.cancel()
        let result = await capture.result(timeout: .seconds(1))
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
    }

    func testTimeoutDropsLateResultAndCancelsReader() async {
        let task = self.delayedRead()
        let capture = DictationContextCapture(target: self.target(), task: task)
        let result = await capture.result(timeout: .milliseconds(10))
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    func testCancellingWaiterCancelsReaderWithoutWaitingForTimeout() async {
        let task = self.delayedRead()
        let capture = DictationContextCapture(target: self.target(), task: task)
        let waiter = Task { await capture.result(timeout: .seconds(10)) }
        await Task.yield()
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
    }

    func testTimeoutKeepsReaderAdmissionClosedUntilCleanupIsJoined() async {
        let reader = SuspendedContextRead()
        guard let capture = DictationContextCapture.start(target: self.target(), read: { await reader.read() }) else {
            return XCTFail("The synthetic reader should own the empty admission slot")
        }
        await reader.waitUntilStarted()
        let result = await capture.result(timeout: .milliseconds(5))
        XCTAssertNil(result, "The consumer deadline must not wait for suspended cleanup")
        for _ in 0..<20 {
            let replacement = DictationContextCapture.start(target: self.target()) {
                XCTFail("No replacement may read while old cleanup is suspended")
                return nil
            }
            XCTAssertNil(replacement, "Optional context must be skipped instead of queued")
        }
        let retirement = ContextRetirementState()
        let join = Task {
            await retirement.started()
            await capture.cancelAndWait()
            await retirement.finished()
        }
        await retirement.waitUntilStarted()
        let prematureFinish = await retirement.hasFinished
        XCTAssertFalse(prematureFinish)
        await reader.finish(.init(textBeforeCursor: "Late canceled context", screenText: nil))
        await join.value
        let stale = await capture.result(timeout: .seconds(1))
        XCTAssertNil(stale)
        let expected = DictationTypingContext(textBeforeCursor: "New context", screenText: nil)
        let replacement = DictationContextCapture.start(target: self.target()) { expected }
        XCTAssertNotNil(replacement, "Admission should reopen after the original reader returned")
        let fresh = await replacement?.result(timeout: .seconds(1))
        XCTAssertEqual(fresh, expected)
        await replacement?.cancelAndWait()
    }

    func testCancelledConsumerDoesNotReleaseSuspendedReader() async {
        let reader = SuspendedContextRead()
        guard let capture = DictationContextCapture.start(target: self.target(), read: { await reader.read() }) else {
            return XCTFail("The synthetic reader should own the empty admission slot")
        }
        await reader.waitUntilStarted()
        let waiter = Task { await capture.result(timeout: .seconds(10)) }
        await Task.yield()
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result)
        let overlap = DictationContextCapture.start(target: self.target()) {
            XCTFail("A canceled consumer must not allow overlapping screen reads")
            return nil
        }
        XCTAssertNil(overlap)
        let retirement = ContextRetirementState()
        let join = Task {
            await retirement.started()
            await capture.cancelAndWait()
            await retirement.finished()
        }
        await retirement.waitUntilStarted()
        let prematureFinish = await retirement.hasFinished
        XCTAssertFalse(prematureFinish)
        await reader.finish(.init(textBeforeCursor: "Ignored late value", screenText: ["Ignored late line"]))
        await join.value
        let stale = await capture.result(timeout: .seconds(1))
        XCTAssertNil(stale)
        let replacement = DictationContextCapture.start(target: self.target()) { nil }
        XCTAssertNotNil(replacement)
        await replacement?.cancelAndWait()
    }

    func testCancelAfterReaderCompletionStillInvalidatesUnconsumedContext() async {
        let task = Task<DictationTypingContext?, Never> { .init(textBeforeCursor: "Unconsumed context", screenText: nil) }
        let capture = DictationContextCapture(target: self.target(), task: task)
        _ = await task.value
        await Task.yield()
        capture.cancel()
        let result = await capture.result(timeout: .seconds(1))
        XCTAssertNil(result)
        await capture.cancelAndWait()
    }

    func testTargetMatchRequiresSameFieldAndWindow() {
        let field = AXUIElementCreateApplication(101)
        let window = AXUIElementCreateApplication(102)
        let original = self.target(window: window, element: field)
        let capture = DictationContextCapture(target: original, task: Task { nil })
        XCTAssertTrue(capture.matches(original))
        XCTAssertTrue(capture.matches(self.target(window: window, element: field)))
        XCTAssertFalse(capture.matches(self.target(window: window, element: AXUIElementCreateApplication(103))))
        XCTAssertFalse(capture.matches(self.target(window: AXUIElementCreateApplication(104), element: field)))
        XCTAssertFalse(capture.matches(self.target(pid: 2, window: window, element: field)))
        XCTAssertFalse(capture.matches(self.target()))
    }

    func testNewCaptureDoesNotReceiveCancelledResult() async {
        let stale = DictationContextCapture(target: self.target(), task: self.delayedRead())
        stale.cancel()
        let expected = DictationTypingContext(textBeforeCursor: "new recording", screenText: nil)
        let current = DictationContextCapture(target: self.target(), task: Task { expected })
        let result = await current.result(timeout: .seconds(1))
        let cancelledResult = await stale.result(timeout: .seconds(1))
        XCTAssertEqual(result, expected)
        XCTAssertNil(cancelledResult)
    }

    func testPermissionRefreshNeverPrompts() async {
        var requests = 0
        let permission = DictationScreenPermissionController(check: { false }, request: {
            requests += 1
            return false
        })
        await permission.refresh()
        XCTAssertTrue(permission.hasChecked)
        XCTAssertFalse(permission.isAllowed)
        XCTAssertEqual(requests, 0)
    }

    func testChangingContextToggleNeverRequestsPermission() async {
        let key = "DictationScreenContextEnabled"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let prompted = self.expectation(description: "The feature toggle must never prompt")
        prompted.isInverted = true
        let permission = DictationScreenPermissionController(check: { false }, request: {
            prompted.fulfill()
            return true
        })
        let settings = SettingsStore.shared
        let view = DictationScreenContextSettings(settings: settings, isBusy: false, permission: permission)
        view.enabledBinding.wrappedValue = true
        XCTAssertTrue(settings.dictationScreenContextEnabled)
        await self.fulfillment(of: [prompted], timeout: 0.2)
        XCTAssertFalse(permission.hasChecked)
        XCTAssertFalse(permission.isAllowed)
        view.enabledBinding.wrappedValue = false
        XCTAssertFalse(settings.dictationScreenContextEnabled)
    }

    func testExplicitPermissionActionRequestsMissingAccess() async {
        var requests = 0
        let permission = DictationScreenPermissionController(check: { false }, request: {
            requests += 1
            return true
        })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
        XCTAssertFalse(permission.requiresSettings)
        XCTAssertEqual(requests, 1)
    }

    func testDeniedPermissionReturnsToAnIdleState() async {
        let permission = DictationScreenPermissionController(check: { false }, request: { false })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.hasChecked)
        XCTAssertFalse(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
        XCTAssertTrue(permission.requiresSettings)
    }

    func testGrantedPermissionDoesNotPromptAgain() async {
        let permission = DictationScreenPermissionController(check: { true }, request: {
            XCTFail("An existing grant must not prompt again")
            return false
        })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.isAllowed)
        XCTAssertFalse(permission.requiresSettings)
    }

    func testRequestEligibilityIsRecheckedBeforePrompt() async {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var enabled = true
        let permission = DictationScreenPermissionController(check: {
            started.signal()
            _ = resume.wait(timeout: .now() + 2)
            return false
        }, request: {
            XCTFail("An ineligible action must not show a pending permission request")
            return true
        })
        let request = Task { await permission.requestIfNeeded { enabled } }
        let didStart = await Task.detached { Self.waitForSignal(started) }.value
        XCTAssertTrue(didStart)
        enabled = false
        resume.signal()
        await request.value
        XCTAssertFalse(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
    }

    func testReturningFromSystemSettingsUpdatesGrantedStatusWithoutPrompting() async {
        let state = ScreenPermissionCheck()
        var requests = 0
        let permission = DictationScreenPermissionController(check: { state.isAllowed }, request: {
            requests += 1
            return false
        })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.requiresSettings)
        state.isAllowed = true
        await permission.refresh()
        XCTAssertTrue(permission.isAllowed)
        XCTAssertFalse(permission.requiresSettings)
        XCTAssertEqual(requests, 1)
    }

    func testRevokedPermissionRemovesGrantedStatusWithoutPrompting() async {
        let state = ScreenPermissionCheck()
        state.isAllowed = true
        let permission = DictationScreenPermissionController(check: { state.isAllowed }, request: {
            XCTFail("Revoked permission must not trigger an automatic request")
            return true
        })
        await permission.refresh()
        XCTAssertTrue(permission.isAllowed)
        state.isAllowed = false
        await permission.refresh()
        XCTAssertFalse(permission.isAllowed)
        XCTAssertTrue(permission.requiresSettings)
    }

    func testLeavingSettingsCancelsPromptAndAllowsFreshPermissionCheck() async {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let state = ScreenPermissionCheck()
        let permission = DictationScreenPermissionController(check: {
            if state.isAllowed { return true }
            started.signal()
            _ = resume.wait(timeout: .now() + 2)
            return false
        }, request: {
            XCTFail("A cancelled action must not open the permission prompt")
            return true
        })
        let request = Task { await permission.requestIfNeeded { true } }
        let didStart = await Task.detached { Self.waitForSignal(started) }.value
        XCTAssertTrue(didStart)
        request.cancel()
        resume.signal()
        await request.value
        XCTAssertFalse(permission.isRequesting)
        XCTAssertFalse(permission.isAllowed)
        state.isAllowed = true
        await permission.refresh()
        XCTAssertTrue(permission.isAllowed)
    }

    func testRepeatedPermissionActionsProduceOnlyOneRequest() async {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var requests = 0
        let permission = DictationScreenPermissionController(check: {
            started.signal()
            _ = resume.wait(timeout: .now() + 2)
            return false
        }, request: {
            requests += 1
            return true
        })
        let first = Task { await permission.requestIfNeeded { true } }
        let didStart = await Task.detached { Self.waitForSignal(started) }.value
        XCTAssertTrue(didStart)
        await permission.requestIfNeeded { true }
        resume.signal()
        await first.value
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
    }

    func testSearchFindsOCRInExperimentalSettings() {
        let result = SettingsSearchIndex.results(for: "OCR", availability: self.searchAvailability(privateAIAvailable: true)).first
        XCTAssertEqual(result?.target, .dictationScreenContext)
        XCTAssertEqual(result?.section, .experimental)
    }

    func testPublicBuildSearchOmitsFluidIntelligenceContext() {
        let availability = self.searchAvailability(privateAIAvailable: false)
        for query in ["OCR", "screen words", "Fluid Intelligence"] {
            XCTAssertFalse(SettingsSearchIndex.results(for: query, availability: availability).contains { $0.target == .dictationScreenContext })
        }
        XCTAssertTrue(availability.includes(.experimental))
    }

    private func attributeError(_ error: AXError) -> AnyObject {
        var error = error
        guard let value = AXValueCreate(.axError, &error) else { preconditionFailure("Cannot create a synthetic AX error") }
        return value
    }

    private func accessibilityAttributes(role: String) -> [AnyObject] {
        [role as NSString, "" as NSString, "Public label" as NSString, NSNull(), NSNull(), NSNull(), NSNull(), [] as NSArray, NSNull()]
    }

    private func assertDecodedNodeSuppressesOCR(_ item: DictationContextReader.ElementText?) async {
        let fixture = ContextAccessibilityFixture()
        let lines = await DictationContextReader.recognizeWindowIfSafe(
            pid: 999_999, window: fixture.window, wordCount: 0,
            hasCompletePrivacyMetadata: item?.hasCompletePrivacyMetadata == true
        ) { _, _ in
            XCTFail("Incomplete per-attribute AX privacy evidence must not invoke OCR")
            return ["Protected screenshot"]
        }
        XCTAssertEqual(lines, [])
    }

    private func searchAvailability(privateAIAvailable: Bool) -> SettingsSearchAvailability {
        .init(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: true,
            savesAudioWithTranscriptionHistory: true,
            overlayAtBottom: false,
            dictationScreenContextAvailable: privateAIAvailable
        )
    }

    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }

    private func target(pid: pid_t = 1, window: AXUIElement? = nil, element: AXUIElement? = nil) -> TypingService.RecordingTargetContext {
        .init(id: UUID(), pid: pid, bundleIdentifier: "test.context", window: window, element: element)
    }

    private func windowInfo(id: CGWindowID, pid: pid_t = 101, frame: CGRect, layer: Int = 0) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: frame.dictionaryRepresentation,
        ]
    }

    private func delayedRead() -> Task<DictationTypingContext?, Never> {
        Task {
            try? await Task.sleep(for: .seconds(10))
            return .init(textBeforeCursor: "late result", screenText: nil)
        }
    }

    private func request(bundleID: String = "test.context", isEnabled: Bool) -> DictationContextReader.Request {
        .init(
            pid: 999_999,
            bundleID: bundleID,
            window: nil,
            element: nil,
            textBeforeCursor: "Known cursor text",
            isEnabled: isEnabled
        )
    }
}

private final nonisolated class ScreenPermissionCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false

    var isAllowed: Bool {
        get { self.lock.withLock { self.allowed } }
        set { self.lock.withLock { self.allowed = newValue } }
    }
}

/// Synthetic Accessibility handles only. No element belongs to a running process.
private nonisolated struct ContextAccessibilityFixture: @unchecked Sendable {
    let window = AXUIElementCreateApplication(999_991)
    let field = AXUIElementCreateApplication(999_992)
    let sibling = AXUIElementCreateApplication(999_993)

    var request: DictationContextReader.Request {
        .init(pid: 999_999, bundleID: "test.ordinary-editor", window: self.window,
              element: self.field, textBeforeCursor: "Public cursor", isEnabled: true)
    }
}

/// Deliberately ignores Task cancellation, as a suspended OS operation may do.
private actor SuspendedContextRead {
    private var didStart = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<DictationTypingContext?, Never>?

    func read() async -> DictationTypingContext? {
        self.didStart = true
        self.startedWaiter?.resume()
        self.startedWaiter = nil
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { self.startedWaiter = $0 }
    }

    func finish(_ value: DictationTypingContext?) {
        self.continuation?.resume(returning: value)
        self.continuation = nil
    }
}

private actor ContextRetirementState {
    private var didStart = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var hasFinished = false

    func started() {
        self.didStart = true
        self.startedWaiter?.resume()
        self.startedWaiter = nil
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { self.startedWaiter = $0 }
    }

    func finished() { self.hasFinished = true }
}
