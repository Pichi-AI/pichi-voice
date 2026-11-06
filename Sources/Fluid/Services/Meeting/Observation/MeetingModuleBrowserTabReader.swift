#if os(macOS)
import Foundation
import PichiCallObservation

/// Uses the existing focused-document reader and the same module probe as microphone
/// admission. A new service's landing/pre-join page is never enough to confirm a call.
@MainActor
final class MeetingModuleBrowserTabReader: BrowserTabReading {
    private let legacy: any BrowserTabReading
    init(legacy: (any BrowserTabReading)? = nil) { self.legacy = legacy ?? AXBrowserTabReader() }
    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL? {
        guard var url = await self.legacy.frontmostTabURL(bundleIdentifier: bundleIdentifier, processID: processID) else { return nil }
        let modules = MeetingCommunicationModuleHost.snapshot
        let document = "https://" + url.host + url.path
        guard modules.registry.candidates(bundleIdentifier: bundleIdentifier).contains(where: { $0.matches(bundleIdentifier: bundleIdentifier, documentURL: document) }) else { return url }
        let application = MeetingApplicationIdentity(bundleIdentifier: bundleIdentifier, processID: processID, displayName: bundleIdentifier)
        let observations: [MeetingCommunicationObservation] = await withCheckedContinuation { continuation in
            MeetingCommunicationAXProbe.shared.request(application: application, boundDocument: document, modules: modules) {
                continuation.resume(returning: $0)
            }
        }
        guard !Task.isCancelled else { return nil }
        let matching = observations.filter { $0.snapshot.documentURL == document && $0.evidence.callState != .indeterminate }
        if matching.count == 1, let evidence = matching.first?.evidence {
            url.communicationCallState = evidence.callState; url.communicationModuleID = evidence.moduleID
            switch evidence.callState {
            case .inCall: url.callState = .inCall
            case .ended: url.callState = .ended
            case .ringing, .onHold, .indeterminate: url.callState = .unknown
            }
            return url
        }
        // Preserve the previously supported paths while new modules require explicit controls.
        if modules.registrations.contains(where: {
            $0.allowsLegacyURLDetection && $0.module.matches(bundleIdentifier: bundleIdentifier, documentURL: document)
        }) { return url }
        return nil
    }
}
#endif
