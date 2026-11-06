import Foundation

/// Versioned, data-only observations. Modules never receive PCM, credentials or editable page text.
public enum CommunicationCallState: String, Codable, Sendable { case indeterminate, prejoin, ringing, inCall, onHold, ended }
public enum CommunicationMicrophoneState: String, Codable, Sendable { case indeterminate, muted, unmuted }
/// Evidence provenance, not an entitlement or a security trust level.
public enum CommunicationModuleValidation: String, Codable, Sendable { case nativeValidated, contractTested, researchOnly }
public struct CommunicationPushToTalkChord: Codable, Equatable, Sendable {
    public enum Modifier: String, Codable, Sendable { case shift, control, option, command, function }
    public let keyCode: UInt16
    public let modifiers: [Modifier]
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 49,
                  modifiers: try c.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? [])
    }
    public init(keyCode: UInt16 = 49, modifiers: [Modifier] = []) { self.keyCode = keyCode; self.modifiers = modifiers }
}
public struct CommunicationControlSnapshot: Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let labels: [String]
    public let value: String?
    public let ancestorIdentifiers: [String]
    public init(role: String, identifier: String? = nil, labels: [String] = [], value: String? = nil, ancestorIdentifiers: [String] = []) {
        self.role = role; self.identifier = identifier; self.labels = labels; self.value = value; self.ancestorIdentifiers = ancestorIdentifiers
    }
}
public struct CommunicationObservationSnapshot: Sendable {
    public let bundleIdentifier: String
    public let processID: Int32
    public let windowID: UInt32
    public let documentURL: String?
    public let windowIdentifier: String?
    public let windowTitle: String?
    public let controls: [CommunicationControlSnapshot]
    public let audioInputActive: Bool?
    public let audioOutputActive: Bool?
    public init(bundleIdentifier: String, processID: Int32, windowID: UInt32, documentURL: String? = nil,
                windowIdentifier: String? = nil, windowTitle: String? = nil, controls: [CommunicationControlSnapshot] = [],
                audioInputActive: Bool? = nil, audioOutputActive: Bool? = nil) {
        self.bundleIdentifier = bundleIdentifier; self.processID = processID; self.windowID = windowID
        self.documentURL = documentURL; self.windowIdentifier = windowIdentifier; self.windowTitle = windowTitle
        self.controls = controls; self.audioInputActive = audioInputActive; self.audioOutputActive = audioOutputActive
    }
}
public struct CommunicationModuleEvidence: Sendable, Equatable {
    public let moduleID: String
    public let callState: CommunicationCallState
    public let microphoneState: CommunicationMicrophoneState
    public init(moduleID: String, callState: CommunicationCallState = .indeterminate,
                microphoneState: CommunicationMicrophoneState = .indeterminate) {
        self.moduleID = moduleID; self.callState = callState; self.microphoneState = microphoneState
    }
}
public struct CommunicationControlSelector: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    public let labels: [String]
    public let ancestorIdentifier: String?
    public let expectedValue: String?
    public let allowsShortcutSuffix: Bool
    private enum CodingKeys: String, CodingKey { case role, identifier, labels, ancestorIdentifier, expectedValue, allowsShortcutSuffix }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(role: try c.decodeIfPresent(String.self, forKey: .role) ?? "AXButton",
                  identifier: try c.decodeIfPresent(String.self, forKey: .identifier),
                  labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [],
                  ancestorIdentifier: try c.decodeIfPresent(String.self, forKey: .ancestorIdentifier),
                  expectedValue: try c.decodeIfPresent(String.self, forKey: .expectedValue),
                  allowsShortcutSuffix: try c.decodeIfPresent(Bool.self, forKey: .allowsShortcutSuffix) ?? false)
    }
    public init(role: String = "AXButton", identifier: String? = nil, labels: [String] = [],
                ancestorIdentifier: String? = nil, expectedValue: String? = nil, allowsShortcutSuffix: Bool = false) {
        self.role = role; self.identifier = identifier; self.labels = labels; self.ancestorIdentifier = ancestorIdentifier
        self.expectedValue = expectedValue; self.allowsShortcutSuffix = allowsShortcutSuffix
    }
    public func matches(_ control: CommunicationControlSnapshot) -> Bool {
        guard control.role == self.role,
              self.identifier.map({ $0 == control.identifier }) ?? true,
              self.ancestorIdentifier.map({ control.ancestorIdentifiers.contains($0) }) ?? true,
              self.expectedValue.map({ $0 == control.value }) ?? true else { return false }
        if self.labels.isEmpty { return self.identifier != nil }
        return control.labels.contains { label in self.labels.contains { expected in
            let actual = Self.normalized(label), target = Self.normalized(expected)
            if actual == target { return true }
            guard self.allowsShortcutSuffix, actual.hasPrefix(target + " ("), actual.hasSuffix(")") else { return false }
            let suffix = actual.dropFirst(target.count)
            return suffix.count <= 64 && Self.isShortcutSuffix(String(suffix))
        } }
    }
    private static func isShortcutSuffix(_ suffix: String) -> Bool {
        let raw = suffix.trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("("), raw.hasSuffix(")") else { return false }
        let body = String(raw.dropFirst().dropLast())
        let separators = CharacterSet(charactersIn: " +-,⌘⌥⇧⌃⎋↵←→↑↓␣")
        let names: Set<String> = ["space", "spacebar", "alt", "option", "command", "cmd", "ctrl", "control", "shift", "fn", "enter", "return", "tab", "esc", "escape"]
        let tokens = body.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            if names.contains(token) { return true }
            if token.count == 1, let c = token.first, c.isASCII, c.isLetter || c.isNumber { return true }
            if token.hasPrefix("f"), let number = Int(token.dropFirst()), (1...24).contains(number) { return true }
            return false
        }
    }
    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
