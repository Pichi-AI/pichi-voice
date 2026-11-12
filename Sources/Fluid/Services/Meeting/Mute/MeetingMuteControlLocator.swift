#if os(macOS)
import ApplicationServices
import Foundation

/// Finds a control, never its mute state. Only the captured icon is a classifier input.
/// Call on one utility queue: AX calls have a short timeout and the entire search has a budget.
final nonisolated class MeetingMuteControlLocator {
    enum Platform: String, Sendable {
        case zoom
        case googleMeet

        var bundleIdentifier: String {
            switch self {
            case .zoom: return "us.zoom.xos"
            case .googleMeet: return "com.google.Chrome"
            }
        }
    }

    struct WindowDescriptor: Equatable, Sendable {
        let windowID: UInt32
        let processID: Int32
        let bundleIdentifier: String
        let frame: CGRect
        /// Transient identity evidence for overlapping windows, never persisted or logged.
        let title: String?

        init(windowID: UInt32, processID: Int32, bundleIdentifier: String, frame: CGRect, title: String? = nil) {
            self.windowID = windowID
            self.processID = processID
            self.bundleIdentifier = bundleIdentifier
            self.frame = frame
            self.title = title
        }
    }

    struct LocatedControl: Sendable {
        let windowID: UInt32
        let processID: Int32
        let windowFrame: CGRect
        let buttonFrame: CGRect
        let iconFrame: CGRect
        let iconCropInWindow: CGRect
        let geometryRevision: UInt64
        let cacheHit: Bool
        /// Compared in memory to pin this attempt to one Meet document; never logged.
        let documentURL: String?
        let semanticState: MeetingMuteSemanticState
    }

    private struct Cache {
        let platform: Platform
        let descriptor: WindowDescriptor
        let window: AXUIElement
        let path: [AXUIElement]
        let callControlPath: [AXUIElement]?
        let webArea: AXUIElement?
        let webAreaURL: String?
        let inventory: Set<UInt32>
        var button: AXUIElement { self.path[self.path.count - 1] }
    }

    private struct Geometry: Equatable {
        let windowID: UInt32
        let processID: Int32
        let window: CGRect
        let button: CGRect
        let icon: CGRect
    }

    private enum ReadFailure: Error { case budget, transport, ambiguous }

    struct Reader {
        static let timeout: Float = 0.025
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(160))
        var attributesRemaining = 1200
        var nodesRemaining = 480

        mutating func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            guard self.attributesRemaining > 0, ContinuousClock.now < self.deadline else { throw ReadFailure.budget }
            self.attributesRemaining -= 1
            _ = AXUIElementSetMessagingTimeout(element, Self.timeout)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if status == .cannotComplete { throw ReadFailure.transport }
            return status == .success ? value : nil
        }

        mutating func string(_ element: AXUIElement, _ attribute: String) throws -> String? {
            guard let value = try self.value(element, attribute) else { return nil }
            if let string = value as? String { return string }
            return (value as? URL)?.absoluteString
        }

        mutating func elements(_ element: AXUIElement, _ attribute: String = kAXChildrenAttribute as String) throws -> [AXUIElement] {
            guard let value = try self.value(element, attribute) else { return [] }
            guard let children = value as? [AXUIElement], children.count <= 64 else { throw ReadFailure.budget }
            return children
        }

        mutating func frame(_ element: AXUIElement) throws -> CGRect? {
            guard let position = try self.value(element, kAXPositionAttribute as String),
                  let size = try self.value(element, kAXSizeAttribute as String),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            let frame = CGRect(origin: point, size: dimensions)
            return MeetingMuteControlLocator.valid(frame) ? frame : nil
        }

        mutating func validate(_ path: [AXUIElement]) throws -> Bool {
            guard (2...32).contains(path.count) else { return false }
            for index in 0..<(path.count - 1) {
                guard try self.elements(path[index]).contains(where: { CFEqual($0, path[index + 1]) }) else { return false }
            }
            return true
        }

        mutating func visit() throws {
            guard self.nodesRemaining > 0, ContinuousClock.now < self.deadline else { throw ReadFailure.budget }
            self.nodesRemaining -= 1
        }
    }

    private var cache: Cache?
    private var geometry: Geometry?
    private var revision: UInt64 = 0
    private var nextDiscoveryAllowed: ContinuousClock.Instant?
    private var retryInventory: Set<UInt32>?

    /// Invalidating also changes the revision so a pending crop cannot survive rebinding.
    func invalidate() {
        self.cache = nil
        self.geometry = nil
        self.nextDiscoveryAllowed = nil
        self.retryInventory = nil
        self.revision &+= 1
    }

    /// Used only for a configured PTT chord. Never reads focused text or key contents.
    func ownsFocusedWindow(processID: Int32) -> Bool {
        guard let cache = self.cache, cache.descriptor.processID == processID else { return false }
        do {
            var reader = Reader()
            let app = AXUIElementCreateApplication(processID)
            guard let value = try reader.value(app, kAXFocusedWindowAttribute as String),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            return CFEqual(value, cache.window)
        } catch { return false }
    }

    /// Returns nil for missing permission, stale/detached controls, ambiguous calls or any exhausted
    /// AX budget. Never returns the previous rectangle after a failed read.
    func resolve(platform: Platform, windows: [WindowDescriptor]) -> LocatedControl? {
        guard AXIsProcessTrusted() else { self.invalidate(); return nil }
        let eligible = windows.filter {
            $0.bundleIdentifier == platform.bundleIdentifier && $0.processID > 0 && Self.valid($0.frame)
        }
        guard !eligible.isEmpty, eligible.count <= 64 else { self.invalidate(); return nil }
        let inventory = Set(eligible.map(\.windowID))
        if self.cache == nil, self.retryInventory == inventory,
           let next = self.nextDiscoveryAllowed, ContinuousClock.now < next { return nil }
        do {
            var reader = Reader()
            if let cache = self.cache, cache.platform == platform, cache.inventory == inventory,
               let current = eligible.only(where: { $0.windowID == cache.descriptor.windowID && $0.processID == cache.descriptor.processID }),
               let result = try self.resolve(cache, descriptor: current, reader: &reader, hit: true) {
                return result
            }
            self.invalidate()
            // Failed cached reads do not reuse their partially consumed budget for a second full
            // search. The next call may rediscover; the current capture must remain unknown.
            if reader.attributesRemaining != 1200 { return nil }
            let found = try self.discover(platform: platform, windows: eligible, inventory: inventory, reader: &reader)
            guard found.count == 1, let cache = found.first else { self.scheduleRetry(inventory); return nil }
            self.cache = cache
            guard let result = try self.resolve(cache, descriptor: cache.descriptor, reader: &reader, hit: false) else {
                self.invalidate(); return nil
            }
            return result
        } catch {
            self.invalidate()
            self.scheduleRetry(inventory)
            return nil
        }
    }

    private func scheduleRetry(_ inventory: Set<UInt32>) {
        self.retryInventory = inventory
        self.nextDiscoveryAllowed = ContinuousClock.now.advanced(by: .seconds(1))
    }

    private func resolve(_ cache: Cache, descriptor: WindowDescriptor, reader: inout Reader, hit: Bool) throws -> LocatedControl? {
        guard try reader.validate(cache.path),
              let windowFrame = try reader.frame(cache.window), Self.sameWindow(windowFrame, descriptor.frame),
              (try reader.value(cache.window, kAXMinimizedAttribute as String) as? Bool) != true,
              let buttonFrame = try reader.frame(cache.button),
              Self.contains(windowFrame, buttonFrame) else { return nil }
        if let area = cache.webArea {
            guard let expected = cache.webAreaURL,
                  try reader.string(area, "AXURL").flatMap(Self.meetDocumentIdentity) == expected,
                  Self.isMeetCallURL(expected),
                  let callPath = cache.callControlPath, try reader.validate(callPath),
                  let leaveFrame = try reader.frame(callPath[callPath.count - 1]),
                  Self.contains(windowFrame, leaveFrame) else { return nil }
        }
        var disclosure: CGRect?
        if cache.platform == .zoom {
            // The Zoom Audio control can contain its separate arrow menu. Crop only the icon
            // portion of that control; do not include the adjacent menu as a false candidate.
            for child in try reader.elements(cache.button) {
                let role = try reader.string(child, kAXRoleAttribute as String)
                if role == "AXMenuButton" || role == "AXPopUpButton" {
                    disclosure = try reader.frame(child)
                }
            }
        }
        guard let icon = Self.iconRect(platform: cache.platform, button: buttonFrame, window: windowFrame, disclosure: disclosure) else { return nil }
        let current = Geometry(windowID: descriptor.windowID, processID: descriptor.processID, window: windowFrame, button: buttonFrame, icon: icon)
        if current != self.geometry { self.revision &+= 1; self.geometry = current }
        return LocatedControl(windowID: descriptor.windowID, processID: descriptor.processID,
            windowFrame: windowFrame, buttonFrame: buttonFrame, iconFrame: icon,
            iconCropInWindow: icon.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY),
            geometryRevision: self.revision, cacheHit: hit, documentURL: cache.webAreaURL,
            semanticState: try self.semanticState(cache, reader: &reader))
    }

    private func semanticState(_ cache: Cache, reader: inout Reader) throws -> MeetingMuteSemanticState {
        let title = try reader.string(cache.button, kAXTitleAttribute as String)
        let description = try reader.string(cache.button, kAXDescriptionAttribute as String)
        switch cache.platform {
        case .zoom:
            return MeetingMuteUISemantics.zoom(title: title, description: description,
                help: try reader.string(cache.button, kAXHelpAttribute as String))
        case .googleMeet:
            return MeetingMuteUISemantics.meet(title: title, description: description)
        }
    }

    private func discover(platform: Platform, windows: [WindowDescriptor], inventory: Set<UInt32>, reader: inout Reader) throws -> [Cache] {
        var found: [Cache] = []
        for processID in Set(windows.map(\.processID)).sorted() {
            let application = AXUIElementCreateApplication(processID)
            // Chromium lazily exposes native accessibility after its application role is read.
            // Descendant role reads then activate only the web-content bridge needed here.
            // Use the existing bounded reader rather than enabling global screen-reader mode.
            if platform == .googleMeet { _ = try reader.value(application, kAXRoleAttribute as String) }
            let appWindows = try reader.elements(application, kAXWindowsAttribute as String)
            guard appWindows.count <= 16 else { throw ReadFailure.budget }
            for window in appWindows {
                if platform == .zoom,
                   try reader.string(window, kAXIdentifierAttribute as String) != "zm.meeting.window.main" { continue }
                guard let frame = try reader.frame(window),
                      let descriptor = Self.matchingWindow(processID: processID, frame: frame,
                        title: try reader.string(window, kAXTitleAttribute as String), windows: windows) else { continue }
                if platform == .zoom {
                    let buttons = try self.paths(root: window, find: { element, role, reader in
                        guard role == "AXButton" else { return false }
                        return try reader.string(element, kAXIdentifierAttribute as String) == "audio"
                    }, reader: &reader)
                    for path in buttons {
                        found.append(Cache(platform: platform, descriptor: descriptor, window: window, path: path,
                            callControlPath: nil, webArea: nil, webAreaURL: nil, inventory: inventory))
                    }
                } else {
                    let areas = try self.paths(root: window, stopAtWebAreas: true, find: { element, role, reader in
                        guard role == "AXWebArea", let url = try reader.string(element, "AXURL") else { return false }
                        return Self.isMeetCallURL(url)
                    }, reader: &reader)
                    for areaPath in areas {
                        guard let area = areaPath.last,
                              let rawURL = try reader.string(area, "AXURL"),
                              let url = Self.meetDocumentIdentity(rawURL) else { continue }
                        var leavePaths: [[AXUIElement]] = []
                        var buttons: [[AXUIElement]] = []
                        _ = try self.paths(root: area, find: { _, _, _ in false }, observe: { path, role, reader in
                            guard role == "AXButton", let element = path.last else { return }
                            let names = try [reader.string(element, kAXTitleAttribute as String), reader.string(element, kAXDescriptionAttribute as String)].compactMap { $0 }
                            // External application's tested English control selectors. They locate
                            // a button only and never determine the recording or mute state.
                            if names.contains(where: Self.isMeetMicrophoneControlLabel) { buttons.append(path) }
                            if names.contains("Leave call") { leavePaths.append(path) }
                        }, reader: &reader)
                        guard leavePaths.count == 1 else { continue }
                        for path in buttons {
                            found.append(Cache(platform: platform, descriptor: descriptor, window: window,
                                path: areaPath + path.dropFirst(), callControlPath: areaPath + leavePaths[0].dropFirst(),
                                webArea: area, webAreaURL: url, inventory: inventory))
                        }
                    }
                }
                if found.count > 1 { throw ReadFailure.ambiguous }
            }
        }
        return found
    }

    private func paths(root: AXUIElement, stopAtWebAreas: Bool = false,
        find: (AXUIElement, String, inout Reader) throws -> Bool,
        observe: (([AXUIElement], String, inout Reader) throws -> Void)? = nil,
        reader: inout Reader) throws -> [[AXUIElement]] {
        let leaves: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXImage", "AXLink", "AXHeading", "AXMenuBar", "AXMenu", "AXTabGroup", "AXToolbar"]
        var pending: [[AXUIElement]] = [[root]]
        var index = 0
        var result: [[AXUIElement]] = []
        while index < pending.count {
            try reader.visit()
            let path = pending[index]
            index += 1
            guard path.count <= 30 else { throw ReadFailure.budget }
            guard let element = path.last,
                  let role = try reader.string(element, kAXRoleAttribute as String) else { throw ReadFailure.transport }
            if try find(element, role, &reader) { result.append(path) }
            try observe?(path, role, &reader)
            if leaves.contains(role) || role == "AXButton" || (stopAtWebAreas && role == "AXWebArea") { continue }
            let children = try reader.elements(element)
            guard pending.count + children.count <= 480 else { throw ReadFailure.budget }
            pending.append(contentsOf: children.map { path + [$0] })
        }
        return result
    }

    static func isMeetMicrophoneControlLabel(_ value: String) -> Bool {
        MeetingMuteUISemantics.isMeetMicrophoneLabel(value)
    }

    /// Geometry is sufficient when unique. Home and call windows can have identical maximized
    /// bounds, so only an exact, unique title match may disambiguate that collision.
    static func matchingWindow(processID: Int32, frame: CGRect, title: String?, windows: [WindowDescriptor]) -> WindowDescriptor? {
        let candidates = windows.filter { $0.processID == processID && Self.sameWindow(frame, $0.frame) }
        if candidates.count == 1 { return candidates[0] }
        guard let title, !title.isEmpty else { return nil }
        return candidates.only { $0.title == title }
    }

    static func isMeetCallURL(_ value: String) -> Bool {
        self.meetDocumentIdentity(value) != nil
    }

    /// Query/fragment changes during join do not silently turn the same call into a new source.
    /// The normalized identity remains in memory only, never in diagnostics or persisted state.
    static func meetDocumentIdentity(_ value: String) -> String? {
        guard let url = URLComponents(string: value), url.scheme == "https", url.host?.lowercased() == "meet.google.com" else { return nil }
        var path = url.path.split(separator: "/")
        if path.first == "meet" { path.removeFirst() }
        guard path.count == 1 else { return nil }
        let groups = path[0].split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [3, 4, 3],
              groups.allSatisfy({ $0.utf8.allSatisfy { (97...122).contains($0) } }) else { return nil }
        return "https://meet.google.com/" + String(path[0])
    }

    /// Geometry follows the actual control, not a screen corner, window size or stored rectangle.
    /// Zoom's label and arrow are outside the icon; Meet's microphone button is icon-only.
    static func iconRect(platform: Platform, button: CGRect, window: CGRect, disclosure: CGRect? = nil) -> CGRect? {
        guard Self.valid(button), Self.valid(window), Self.contains(window, button),
              button.width >= 12, button.height >= 12, button.width <= 300, button.height <= 200 else { return nil }
        var iconArea = button
        if platform == .zoom {
            if let disclosure, Self.valid(disclosure), Self.contains(button, disclosure), disclosure.midX > button.midX {
                iconArea.size.width = disclosure.minX - button.minX
            }
            iconArea.size.height *= 0.68
        }
        let side = min(96, min(iconArea.width, iconArea.height) * (platform == .googleMeet ? 2 / 3 : 1))
        guard side >= 12 else { return nil }
        let crop = CGRect(x: iconArea.midX - side / 2, y: iconArea.midY - side / 2, width: side, height: side)
        return Self.contains(button, crop) ? crop : nil
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -0.5, dy: -0.5).contains(inner)
    }

    private static func sameWindow(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
        abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }
}

private extension Array {
    nonisolated func only(where predicate: (Element) -> Bool) -> Element? {
        var result: Element?
        for value in self where predicate(value) {
            guard result == nil else { return nil }
            result = value
        }
        return result
    }
}

#endif
