import AppKit
import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

@MainActor
final class ParakeetCompactModelDemoTests: XCTestCase {
    func testOptInNativeOnboardingAndSettingsReview() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_DEMO"] == "1",
              let audioPath = ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_AUDIO"]
        else { throw XCTSkip("Explicitly enable the native model review with an English test WAV") }
        let settings = SettingsStore.shared
        settings.onboardingSelectedLanguageID = "en"
        let finished = expectation(description: "Native review closed")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Mini and Pico — Model Review"
        let viewModel = VoiceEngineSettingsViewModel(settings: settings, appServices: .shared)
        viewModel.providerFilter = .nvidia
        viewModel.englishOnlyFilter = true
        let view = CompactModelReviewView(viewModel: viewModel, audioPath: audioPath) {
            window.orderOut(nil)
            finished.fulfill()
        }
        window.contentView = NSHostingView(rootView: view.appTheme(.dark))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("COMPACT_MODEL_DEMO_READY window=\(window.windowNumber)")
        await fulfillment(of: [finished], timeout: 600)
        window.contentView = nil
        window.close()
        await AppServices.shared.asr.finishAudioRouteRecoveryTest()
    }
}

@MainActor
private struct CompactModelReviewView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    let audioPath: String
    let onClose: () -> Void
    @State private var page = 0
    @State private var onboardingStep = 2
    @State private var shortcutTarget: ShortcutRecordingTarget?
    @State private var shortcutMessage: String?
    @State private var transcript = "Choose a downloaded model to transcribe the test recording."
    @State private var isTranscribing = false
    private let menuBarManager = MenuBarManager()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Review", selection: self.$page) {
                    Text("Voice Engine").tag(0)
                    Text("Onboarding").tag(1)
                    Text("Test transcription").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 450)
                Spacer()
                Button("Close review", action: self.onClose)
                    .disabled(self.isTranscribing || self.viewModel.areSpeechModelActionsBlocked)
            }
            .padding(16)
            Divider()
            switch self.page {
            case 1:
                OnboardingFlowView(
                    currentStep: self.$onboardingStep,
                    accessibilityEnabled: true,
                    accessibilitySetupInProgress: false,
                    markAISkipped: {},
                    finishOnboarding: {},
                    finishOnboardingAtGettingStarted: {},
                    openAccessibilitySettings: {},
                    restartApp: {},
                    menuBarManager: self.menuBarManager,
                    activeShortcutRecordingTarget: self.$shortcutTarget,
                    shortcutRecordingMessage: self.$shortcutMessage,
                    theme: .dark
                )
                .environmentObject(AppServices.shared)
            case 2:
                VStack(alignment: .leading, spacing: 20) {
                    Text("English test recording · Microphone stays off")
                    HStack {
                        Button("Test Mini") { self.transcribe(.fluidParakeetMini) }
                        Button("Test Pico") { self.transcribe(.fluidParakeetPico) }
                    }
                    .disabled(self.isTranscribing)
                    if self.isTranscribing { ProgressView("Loading and transcribing…") }
                    Text(self.transcript).textSelection(.enabled)
                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            default:
                ScrollView {
                    VoiceEngineSettingsView(viewModel: self.viewModel, settings: .shared, theme: .dark)
                        .padding(20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func transcribe(_ model: SettingsStore.SpeechModel) {
        self.isTranscribing = true
        self.transcript = ""
        Task { @MainActor in
            defer { self.isTranscribing = false }
            do {
                let samples = try await Self.readAudio(self.audioPath)
                let provider = FluidAudioProvider(
                    modelOverride: model,
                    configureWordBoosting: false,
                    enhancementOptions: .init(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: false, customDictionaryEntries: [])
                )
                try await provider.prepare()
                let result = try await provider.transcribe(samples)
                self.transcript = "\(model.humanReadableName): \(result.text)"
            } catch {
                self.transcript = error.localizedDescription
            }
        }
    }

    @concurrent private static func readAudio(_ path: String) async throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

@MainActor
final class WindowSizingRegressionTests: XCTestCase {
    func testLongLibraryDoesNotBecomeTheHostingMinimumHeight() async {
        let state = LibraryLayoutSelection()
        state.showsLibrary = true
        let host = NSHostingController(rootView: LibraryLayoutFixture(selection: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1000, height: 560))
        await self.settleHosting(host.view)
        XCTAssertLessThanOrEqual(host.view.fittingSize.height, 560,
                                 "A scrollable document must not become the main window's minimum height")
    }

    func testSwitchingToLongLibraryPreservesSmallWindowAndScrollViewport() async {
        let state = LibraryLayoutSelection()
        let host = NSHostingController(rootView: LibraryLayoutFixture(selection: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1000, height: 560))
        await self.settleHosting(host.view)
        let initialFrame = window.frame
        state.showsLibrary = true
        await self.settleHosting(host.view)
        XCTAssertEqual(window.frame.height, initialFrame.height, accuracy: 1,
                       "Opening the library must preserve the user's window height")
        self.assertSidebarFooterVisible(state)
        let library = self.scrollViews(in: host.view).first { ($0.documentView?.bounds.height ?? 0) > 900 }
        XCTAssertNotNil(library, "The actual hosted library must retain a native scroll viewport")
        guard let library, let document = library.documentView else { return }
        XCTAssertLessThanOrEqual(library.contentSize.height, 560)
        XCTAssertGreaterThan(document.bounds.height, library.contentSize.height + 500)
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY - library.contentSize.height))
        XCTAssertEqual(library.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 2,
                       "The last model must be reachable in a small window")
    }

    func testLibraryViewportFollowsRepeatedSmallAndLargeResizes() async {
        let state = LibraryLayoutSelection()
        state.showsLibrary = true
        let host = NSHostingController(rootView: LibraryLayoutFixture(selection: state))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        for size in [NSSize(width: 1000, height: 560), NSSize(width: 1600, height: 1000),
                     NSSize(width: 850, height: 520), NSSize(width: 1500, height: 900)] {
            window.setContentSize(size)
            await self.settleHosting(host.view)
            XCTAssertEqual(host.view.bounds.height, size.height, accuracy: 1)
            self.assertSidebarFooterVisible(state)
            let library = self.scrollViews(in: host.view).first { ($0.documentView?.bounds.height ?? 0) > 900 }
            XCTAssertNotNil(library)
            if let library { XCTAssertLessThanOrEqual(library.contentSize.height, size.height) }
        }
    }

    private func settleHosting(_ view: NSView) async {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func assertSidebarFooterVisible(_ state: LibraryLayoutSelection,
                                            file: StaticString = #filePath, line: UInt = #line) {
        guard let viewport = state.sidebarViewport, let footer = state.footerFrame else {
            XCTFail("The hosted sidebar must report its viewport and pinned footer", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(footer.minY, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(footer.maxY, viewport.height + 1, file: file, line: line)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { self.scrollViews(in: $0) }
    }

    func testRepeatedLayoutAndResizeEventsDoNotRewriteStableBounds() async {
        let window = SizingRecordingWindow()
        let view = FluidWindowSizingNSView(sizing: .minimum(width: 800, height: 500))
        window.contentView = view
        await self.drainSizing()
        window.resetWrites()
        for _ in 0..<100 {
            view.sizing = .minimum(width: 800, height: 500)
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        }
        XCTAssertEqual(window.boundsWrites, 0, "A SwiftUI update must not synchronously invalidate window constraints")
        await self.drainSizing()
        XCTAssertEqual(window.boundsWrites, 0, "Stable bounds must stay untouched after the coalesced update")
        XCTAssertEqual(window.frameWrites, 0)
        window.contentView = nil
    }

    func testRapidSizingChangesApplyOnlyTheLatestBoundsAfterLayout() async {
        let window = SizingRecordingWindow()
        let view = FluidWindowSizingNSView(sizing: .minimum(width: 800, height: 500))
        window.contentView = view
        await self.drainSizing()
        window.resetWrites()
        view.sizing = .minimum(width: 900, height: 550)
        view.sizing = .minimum(width: 940, height: 700)
        XCTAssertEqual(window.boundsWrites, 0)
        await self.drainSizing()
        XCTAssertEqual(window.minSize, NSSize(width: 940, height: 700))
        XCTAssertEqual(window.minimumWrites, 1)
        window.contentView = nil
    }

    func testFullScreenLayoutDoesNotChangeAnyWindowBoundsOrFrame() async {
        let window = SizingRecordingWindow()
        let view = FluidWindowSizingNSView(sizing: .minimum(width: 800, height: 500))
        window.contentView = view
        await self.drainSizing()
        window.isFullScreenForTest = true
        window.resetWrites()
        view.sizing = .minimum(width: 940, height: 700)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        await self.drainSizing()
        XCTAssertEqual(window.boundsWrites, 0, "Full-screen sizing belongs entirely to macOS")
        XCTAssertEqual(window.frameWrites, 0)
        window.isFullScreenForTest = false
        // Exit must restore the pending bounds even without a final resize event.
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await self.drainSizing()
        XCTAssertEqual(window.minSize, NSSize(width: 940, height: 700))
        window.contentView = nil
    }

    func testQueuedSizingDoesNotWriteToThePreviousWindow() async {
        let oldWindow = SizingRecordingWindow()
        let newWindow = SizingRecordingWindow()
        let view = FluidWindowSizingNSView(sizing: .minimum(width: 800, height: 500))
        oldWindow.contentView = view
        await self.drainSizing()
        oldWindow.resetWrites()
        view.sizing = .minimum(width: 940, height: 700)
        oldWindow.contentView = nil
        newWindow.contentView = view
        await self.drainSizing()
        XCTAssertEqual(oldWindow.boundsWrites, 0)
        XCTAssertEqual(oldWindow.frameWrites, 0)
        XCTAssertEqual(newWindow.minSize, NSSize(width: 940, height: 700))
        newWindow.contentView = nil
    }

    private func drainSizing() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class LibraryLayoutSelection: ObservableObject {
    @Published var showsLibrary = false
    var sidebarViewport: CGSize?
    var footerFrame: CGRect?
}

@MainActor
private struct LibraryLayoutFixture: View {
    @ObservedObject var selection: LibraryLayoutSelection

    var body: some View {
        NavigationSplitView {
            ZStack {
                VStack(spacing: 0) {
                    Text("Search")
                    List(0..<20, id: \.self) { index in Text("Sidebar \(index)") }
                    Text("Settings")
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .named("library-layout-sidebar"))
                        } action: { self.selection.footerFrame = $0 }
                }
                // The production sidebar keeps the settings navigation mounted too.
                VStack {
                    Text("Settings Search")
                    List(0..<30, id: \.self) { index in Text("Setting \(index)") }
                    Text("Back")
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .fluidViewport()
            .coordinateSpace(name: "library-layout-sidebar")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { self.selection.sidebarViewport = $0 }
            .navigationSplitViewColumnWidth(min: 264, ideal: 300, max: 360)
        } detail: {
            ZStack {
                Color.clear
                if self.selection.showsLibrary {
                    VoiceEngineSettingsScreen(appServices: .shared, theme: .dark)
                } else {
                    Text("Overview").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fluidViewport()
        }
        .navigationSplitViewStyle(.balanced)
        .fluidWindowSizing(.minimum(width: 800, height: 500))
    }
}

@MainActor
private final class SizingRecordingWindow: NSWindow {
    var minimumWrites = 0
    var maximumWrites = 0
    var frameWrites = 0
    var isFullScreenForTest = false
    var boundsWrites: Int { self.minimumWrites + self.maximumWrites }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.isReleasedWhenClosed = false
    }

    override var minSize: NSSize {
        get { super.minSize }
        set { self.minimumWrites += 1; super.minSize = newValue }
    }

    override var maxSize: NSSize {
        get { super.maxSize }
        set { self.maximumWrites += 1; super.maxSize = newValue }
    }

    override var styleMask: NSWindow.StyleMask {
        get { self.isFullScreenForTest ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        self.frameWrites += 1
        super.setFrame(frameRect, display: flag, animate: animateFlag)
    }

    func resetWrites() {
        self.minimumWrites = 0
        self.maximumWrites = 0
        self.frameWrites = 0
    }
}