public struct CommunicationCallRules: Codable, Sendable, Equatable {
    public let connected: [CommunicationControlSelector]
    public let ended: [CommunicationControlSelector]
    public let ringing: [CommunicationControlSelector]
    public let held: [CommunicationControlSelector]
    public let prejoin: [CommunicationControlSelector]
    private enum CodingKeys: String, CodingKey { case connected, ended, ringing, held, prejoin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(connected: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .connected) ?? [],
                  ended: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .ended) ?? [],
                  ringing: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .ringing) ?? [],
                  held: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .held) ?? [],
                  prejoin: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .prejoin) ?? [])
    }
    public init(connected: [CommunicationControlSelector] = [], ended: [CommunicationControlSelector] = [],
                ringing: [CommunicationControlSelector] = [], held: [CommunicationControlSelector] = [],
                prejoin: [CommunicationControlSelector] = []) {
        self.connected = connected; self.ended = ended; self.ringing = ringing; self.held = held; self.prejoin = prejoin
    }
}
public struct CommunicationMicrophoneRules: Codable, Sendable, Equatable {
    public let muted: [CommunicationControlSelector]
    public let unmuted: [CommunicationControlSelector]
    private enum CodingKeys: String, CodingKey { case muted, unmuted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(muted: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .muted) ?? [],
                  unmuted: try c.decodeIfPresent([CommunicationControlSelector].self, forKey: .unmuted) ?? [])
    }
    public init(muted: [CommunicationControlSelector] = [], unmuted: [CommunicationControlSelector] = []) {
        self.muted = muted; self.unmuted = unmuted
    }
}
public struct CommunicationURLRule: Codable, Sendable, Equatable {
    public let host: String
    public let allowsSubdomains: Bool
    public let pathPrefixes: [String]
    public let excludedPathPrefixes: [String]
    public let requiresHTTPS: Bool
    private enum CodingKeys: String, CodingKey { case host, allowsSubdomains, pathPrefixes, excludedPathPrefixes, requiresHTTPS }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try c.decode(String.self, forKey: .host),
                  allowsSubdomains: try c.decodeIfPresent(Bool.self, forKey: .allowsSubdomains) ?? false,
                  pathPrefixes: try c.decodeIfPresent([String].self, forKey: .pathPrefixes) ?? [],
                  excludedPathPrefixes: try c.decodeIfPresent([String].self, forKey: .excludedPathPrefixes) ?? [],
                  requiresHTTPS: try c.decodeIfPresent(Bool.self, forKey: .requiresHTTPS) ?? true)
    }
    public init(host: String, allowsSubdomains: Bool = false, pathPrefixes: [String] = [],
                excludedPathPrefixes: [String] = [], requiresHTTPS: Bool = true) {
        self.host = host.lowercased(); self.allowsSubdomains = allowsSubdomains; self.pathPrefixes = pathPrefixes
        self.excludedPathPrefixes = excludedPathPrefixes; self.requiresHTTPS = requiresHTTPS
    }
    public func matches(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= 4096, let url = URLComponents(string: value),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              self.requiresHTTPS ? url.scheme?.lowercased() == "https" : ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              host == self.host || (self.allowsSubdomains && host.hasSuffix("." + self.host)) else { return false }
        let path = url.path
        func starts(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") }
        guard !self.excludedPathPrefixes.contains(where: starts) else { return false }
        return self.pathPrefixes.isEmpty || self.pathPrefixes.contains(where: starts)
    }
}
public struct CommunicationModuleDescriptor: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let version: String
    public let nativeBundleIdentifiers: [String]
    public let browserBundleIdentifiers: [String]
    public let urlRules: [CommunicationURLRule]
    public let validation: CommunicationModuleValidation
    public let callRules: CommunicationCallRules
    public let microphoneRules: CommunicationMicrophoneRules
    public let pushToTalkChords: [CommunicationPushToTalkChord]
    public let nativeWindowIdentifiers: [String]
    public let nativeWindowTitles: [String]
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, version, nativeBundleIdentifiers, browserBundleIdentifiers, urlRules
        case validation, callRules, microphoneRules, pushToTalkChords, nativeWindowIdentifiers, nativeWindowTitles
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            id: try c.decode(String.self, forKey: .id), displayName: try c.decode(String.self, forKey: .displayName),
            version: try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0",
            nativeBundleIdentifiers: try c.decodeIfPresent([String].self, forKey: .nativeBundleIdentifiers) ?? [],
            browserBundleIdentifiers: try c.decodeIfPresent([String].self, forKey: .browserBundleIdentifiers) ?? [],
            urlRules: try c.decodeIfPresent([CommunicationURLRule].self, forKey: .urlRules) ?? [],
            validation: try c.decodeIfPresent(CommunicationModuleValidation.self, forKey: .validation) ?? .contractTested,
            callRules: try c.decodeIfPresent(CommunicationCallRules.self, forKey: .callRules) ?? .init(),
            microphoneRules: try c.decodeIfPresent(CommunicationMicrophoneRules.self, forKey: .microphoneRules) ?? .init(),
            pushToTalkChords: try c.decodeIfPresent([CommunicationPushToTalkChord].self, forKey: .pushToTalkChords) ?? [],
            nativeWindowIdentifiers: try c.decodeIfPresent([String].self, forKey: .nativeWindowIdentifiers) ?? [],
            nativeWindowTitles: try c.decodeIfPresent([String].self, forKey: .nativeWindowTitles) ?? [])
    }
    public init(schemaVersion: Int = 1, id: String, displayName: String, version: String = "1.0.0",
                nativeBundleIdentifiers: [String] = [], browserBundleIdentifiers: [String] = [], urlRules: [CommunicationURLRule] = [],
                validation: CommunicationModuleValidation = .contractTested, callRules: CommunicationCallRules = .init(),
                microphoneRules: CommunicationMicrophoneRules = .init(), pushToTalkChords: [CommunicationPushToTalkChord] = [],
                nativeWindowIdentifiers: [String] = [], nativeWindowTitles: [String] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.displayName = displayName; self.version = version
        self.nativeBundleIdentifiers = nativeBundleIdentifiers; self.browserBundleIdentifiers = browserBundleIdentifiers
        self.urlRules = urlRules; self.validation = validation; self.callRules = callRules; self.microphoneRules = microphoneRules
        self.pushToTalkChords = pushToTalkChords; self.nativeWindowIdentifiers = nativeWindowIdentifiers; self.nativeWindowTitles = nativeWindowTitles
    }
    public func matchesBrowserBundleIdentifier(_ bundle: String) -> Bool {
        self.browserBundleIdentifiers.contains { registered in
            bundle == registered || bundle.hasPrefix(registered + ".app.")
        }
    }
    public var selectors: [CommunicationControlSelector] {
        self.callRules.connected + self.callRules.ended + self.callRules.ringing + self.callRules.held + self.callRules.prejoin + self.microphoneRules.muted + self.microphoneRules.unmuted
    }
    public func validate() throws {
        func valid(_ value: String, maximum: Int = 512) -> Bool { !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains(where: { $0.value < 32 }) }
        guard self.schemaVersion == 1, valid(self.id, maximum: 96), self.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
              valid(self.displayName, maximum: 128), valid(self.version, maximum: 32),
              self.validation == .researchOnly || !self.nativeBundleIdentifiers.isEmpty || (!self.browserBundleIdentifiers.isEmpty && !self.urlRules.isEmpty),
              self.nativeBundleIdentifiers.count <= 16, self.browserBundleIdentifiers.count <= 16,
              self.nativeBundleIdentifiers.allSatisfy({ valid($0, maximum: 256) }), self.browserBundleIdentifiers.allSatisfy({ valid($0, maximum: 256) }),
              self.urlRules.count <= 32, self.selectors.count <= 64, self.pushToTalkChords.count <= 8,
              self.nativeWindowIdentifiers.count <= 16, self.nativeWindowTitles.count <= 16,
              self.pushToTalkChords.allSatisfy({ $0.keyCode <= 127 && $0.modifiers.count <= 5 && Set($0.modifiers).count == $0.modifiers.count }) else { throw CommunicationModuleError.invalidDescriptor }
        for rule in self.urlRules {
            guard valid(rule.host, maximum: 253), rule.host.contains("."), rule.host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                  rule.pathPrefixes.count <= 32, rule.excludedPathPrefixes.count <= 32,
                  (rule.pathPrefixes + rule.excludedPathPrefixes).allSatisfy({ $0.hasPrefix("/") && valid($0) }) else { throw CommunicationModuleError.invalidDescriptor }
        }
        for selector in self.selectors {
            guard ["AXButton", "AXCheckBox", "AXToggleButton", "AXMenuButton", "AXPopUpButton"].contains(selector.role),
                  selector.identifier != nil || !selector.labels.isEmpty, selector.labels.count <= 16,
                  selector.labels.allSatisfy({ valid($0) }), selector.identifier.map({ valid($0) }) ?? true,
                  selector.ancestorIdentifier.map({ valid($0) }) ?? true, selector.expectedValue.map({ valid($0) }) ?? true else { throw CommunicationModuleError.invalidDescriptor }
        }
        guard (self.nativeWindowIdentifiers + self.nativeWindowTitles).allSatisfy({ valid($0) }) else { throw CommunicationModuleError.invalidDescriptor }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw CommunicationModuleError.invalidDescriptor }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result
    }
}
public enum CommunicationModuleError: Error, Equatable { case invalidDescriptor, duplicateIdentifier, capacityExceeded }
public protocol CommunicationObservationModule: Sendable {
    var descriptor: CommunicationModuleDescriptor { get }
    func matches(bundleIdentifier: String, documentURL: String?) -> Bool
    func evaluate(_ snapshot: CommunicationObservationSnapshot) -> CommunicationModuleEvidence
}
public struct SemanticCommunicationModule: CommunicationObservationModule {
    public let descriptor: CommunicationModuleDescriptor
    public init(descriptor: CommunicationModuleDescriptor) throws { try descriptor.validate(); self.descriptor = descriptor }
    public func matches(bundleIdentifier: String, documentURL: String?) -> Bool {
        self.descriptor.nativeBundleIdentifiers.contains(bundleIdentifier)
            || (self.descriptor.matchesBrowserBundleIdentifier(bundleIdentifier) && self.descriptor.urlRules.contains { $0.matches(documentURL) })
    }
    public func evaluate(_ snapshot: CommunicationObservationSnapshot) -> CommunicationModuleEvidence {
        let empty = CommunicationModuleEvidence(moduleID: self.descriptor.id)
        guard snapshot.processID > 0, snapshot.windowID > 0, snapshot.bundleIdentifier.utf8.count <= 256,
              snapshot.documentURL.map({ $0.utf8.count <= 4096 }) ?? true, snapshot.windowIdentifier.map({ $0.utf8.count <= 512 }) ?? true,
              snapshot.windowTitle.map({ $0.utf8.count <= 1024 }) ?? true, snapshot.controls.count <= 512,
              snapshot.controls.allSatisfy({ $0.labels.count <= 8 && $0.labels.allSatisfy({ $0.utf8.count <= 1024 }) && $0.ancestorIdentifiers.count <= 32 && $0.ancestorIdentifiers.allSatisfy({ $0.utf8.count <= 512 }) && ($0.identifier.map({ $0.utf8.count <= 512 }) ?? true) && ($0.value.map({ $0.utf8.count <= 1024 }) ?? true) }),
              self.matches(bundleIdentifier: snapshot.bundleIdentifier, documentURL: snapshot.documentURL) else { return empty }
        if self.descriptor.nativeBundleIdentifiers.contains(snapshot.bundleIdentifier) {
            guard self.descriptor.nativeWindowIdentifiers.isEmpty || self.descriptor.nativeWindowIdentifiers.contains(snapshot.windowIdentifier ?? ""),
                  self.descriptor.nativeWindowTitles.isEmpty || self.descriptor.nativeWindowTitles.contains(snapshot.windowTitle ?? "") else { return empty }
        }
        func sees(_ rules: [CommunicationControlSelector]) -> Bool { rules.contains { rule in snapshot.controls.contains(where: rule.matches) } }
        let connected = sees(self.descriptor.callRules.connected), ended = sees(self.descriptor.callRules.ended)
        let ringing = sees(self.descriptor.callRules.ringing), held = sees(self.descriptor.callRules.held)
        let prejoin = sees(self.descriptor.callRules.prejoin)
        let call: CommunicationCallState
        if prejoin { call = connected || ended || ringing || held ? .indeterminate : .prejoin }
        else if ended { call = connected || ringing || held ? .indeterminate : .ended }
        else if ringing { call = held ? .indeterminate : .ringing }
        else if held { call = .onHold }
        else { call = connected ? .inCall : .indeterminate }
        let muted = sees(self.descriptor.microphoneRules.muted), unmuted = sees(self.descriptor.microphoneRules.unmuted)
        let microphone: CommunicationMicrophoneState = call == .inCall && muted != unmuted ? (muted ? .muted : .unmuted) : .indeterminate
        return CommunicationModuleEvidence(moduleID: self.descriptor.id, callState: call, microphoneState: microphone)
    }
}
public struct CommunicationModuleRegistry: Sendable {
    public private(set) var modules: [any CommunicationObservationModule] = []
    public init() {}
    public init(modules: [any CommunicationObservationModule]) throws { for module in modules { try self.register(module) } }
    public mutating func register(_ module: any CommunicationObservationModule) throws {
        try module.descriptor.validate()
        guard self.modules.count < 128 else { throw CommunicationModuleError.capacityExceeded }
        guard !self.modules.contains(where: { $0.descriptor.id == module.descriptor.id }) else { throw CommunicationModuleError.duplicateIdentifier }
        self.modules.append(module)
    }
    public func candidates(bundleIdentifier: String, includeResearchOnly: Bool = false) -> [any CommunicationObservationModule] {
        self.modules.filter { module in
            (includeResearchOnly || module.descriptor.validation != .researchOnly)
                && (module.descriptor.nativeBundleIdentifiers.contains(bundleIdentifier) || module.descriptor.matchesBrowserBundleIdentifier(bundleIdentifier))
        }
    }
    public func resolve(snapshot: CommunicationObservationSnapshot) -> CommunicationModuleEvidence? {
        let matches = self.candidates(bundleIdentifier: snapshot.bundleIdentifier).filter { $0.matches(bundleIdentifier: snapshot.bundleIdentifier, documentURL: snapshot.documentURL) }
        guard matches.count == 1, let module = matches.first else { return nil }
        return module.evaluate(snapshot)
    }
}
