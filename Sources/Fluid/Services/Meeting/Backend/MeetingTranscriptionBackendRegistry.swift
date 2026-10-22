import Foundation

/// Registry of compiled backend factories — not a dynamic plugin system. Injectable so tests (and
/// later, development-only composite backends) can register their own without touching the default
/// production wiring.
///
/// Unknown or unregistered identifiers are rejected explicitly. Nothing ever silently substitutes
/// a different backend.
@MainActor
final class MeetingTranscriptionBackendRegistry {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    typealias Factory = @MainActor (MeetingBackendHostContext) -> any MeetingTranscriptionBackend

    private var factories: [MeetingBackendID: Factory] = [:]
    private var descriptors: [MeetingBackendID: MeetingBackendDescriptor] = [:]
    let defaultBackendID: MeetingBackendID

    init(defaultBackendID: MeetingBackendID = .productionDefault) {
        self.defaultBackendID = defaultBackendID
    }

    /// Production registry: the local Parakeet + Nemotron composite plus the explicit legacy
    /// rollback backend. Its default shares the same source of truth as persisted settings.
    static func makeDefault() -> MeetingTranscriptionBackendRegistry {
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(.legacyCompatibility, descriptor: MeetingLegacyCompatibilityBackend.descriptor) { context in
            MeetingLegacyCompatibilityBackend(legacyExecutor: context.legacyExecutor)
        }
        registry.register(.parakeetNemotron, descriptor: MeetingParakeetNemotronBackend.descriptor) { context in
            MeetingParakeetNemotronBackend(runtimeFactory: context.parakeetNemotronRuntimeFactory)
        }
        PichiMeetingProviderFactory.registerBackends(in: registry)
        return registry
    }

    /// Declared capabilities allow preflight without constructing a backend or model. Bare
    /// custom factories retain compatibility and are validated against their produced descriptor.
    func register(_ id: MeetingBackendID, descriptor: MeetingBackendDescriptor? = nil, factory: @escaping Factory) {
        self.factories[id] = factory
        self.descriptors[id] = descriptor
    }

    func descriptor(for id: MeetingBackendID) -> MeetingBackendDescriptor? { self.descriptors[id] }

    /// Unknown custom capabilities cannot justify rejecting a language before construction.
    var supportedLanguageCodes: Set<String>? {
        guard !self.factories.isEmpty, self.factories.keys.allSatisfy({ self.descriptors[$0] != nil }) else { return nil }
        return self.descriptors.values.reduce(into: Set<String>()) { $0.formUnion($1.supportedLanguageCodes) }
    }

    var registeredBackendIDs: Set<MeetingBackendID> {
        Set(self.factories.keys)
    }

    func contains(_ id: MeetingBackendID) -> Bool {
        self.factories[id] != nil
    }

    /// Throws `MeetingBackendError.unknownBackend` for an identifier that was never registered —
    /// including a default that a caller configured but did not register.
    ///
    /// The requested identifier is also bound to the produced descriptor's identifier: a factory
    /// registered under one key may not hand back a backend that calls itself something else. Every
    /// downstream check — evidence's `backendMismatch`, the descriptor's declared precisions and
    /// limits — is keyed off that identity, so a mismatch here would make selection unverifiable.
    func makeBackend(
        id: MeetingBackendID,
        context: MeetingBackendHostContext
    ) throws -> any MeetingTranscriptionBackend {
        guard let factory = self.factories[id] else {
            throw MeetingBackendError.unknownBackend(id)
        }
        let backend = factory(context)
        guard backend.descriptor.id == id else {
            throw MeetingBackendError.backendIdentityMismatch(
                requested: id,
                produced: backend.descriptor.id
            )
        }
        if let declared = self.descriptors[id], backend.descriptor != declared {
            throw MeetingBackendError.backendDescriptorMismatch(backend: id)
        }
        return backend
    }
}
