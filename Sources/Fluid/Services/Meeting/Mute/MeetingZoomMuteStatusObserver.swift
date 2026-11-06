#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Zoom exposes the local tile's rendered computer-audio status even when its toolbar is hidden.
/// Its temporary-unmute HUD is another explicit rendered transition. Neither needs OCR or a
/// permanent screenshot of a toolbar. All labels stay in memory and are never logged.
final nonisolated class MeetingZoomMuteStatusObserver: MeetingRenderedAudioStatusObserving {
    typealias Snapshot = MeetingRenderedAudioStatusSnapshot

    private struct CachedTile {
        let processID: Int32
        let windowID: UInt32
        let path: [AXUIElement]
    }
    private var tile: CachedTile?
    private var callWindow: AXUIElement?
    private var callProcessID: Int32?

    func invalidate() { self.tile = nil; self.callWindow = nil; self.callProcessID = nil }

    func ownsFocusedWindow(processID: Int32) -> Bool {
        guard self.callProcessID == processID, let callWindow = self.callWindow else { return false }
        do {
            var reader = MeetingMuteControlLocator.Reader()
            let app = AXUIElementCreateApplication(processID)
            guard let focused = try reader.value(app, kAXFocusedWindowAttribute as String),
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
            return CFEqual(focused, callWindow)
        } catch { return false }
    }

    func sample(processID: Int32, boundWindowID: UInt32?) -> Snapshot {
        guard AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: processID)?.bundleIdentifier == "us.zoom.xos",
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              records.count <= 4_096 else { return .unavailable }
        let descriptors = records.compactMap { record -> MeetingMuteControlLocator.WindowDescriptor? in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return .init(windowID: id, processID: processID, bundleIdentifier: "us.zoom.xos",
                frame: frame, title: record[kCGWindowName as String] as? String)
        }
        guard !descriptors.isEmpty, descriptors.count <= 64 else { return .unavailable }
        do {
            var reader = MeetingMuteControlLocator.Reader()
            let app = AXUIElementCreateApplication(processID)
            let windows = try reader.elements(app, kAXWindowsAttribute as String)
            guard windows.count <= 16 else { return .unavailable }
            var calls: [(AXUIElement, MeetingMuteControlLocator.WindowDescriptor)] = []
            for window in windows {
                guard try reader.string(window, kAXIdentifierAttribute as String) == "zm.meeting.window.main",
                      let frame = try reader.frame(window),
                      let descriptor = MeetingMuteControlLocator.matchingWindow(processID: processID, frame: frame,
                        title: try reader.string(window, kAXTitleAttribute as String), windows: descriptors),
                      boundWindowID == nil || descriptor.windowID == boundWindowID else { continue }
                calls.append((window, descriptor))
            }
            guard calls.count == 1, let call = calls.first else { self.invalidate(); return .unavailable }
            self.callWindow = call.0
            self.callProcessID = processID
            let state = try self.renderedState(window: call.0, descriptor: call.1, reader: &reader)
            let hud = self.temporaryHUD(windows: windows, app: app, call: call.0, processID: processID,
                descriptors: descriptors, reader: &reader)
            return Snapshot(callWindowID: call.1.windowID, state: state, temporaryHUDVisible: hud)
        } catch { return .unavailable }
    }

    private static func ownsForegroundCall(app: AXUIElement, call: AXUIElement, processID: Int32,
        reader: inout MeetingMuteControlLocator.Reader) throws -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let focused = try reader.value(app, kAXFocusedWindowAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focused, call)
    }

    private func renderedState(window: AXUIElement, descriptor: MeetingMuteControlLocator.WindowDescriptor,
        reader: inout MeetingMuteControlLocator.Reader) throws -> MeetingMicrophoneMuteState? {
        if let tile = self.tile, tile.processID == descriptor.processID, tile.windowID == descriptor.windowID,
           CFEqual(tile.path[0], window), try reader.validate(tile.path), let element = tile.path.last {
            let role = try reader.string(element, kAXRoleAttribute as String)
            let description = try reader.string(element, kAXRoleDescriptionAttribute as String)
            if Self.isVideoRenderer(role: role, description: description),
               let state = try Self.tileState(element, reader: &reader) { return state }
        }
        self.tile = nil
        var pending: [([AXUIElement], Int)] = [([window], 0)]
        var states: [(MeetingMicrophoneMuteState, [AXUIElement])] = []
        var visited = 0
        while let (path, depth) = pending.popLast() {
            visited += 1
            guard visited <= 128, let element = path.last else { return nil }
            try reader.visit()
            let role = try reader.string(element, kAXRoleAttribute as String)
            let description = try reader.string(element, kAXRoleDescriptionAttribute as String)
            if Self.isVideoRenderer(role: role, description: description),
               let state = try Self.tileState(element, reader: &reader) { states.append((state, path)) }
            guard depth < 4, !Self.isTextInput(role), role != "AXWebArea", role != "AXScrollArea" else { continue }
            for child in try reader.elements(element).reversed() { pending.append((path + [child], depth + 1)) }
        }
        guard states.count == 1, let first = states.first else { return nil }
        self.tile = CachedTile(processID: descriptor.processID, windowID: descriptor.windowID, path: first.1)
        return first.0
    }

    private static func tileState(_ element: AXUIElement, reader: inout MeetingMuteControlLocator.Reader) throws -> MeetingMicrophoneMuteState? {
        let states = try [kAXDescriptionAttribute as String, kAXValueAttribute as String]
            .compactMap { Self.selfTileState(try reader.string(element, $0)) }
        guard let first = states.first, states.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Only status-only metadata is accepted. AXTitle and combined display-name text cannot
    /// identify a self tile, because a peer can choose an arbitrary display name.
    static func selfTileState(_ value: String?) -> MeetingMicrophoneMuteState? {
        guard let text = value?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() else { return nil }
        if text == "computer audio muted" { return .muted }
        if text == "computer audio unmuted" { return .unmuted }
        return nil
    }

    static func isTemporaryHUDText(_ value: String?) -> Bool {
        value?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() == "temporarily unmuted"
    }

    private static func isVideoRenderer(role: String?, description: String?) -> Bool {
        ["video render", "video renderer"].contains(description?.lowercased() ?? "")
            || ["AXVideoRender", "AXVideoRenderer"].contains(role ?? "")
    }

    private static func isTextInput(_ role: String?) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "")
    }

    private func temporaryHUD(windows: [AXUIElement], app: AXUIElement, call: AXUIElement, processID: Int32,
        descriptors: [MeetingMuteControlLocator.WindowDescriptor], reader: inout MeetingMuteControlLocator.Reader) -> Bool? {
        do {
            guard try Self.ownsForegroundCall(app: app, call: call, processID: processID, reader: &reader) else { return nil }
            for window in windows where !CFEqual(window, call) {
                guard let frame = try reader.frame(window), (32...400).contains(frame.width),
                      (32...250).contains(frame.height), frame.width * frame.height <= 80_000,
                      descriptors.contains(where: { abs($0.frame.minX - frame.minX) <= 2 && abs($0.frame.minY - frame.minY) <= 2
                        && abs($0.frame.width - frame.width) <= 2 && abs($0.frame.height - frame.height) <= 2 }) else { continue }
                var pending = [(window, 0)]
                var matched = false, interactive = false, visited = 0
                while let (element, depth) = pending.popLast() {
                    visited += 1
                    guard visited <= 48 else { return nil }
                    try reader.visit()
                    let role = try reader.string(element, kAXRoleAttribute as String)
                    if Self.isTextInput(role) || role == "AXButton" || role == "AXCheckBox" { interactive = true; break }
                    if ["AXStaticText", "AXImage", "AXUnknown", "AXGroup"].contains(role ?? "") {
                        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                            if Self.isTemporaryHUDText(try reader.string(element, attribute)) { matched = true }
                        }
                    }
                    if depth < 4 { pending.append(contentsOf: try reader.elements(element).map { ($0, depth + 1) }) }
                }
                if matched, !interactive {
                    return try Self.ownsForegroundCall(app: app, call: call, processID: processID, reader: &reader) ? true : nil
                }
            }
            return false
        } catch { return nil }
    }
}
#endif
