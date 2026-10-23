import Foundation
import Combine
import PDFKit
import SwiftUI
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// A publication attempt retains N2's immutable source and the concealment revision.
/// This is a view-work fence, never a selected profile or account manager.
struct MobilePrivatePublicationContext: Equatable {
    let profile: PrivateProfileSnapshot
    let projectionRevision: UUID
}

/// Owns only cancellable private presentation work. Capture/finalization stays with
/// the meeting coordinator and is never cancelled by this owner.
@MainActor
final class MobilePrivatePublicationTasks: ObservableObject {
    struct Admission {
        let context: MobilePrivatePublicationContext
        fileprivate let epoch: UUID
    }
    @Published private(set) var busyCount = 0
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var isClosing = false
    private var joinTask: Task<Void, Never>?
    private let capture: @MainActor () -> MobilePrivatePublicationContext?
    private let validate: @MainActor (MobilePrivatePublicationContext) -> Bool

    init(capture: @escaping @MainActor () -> MobilePrivatePublicationContext?,
         validate: @escaping @MainActor (MobilePrivatePublicationContext) -> Bool) {
        self.capture = capture; self.validate = validate
    }

    func admit() -> Admission? {
        guard !isClosing, let context = capture(), validate(context) else { return nil }
        return Admission(context: context, epoch: epoch)
    }

    func canPublish(_ admission: Admission) -> Bool {
        !Task.isCancelled && !isClosing && admission.epoch == epoch && validate(admission.context)
    }

    @discardableResult
    func start(affectsBusy: Bool = true,
               report: @escaping @MainActor (Error) -> Void = { _ in },
               operation: @escaping @MainActor (Admission) async throws -> Void) -> Task<Void, Never>? {
        guard let admission = admit() else { return nil }
        let id = UUID()
        if affectsBusy { busyCount += 1 }
        let task = Task { @MainActor in
            defer {
                self.jobs.removeValue(forKey: id)
                if affectsBusy { self.busyCount -= 1 }
            }
            do {
                guard self.canPublish(admission) else { return }
                try await operation(admission)
            } catch {
                guard self.canPublish(admission), !(error is CancellationError) else { return }
                report(error)
            }
        }
        jobs[id] = task
        return task
    }

    /// Immediate concealment invalidates publication before any asynchronous join.
    func cancel() {
        isClosing = true; epoch = UUID()
        for job in jobs.values { job.cancel() }
    }

    func cancelAndJoin() async {
        if let joinTask { await joinTask.value; return }
        cancel()
        let pending = Array(jobs.values)
        let task = Task { @MainActor in
            for pending in pending { await pending.value }
            self.joinTask = nil
        }
        joinTask = task
        await task.value
    }

    func resume() {
        guard jobs.isEmpty, joinTask == nil else { return }
        isClosing = false
    }
}

/// One transient, read-only document lease. PDFKit reads the original URL;
/// it is never copied into meeting storage, bookmarked, renamed or deleted.
// The parser exclusively owns PDFKit until its detached worker has completed.
// The joined result is then handed to the main-thread native viewer, with no
// concurrent PDFDocument access across that handoff.
nonisolated final class MobilePresentationDocument: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let pdf: PDFDocument
    private let releaseAccess: (() -> Void)?

    init(url: URL,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         isReadablePDF: (URL) throws -> Bool = { url in
             let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isReadableKey])
             return values.isRegularFile == true && values.isReadable == true
                 && values.contentType?.conforms(to: .pdf) == true
         },
         loadPDF: (URL) -> PDFDocument? = { PDFDocument(url: $0) }) throws {
        let scoped = startAccess(url)
        do {
            guard url.isFileURL, try isReadablePDF(url),
                  let pdf = loadPDF(url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.pdf = pdf
        } catch {
            if scoped { stopAccess(url) }
            throw error
        }
        self.url = url
        self.releaseAccess = scoped ? { stopAccess(url) } : nil
    }

    deinit { releaseAccess?() }
}

/// One owned parse at a time. Cancelling invalidates publication immediately,
/// but the operation keeps joining the non-cooperative native parser before
/// releasing its scope or admitting another document. UI cancellation never waits.
@MainActor
final class MobilePresentationLoader: ObservableObject {
    @Published private(set) var isLoading = false
    private var generation: UUID?
    private var worker: Task<MobilePresentationDocument, Error>?
    private var operation: Task<Void, Never>?

