#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PichiCallObservation

nonisolated struct MeetingCommunicationObservation: Sendable {
    let snapshot: CommunicationObservationSnapshot
    let evidence: CommunicationModuleEvidence
    let acquiredAtHostTime: UInt64
}

/// Shared, bounded native reader. Discovery scans once per second; active reads use only
/// validated cached call controls. Text inputs, chat text and participant names are not sampled.
final nonisolated class MeetingCommunicationAXProbe: @unchecked Sendable {
    static let shared = MeetingCommunicationAXProbe()
    typealias Completion = @Sendable ([MeetingCommunicationObservation]) -> Void
    private let queue = DispatchQueue(label: "meeting.communication.ax", qos: .utility)
    private let admissionLock = NSLock()
    private var admitted = 0
    private struct CachedControl { let path: [AXUIElement]; let ancestors: [String] }
    private struct CachedWindow {
        let window: AXUIElement
        let areaPath: [AXUIElement]?
        let document: String?
        let controls: [CachedControl]
    }
    private var cache: [String: CachedWindow] = [:]
    private var lastDiscovery: [String: Double] = [:]

    func request(application: MeetingApplicationIdentity, boundWindowID: UInt32? = nil,
                 boundDocument: String? = nil, modules: MeetingCommunicationModuleSnapshot,
                 completion: @escaping Completion) {
        let accepted = self.admissionLock.withLock { () -> Bool in
            guard self.admitted < 2 else { return false }
            self.admitted += 1; return true
        }
        guard accepted else { completion([]); return }
        self.queue.async {
            defer { self.admissionLock.withLock { self.admitted -= 1 } }
            completion(self.read(application: application, boundWindowID: boundWindowID,
                                 boundDocument: boundDocument, modules: modules))
        }
    }

    func invalidate() { self.queue.async { self.cache.removeAll(); self.lastDiscovery.removeAll() } }

    private func read(application: MeetingApplicationIdentity, boundWindowID: UInt32?, boundDocument: String?,
                      modules: MeetingCommunicationModuleSnapshot) -> [MeetingCommunicationObservation] {
        guard AXIsProcessTrusted(), let pid = application.processID,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == application.bundleIdentifier else { return [] }
        let candidates = modules.registry.candidates(bundleIdentifier: application.bundleIdentifier)
        guard !candidates.isEmpty else { return [] }
        let began = mach_absolute_time()
        let options: CGWindowListOption = boundWindowID == nil ? [.optionAll, .excludeDesktopElements] : .optionIncludingWindow
        guard let records = CGWindowListCopyWindowInfo(options, boundWindowID ?? kCGNullWindowID) as? [[String: Any]], records.count <= 4096 else { return [] }
        let descriptors = records.compactMap { row -> MeetingMuteControlLocator.WindowDescriptor? in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  boundWindowID == nil || boundWindowID == id,
                  let value = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: value as CFDictionary) else { return nil }
            return .init(windowID: id, processID: pid, bundleIdentifier: application.bundleIdentifier,
                         frame: frame, title: row[kCGWindowName as String] as? String)
        }
        guard !descriptors.isEmpty, descriptors.count <= 16 else { return [] }
        do {
            var reader = MeetingMuteControlLocator.Reader()
            let app = AXUIElementCreateApplication(pid)
            _ = try reader.value(app, kAXRoleAttribute as String)
            let windows = try reader.elements(app, kAXWindowsAttribute as String)
            guard windows.count <= 16 else { return [] }
            var results: [MeetingCommunicationObservation] = []
            for window in windows {
                guard let frame = try reader.frame(window),
                      let descriptor = MeetingMuteControlLocator.matchingWindow(processID: pid, frame: frame,
                        title: try reader.string(window, kAXTitleAttribute as String), windows: descriptors) else { continue }
                let key = "\(pid):\(descriptor.windowID)"
                let browser = candidates.contains { $0.descriptor.matchesBrowserBundleIdentifier(application.bundleIdentifier) }
                var cached = self.cache[key]
                if ProcessInfo.processInfo.systemUptime - (self.lastDiscovery[key] ?? -.infinity) >= 1 { cached = nil; self.cache[key] = nil }
                if let current = cached {
                    let controlsValid = try current.controls.allSatisfy { try reader.validate($0.path) }
                    let areaValid = try current.areaPath.map { try reader.validate($0) } ?? true
                    if !CFEqual(current.window, window) || !controlsValid || !areaValid { cached = nil; self.cache[key] = nil }
                }
                if cached == nil {
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - (self.lastDiscovery[key] ?? -.infinity) >= 1 else { continue }
                    if self.lastDiscovery.count >= 64, self.lastDiscovery[key] == nil, let oldest = self.lastDiscovery.min(by: { $0.value < $1.value })?.key { self.lastDiscovery[oldest] = nil; self.cache[oldest] = nil }
                    self.lastDiscovery[key] = now
                    var areaPath: [AXUIElement]?, document: String?
                    if browser {
                        let areas = try self.webAreas(root: window, bundle: application.bundleIdentifier, candidates: candidates, reader: &reader)
                        guard areas.count == 1, let area = areas.first else { continue }
                        areaPath = area.0; document = area.1
                    }
                    let root = areaPath?.last ?? window
                    let controls = try self.discoverControls(root: root, prefix: areaPath ?? [window], reader: &reader)
                    let selectors = candidates.flatMap { $0.descriptor.selectors }
                    let relevant = try controls.filter { item in
                        guard let element = item.path.last else { return false }
                        let value = try self.control(element, ancestors: item.ancestors, reader: &reader)
                        return selectors.contains { $0.matches(value) }
                    }
                    guard relevant.count <= 32 else { continue }
                    cached = CachedWindow(window: window, areaPath: areaPath, document: document, controls: relevant)
                    if self.cache.count >= 32, let oldest = self.cache.keys.first { self.cache[oldest] = nil; self.lastDiscovery[oldest] = nil }
                    if !relevant.isEmpty { self.cache[key] = cached }
                }
                guard let current = cached else { continue }
                let document = try current.areaPath?.last.flatMap { area in
                    try reader.string(area, "AXURL").flatMap(Self.documentIdentity)
                }
                guard document == current.document,
                      boundDocument == nil || boundDocument == document else { self.cache[key] = nil; continue }
                let controls = try current.controls.compactMap { item -> CommunicationControlSnapshot? in
                    guard let element = item.path.last else { return nil }
                    return try self.control(element, ancestors: item.ancestors, reader: &reader)
                }
                let snapshot = CommunicationObservationSnapshot(bundleIdentifier: application.bundleIdentifier, processID: pid,
                    windowID: descriptor.windowID, documentURL: document,
                    windowIdentifier: try reader.string(window, kAXIdentifierAttribute as String), windowTitle: descriptor.title, controls: controls)
                if let evidence = modules.registry.resolve(snapshot: snapshot) {
                    results.append(.init(snapshot: snapshot, evidence: evidence, acquiredAtHostTime: began))
                }
            }
            return results
        } catch { return [] }
    }

    private func control(_ element: AXUIElement, ancestors: [String], reader: inout MeetingMuteControlLocator.Reader) throws -> CommunicationControlSnapshot {
        let labels = try [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { try reader.string(element, $0 as String) }.filter { $0.utf8.count <= 1024 }
        return .init(role: try reader.string(element, kAXRoleAttribute as String) ?? "",
            identifier: try reader.string(element, kAXIdentifierAttribute as String), labels: labels,
            value: try reader.string(element, kAXValueAttribute as String), ancestorIdentifiers: ancestors)
    }

    private func discoverControls(root: AXUIElement, prefix: [AXUIElement], reader: inout MeetingMuteControlLocator.Reader) throws -> [CachedControl] {
        var pending: [([AXUIElement], [String], Int)] = [(prefix, [], 0)]
        var found: [CachedControl] = []
        while let (path, ancestors, depth) = pending.popLast(), let node = path.last {
            try reader.visit()
            let role = try reader.string(node, kAXRoleAttribute as String) ?? ""
            let identifier = try reader.string(node, kAXIdentifierAttribute as String)
            if ["AXButton", "AXCheckBox", "AXToggleButton", "AXMenuButton", "AXPopUpButton"].contains(role) {
                found.append(.init(path: path, ancestors: ancestors))
                guard found.count <= 128 else { return [] }
                continue
            }
            guard depth < 12, !["AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXMenu", "AXMenuBar", "AXTabGroup", "AXScrollArea", "AXList", "AXTable", "AXOutline"].contains(role) else { continue }
            let next = ancestors + (identifier.map { [$0] } ?? [])
            for child in try reader.elements(node).reversed() { pending.append((path + [child], next, depth + 1)) }
            guard pending.count <= 512 else { return [] }
        }
        return found
    }

    private func webAreas(root: AXUIElement, bundle: String, candidates: [any CommunicationObservationModule],
                          reader: inout MeetingMuteControlLocator.Reader) throws -> [([AXUIElement], String)] {
        var pending = [([root], 0)], found: [([AXUIElement], String)] = []
        while let (path, depth) = pending.popLast(), let node = path.last {
            try reader.visit()
            let role = try reader.string(node, kAXRoleAttribute as String) ?? ""
            if role == "AXWebArea" {
                if let url = try reader.string(node, "AXURL").flatMap(Self.documentIdentity),
                   candidates.contains(where: { $0.matches(bundleIdentifier: bundle, documentURL: url) }) { found.append((path, url)) }
                continue
            }
            guard depth < 8, !["AXToolbar", "AXTabGroup", "AXStaticText", "AXTextField", "AXTextArea", "AXButton", "AXImage", "AXMenu"].contains(role) else { continue }
            for child in try reader.elements(node).reversed() { pending.append((path + [child], depth + 1)) }
            guard pending.count <= 128 else { return [] }
        }
        return found
    }

    static func documentIdentity(_ value: String) -> String? {
        guard value.utf8.count <= 4096, var url = URLComponents(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        url.query = nil; url.fragment = nil; url.host = url.host?.lowercased()
        return url.string
    }

    static func ownsFocusedWindow(application: MeetingApplicationIdentity, windowID: UInt32) -> Bool {
        guard let pid = application.processID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        do {
            var reader = MeetingMuteControlLocator.Reader()
            let app = AXUIElementCreateApplication(pid)
            guard let value = try reader.value(app, kAXFocusedWindowAttribute as String),
                  CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let owned = self.shared.queue.sync(execute: { self.shared.cache["\(pid):\(windowID)"]?.window }) else { return false }
            return CFEqual(value, owned)
        } catch { return false }
    }
}
#endif
