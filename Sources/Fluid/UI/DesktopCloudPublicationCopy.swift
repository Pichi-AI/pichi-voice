import Foundation

/// Complete typed presentation mapping. N3 owns the corresponding String Catalog entries.
nonisolated enum DesktopCloudPublicationCopy {
    static func availability(_ snapshot: PichiCloudPublicationSnapshot, accountState: AccountSessionState,
                             language: PichiInterfaceLanguage = PichiLocalization.language,
                             bundle: Bundle = .main) -> String {
        if accountState == .reauthenticationRequired {
            return PichiLocalization.text("cloud.pause.authenticationRequired", language: language, bundle: bundle,
                                          defaultValue: "Sign in again to resume cloud uploads")
        }
        if !snapshot.cloudSyncEnabled, snapshot.availability == .ready || snapshot.availability == .paused {
            return PichiLocalization.text("cloud.state.off", language: language, bundle: bundle,
                                          defaultValue: "Cloud sync is off")
        }
        return self.availabilityLabel(snapshot.availability, language: language, bundle: bundle)
    }
    static func availabilityLabel(_ value: PichiCloudPublicationAvailability,
                                  language: PichiInterfaceLanguage = PichiLocalization.language,
                                  bundle: Bundle = .main) -> String {
        switch value {
        case .unconfigured: PichiLocalization.text("cloud.availability.unconfigured", language: language, bundle: bundle, defaultValue: "Cloud sync is not configured")
        case .signedOut: PichiLocalization.text("cloud.availability.signedOut", language: language, bundle: bundle, defaultValue: "Sign in to use cloud sync")
        case .profileUnavailable: PichiLocalization.text("cloud.availability.profileUnavailable", language: language, bundle: bundle, defaultValue: "Cloud data is temporarily hidden")
        case .ready: PichiLocalization.text("cloud.availability.ready", language: language, bundle: bundle,
                                            defaultValue: "Cloud sync is ready.")
        case .pausing: PichiLocalization.text("cloud.availability.pausing", language: language, bundle: bundle, defaultValue: "Stopping cloud sync")
        case .paused: PichiLocalization.text("cloud.availability.paused", language: language, bundle: bundle, defaultValue: "Cloud uploads paused")
        case .transportUnavailable: PichiLocalization.text("cloud.availability.transportUnavailable", language: language, bundle: bundle, defaultValue: "Cloud connection unavailable")
        case .storageUnavailable: PichiLocalization.text("cloud.availability.storageUnavailable", language: language, bundle: bundle, defaultValue: "Cloud storage unavailable. Transfers are paused.")
        case .protectedDataUnavailable: PichiLocalization.text("cloud.availability.protectedDataUnavailable", language: language, bundle: bundle, defaultValue: "Unlock this device to resume protected delivery.")
        }
    }
    static func pause(_ value: PichiPublicationPauseReason) -> String {
        switch value {
        case .userRequested: PichiLocalization.text("cloud.pause.userRequested", defaultValue: "Cloud uploads paused")
        case .profileTransition: PichiLocalization.text("cloud.pause.profileTransition", defaultValue: "Uploads paused after an account change")
        case .uncertainDelivery: PichiLocalization.text("cloud.pause.uncertainDelivery", defaultValue: "Upload confirmation needed")
        case .authenticationRequired: PichiLocalization.text("cloud.pause.authenticationRequired", defaultValue: "Sign in again to resume cloud uploads")
        case .accountReview: PichiLocalization.text("cloud.pause.accountReview", defaultValue: "Review account balance")
        case .permissionReview: PichiLocalization.text("cloud.pause.permissionReview", defaultValue: "Review workspace access")
        case .receiptReview: PichiLocalization.text("cloud.pause.receiptReview", defaultValue: "Review cloud upload status")
        case .validationRejected: PichiLocalization.text("cloud.pause.validationRejected", defaultValue: "Cloud upload needs validation review")
        case .sourceConflict: PichiLocalization.text("cloud.pause.sourceConflict", defaultValue: "Cloud source conflict")
        case .retryBudgetExhausted: PichiLocalization.text("cloud.pause.retryBudgetExhausted", defaultValue: "Automatic retries paused")
        case .retryAfterBeyondBudget: PichiLocalization.text("cloud.pause.retryAfterBeyondBudget", defaultValue: "Server requested a longer retry delay")
        case .transportUnavailable: PichiLocalization.text("cloud.pause.transportUnavailable", defaultValue: "Cloud connection unavailable")
        case .storageUnavailable: PichiLocalization.text("cloud.pause.storageUnavailable", defaultValue: "Cloud storage unavailable. Transfers are paused.")
        }
    }
    static func withheld(_ value: PichiPublicationWithholdingReason) -> String {
        switch value {
        case .notCompleted: PichiLocalization.text("cloud.withheld.notCompleted", defaultValue: "Recording is not completed. Kept on this device.")
        case .redactionNotEnabled: PichiLocalization.text("cloud.withheld.redactionNotEnabled", defaultValue: "This recording was captured without text redaction")
        case .originalTextRetained: PichiLocalization.text("cloud.withheld.originalTextRetained", defaultValue: "Original text is still stored")
        case .completenessUnknown: PichiLocalization.text("cloud.withheld.completenessUnknown", defaultValue: "Recognition completeness is unknown")
        case .incompleteTranscript: PichiLocalization.text("cloud.withheld.incompleteTranscript", defaultValue: "Recognition is incomplete. Kept on this device.")
        case .emptyTranscript: PichiLocalization.text("cloud.withheld.emptyTranscript", defaultValue: "No transcript text to upload")
        case .excludedIntervals: PichiLocalization.text("cloud.withheld.excludedIntervals", defaultValue: "Some audio intervals have no transcript")
        case .invalidTranscript: PichiLocalization.text("cloud.withheld.invalidTranscript", defaultValue: "This protected source needs review")
        case .exportLimitExceeded: PichiLocalization.text("cloud.withheld.exportLimitExceeded", defaultValue: "This source exceeds cloud upload limits")
        }
    }
    static func analysis(_ value: PichiPublicationAnalysisState) -> String {
        switch value {
        case .queued: PichiLocalization.text("cloud.analysis.queued", defaultValue: "Analysis queued")
        case .running: PichiLocalization.text("cloud.analysis.running", defaultValue: "Analysis running")
        case .succeeded: PichiLocalization.text("cloud.analysis.succeeded", defaultValue: "Analysis completed")
        case .failed: PichiLocalization.text("cloud.analysis.failed", defaultValue: "Analysis failed. Upload retained.")
        case .needsParticipant: PichiLocalization.text("cloud.analysis.needsParticipant", defaultValue: "Choose the represented participant")
        case .needsCriteria: PichiLocalization.text("cloud.analysis.needsCriteria", defaultValue: "Choose assessment criteria")
        }
    }
    static func action(_ value: DesktopCloudPublicationPolicy.RecordingAction) -> String {
        switch value {
        case .send: PichiLocalization.text("cloud.action.send", defaultValue: "Send protected transcript")
        case .retry: PichiLocalization.text("cloud.action.retry", defaultValue: "Retry upload")
        case .reconcile: PichiLocalization.text("cloud.action.reconcile", defaultValue: "Refresh cloud status")
        }
    }
    static func failure(_ value: DesktopCloudPublicationPresentation.Failure) -> String {
        switch value {
        case .busy: PichiLocalization.text("cloud.error.busy", defaultValue: "A cloud operation is still finishing. Try again shortly.")
        case .operation: PichiLocalization.text("cloud.error.operation", defaultValue: "Cloud sync could not finish. Review its status and try again.")
        }
    }
    static func receipt(_ status: PichiCloudPublicationStatus) -> PichiPublicationReceipt? {
        switch status {
        case let .accepted(receipt), let .acceptedNeedsReview(receipt, _): receipt
        default: nil
        }
    }
    static func retryScheduled(_ date: Date, language: PichiInterfaceLanguage = PichiLocalization.language,
                               bundle: Bundle = .main, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)
        style.timeZone = timeZone
        return PichiLocalization.format("cloud.status.retryScheduled", language: language, bundle: bundle,
                                       arguments: [date.formatted(style)], defaultValue: "Retry at %@")
    }
    static func status(_ status: PichiCloudPublicationStatus) -> String {
        switch status {
        case .localOnly: PichiLocalization.text("cloud.status.localOnly", defaultValue: "Saved on this device")
        case .waitingForSource: PichiLocalization.text("cloud.status.waitingForSource", defaultValue: "Waiting for protected transcript")
        case .queued: PichiLocalization.text("cloud.status.queued", defaultValue: "Queued for cloud upload")
        case .sending: PichiLocalization.text("cloud.status.sending", defaultValue: "Uploading protected transcript")
        case let .retryScheduled(date): self.retryScheduled(date)
        case .accepted, .acceptedNeedsReview: PichiLocalization.text("cloud.status.accepted", defaultValue: "Cloud upload accepted")
        case .conflict: PichiLocalization.text("cloud.status.conflict", defaultValue: "Cloud source conflict")
        case let .withheld(reason): self.withheld(reason)
        case let .paused(reason): self.pause(reason)
        }
    }
}