    @discardableResult
    func load(url: URL,
              parse: @escaping @Sendable (URL) throws -> MobilePresentationDocument = {
                  try MobilePresentationDocument(url: $0)
              },
              canPublish: @escaping @MainActor () -> Bool = { true },
              completion: @escaping @MainActor (Result<MobilePresentationDocument, Error>) -> Void) -> Bool {
        guard !isLoading, canPublish() else { return false }
        let id = UUID()
        generation = id
        isLoading = true
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let document = try parse(url)
            try Task.checkCancellation()
            return document
        }
        self.worker = worker
        // Retain the owner through the join even if its scene disappears. The
        // root cancels on navigation/disappearance, suppressing stale publication.
        operation = Task { [self] in
            let result = await worker.result
            self.worker = nil
            self.operation = nil
            self.isLoading = false
            guard self.generation == id, !Task.isCancelled, canPublish() else { return }
            self.generation = nil
            completion(result)
        }
        return true
    }

    func cancel() {
        generation = nil
        worker?.cancel()
        operation?.cancel()
    }

    func waitUntilFinished() async { await operation?.value }
}

#if os(iOS)
/// Multiple presentation windows share the process idle timer. Only the last
/// recording presentation restores its previous value; closing another window
/// cannot turn the timer back on underneath a recording presentation.
@MainActor
final class MobilePresentationAwakeRegistry {
    static let shared = MobilePresentationAwakeRegistry(
        getDisabled: { UIApplication.shared.isIdleTimerDisabled },
        setDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })

    private let getDisabled: () -> Bool
    private let setDisabled: (Bool) -> Void
    private var owners = Set<UUID>()
    private var previousValue: Bool?

    init(getDisabled: @escaping () -> Bool, setDisabled: @escaping (Bool) -> Void) {
        self.getDisabled = getDisabled
        self.setDisabled = setDisabled
    }

    func acquire() -> UUID {
        if owners.isEmpty {
            previousValue = getDisabled()
            setDisabled(true)
        }
        let token = UUID()
        owners.insert(token)
        return token
    }

    func release(_ token: UUID) {
        guard owners.remove(token) != nil, owners.isEmpty else { return }
        if let previousValue { setDisabled(previousValue) }
        previousValue = nil
    }
}

/// The native view owns the file and screen leases until dismantle, including
/// dismissal animation. Streaming view updates never reload the PDF document.
struct MobilePresentationPDFView: UIViewRepresentable {
    let document: MobilePresentationDocument
    let isRecording: Bool
    let isSceneActive: Bool

    @MainActor
    final class Coordinator: PrivateProfileTransitionParticipant {
        private(set) var document: MobilePresentationDocument?
        private let awake: MobilePresentationAwakeRegistry
        private var awakeToken: UUID?
        private weak var view: PDFView?
        private var visibilityObserver: AnyCancellable?

        init(document: MobilePresentationDocument, awake: MobilePresentationAwakeRegistry? = nil) {
            self.document = document
            self.awake = awake ?? .shared
            PrivateProfileService.shared.register(self)
            visibilityObserver = PrivateProfileService.shared.$isPrivateDataVisible.sink { [weak self] visible in
                if !visible { self?.conceal() }
            }
        }

        func attach(_ view: PDFView) {
            self.view = view
            if document == nil { view.document = nil }
        }

        private func conceal() { view?.document = nil; finish() }

        func prepareForPrivateProfileTransition() async throws { conceal() }

        func update(isRecording: Bool, isSceneActive: Bool = true) {
            let shouldStayAwake = isRecording && isSceneActive && document != nil
            if shouldStayAwake && awakeToken == nil { awakeToken = awake.acquire() }
            else if !shouldStayAwake, let token = awakeToken {
                awakeToken = nil
                awake.release(token)
            }
        }

        func finish() {
            update(isRecording: false)
            document = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = context.coordinator.document?.pdf
        context.coordinator.attach(view)
        context.coordinator.update(isRecording: isRecording, isSceneActive: isSceneActive)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.update(isRecording: isRecording, isSceneActive: isSceneActive)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        view.document = nil
        coordinator.finish()
    }
}
#endif
