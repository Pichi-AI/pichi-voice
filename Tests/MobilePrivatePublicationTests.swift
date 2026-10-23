import Foundation
import PDFKit

// In-memory scope metadata only. No real profile is selected or configured.
@MainActor private final class SyntheticPublicationScope {
    var visible = true
    var context = MobilePrivatePublicationContext(profile: PrivateProfileSnapshot(id: "synthetic-a", context: nil,
        generation: UUID(), rootDirectory: URL(fileURLWithPath: "/synthetic-unused"),
        legacyRootDirectory: URL(fileURLWithPath: "/synthetic-unused"), isReadable: true), projectionRevision: UUID())
    func current(_ token: MobilePrivatePublicationContext) -> Bool { visible && token == context }
    func conceal() {
        visible = false
        context = .init(profile: context.profile, projectionRevision: UUID())
    }
}

nonisolated private final class SyntheticPDFParseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredValue = false
    private var releaseValue = 0
    let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return enteredValue }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return releaseValue }
    func recordRelease() { lock.lock(); releaseValue += 1; lock.unlock() }
    func parse(_ url: URL) throws -> MobilePresentationDocument {
        try MobilePresentationDocument(url: url, startAccess: { _ in true }, stopAccess: { _ in self.recordRelease() },
            isReadablePDF: { _ in true }, loadPDF: { _ in
                self.lock.lock(); self.enteredValue = true; self.lock.unlock()
                self.semaphore.wait() // The native parser intentionally ignores cancellation.
                let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0); return pdf
            })
    }
}

extension MobileAccountInteractionTests {
    @MainActor static func privatePublicationTests() async throws {
        let scope = SyntheticPublicationScope()
        let owner = MobilePrivatePublicationTasks(capture: { scope.visible ? scope.context : nil }, validate: { scope.current($0) })
        let original = owner.admit()!
        expect(owner.canPublish(original), "Current immutable profile/revision can publish")
        var gate: CheckedContinuation<Void, Never>?
        var started = false, didPublish = false, reports = 0
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pichi-synthetic-publication-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("synthetic.txt")
        let pending = owner.start(report: { _ in reports += 1 }) { admission in
            started = true
            await withCheckedContinuation { gate = $0 }
            // Simulate a non-cooperative exporter handing back its newly staged file.
            try Data("synthetic export".utf8).write(to: staged)
            guard owner.canPublish(admission) else { try FileManager.default.removeItem(at: staged); return }
            didPublish = true
        }
        await until { started }
        expect(owner.busyCount == 1, "Publication remains owned across suspended I/O")
        scope.conceal()
        var joined = false
        let join = Task { await owner.cancelAndJoin(); joined = true }
        await until { owner.admit() == nil }
        expect(owner.start(operation: { _ in preconditionFailure("Late work admitted during cleanup") }) == nil,
               "Joined cleanup closes local publication admission")
        expect(!joined && owner.busyCount == 1, "Cancellation joins the non-cooperative operation")
        gate!.resume(); await pending?.value; await join.value
        expect(joined && !didPublish && reports == 0, "Concealed completion cannot publish or report stale failure")
        expect(!FileManager.default.fileExists(atPath: staged.path), "Rejected staged payload is independently removed")
        expect(owner.busyCount == 0 && !owner.canPublish(original), "Joined work releases ownership and invalidates former tokens")
        owner.resume()
        expect(owner.admit() == nil, "Resuming the UI owner cannot bypass profile visibility")
        scope.visible = true
        expect(owner.admit() != nil && !owner.canPublish(original), "Same-profile return with a new revision cannot revive an old publication")

        var errorGate: CheckedContinuation<Void, Never>?
        var errorStarted = false
        owner.start(report: { _ in reports += 1 }) { _ in
            errorStarted = true; await withCheckedContinuation { errorGate = $0 }
            throw AccountError.networkUnavailable
        }
        await until { errorStarted }
        owner.cancel()
        let errorJoin = Task { await owner.cancelAndJoin() }
        errorGate!.resume(); await errorJoin.value
        expect(reports == 0, "Late private failure cannot populate the next profile's alert")
        owner.resume()
        let currentFailure = owner.start(report: { _ in reports += 1 }) { _ in throw AccountError.networkUnavailable }
        await currentFailure?.value
        expect(reports == 1, "A current-scope failure is still reported")

        var confirmation = false, delayedStarted = false
        var delayGate: CheckedContinuation<Void, Never>?
        owner.start(affectsBusy: false) { admission in
            delayedStarted = true; await withCheckedContinuation { delayGate = $0 }
            if owner.canPublish(admission) { confirmation = true }
        }
        await until { delayedStarted }
        expect(owner.busyCount == 0, "Retained confirmation work does not block recording controls")
        owner.cancel()
        let confirmationJoin = Task { await owner.cancelAndJoin() }
        delayGate!.resume(); await confirmationJoin.value
        expect(!confirmation, "A cancelled delayed confirmation cannot mutate a new presentation")

        let loader = MobilePresentationLoader(), parser = SyntheticPDFParseGate()
        var pdfPublications = 0
        let pdfContext = scope.context
        expect(loader.load(url: URL(fileURLWithPath: "/synthetic.pdf"), parse: { try parser.parse($0) },
            canPublish: { scope.current(pdfContext) }, completion: { _ in pdfPublications += 1 }), "Current PDF request is admitted")
        await until { parser.entered }
        scope.conceal()
        // Deliberately omit loader.cancel: the actual completion fence must reject it.
        parser.semaphore.signal(); await loader.waitUntilFinished()
        expect(pdfPublications == 0 && parser.releases == 1, "Changed profile/revision rejects parsed PDF and releases its security scope")
        expect(!loader.isLoading, "A rejected PDF still joins its native worker")
        expect(!loader.load(url: URL(fileURLWithPath: "/synthetic.pdf"), canPublish: { false }, completion: { _ in
            preconditionFailure("Concealed PDF request was published")
        }), "Concealed PDF admission never starts parsing")
        await owner.cancelAndJoin()
    }
}
