import AppKit
import Foundation

/// A simple service for clipboard operations
enum ClipboardService {
    /// Copies the provided text to the system clipboard
    /// - Parameter text: The text to copy to clipboard
    /// - Returns: Boolean indicating success or failure
    @discardableResult
    static func copyToClipboard(_ text: String, file: String = #fileID, line: Int = #line) -> Bool {
        guard !text.isEmpty else {
            DebugLogger.shared.debug("Attempted to copy empty text to clipboard, skipping", source: "ClipboardService")
            return false
        }

        let pasteboard = NSPasteboard.general
        ClipboardAudit.record("copy_begin", pasteboard: pasteboard, file: file, line: line)
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        ClipboardAudit.record("copy_end", pasteboard: pasteboard, detail: "success=\(success) chars=\(text.count)", file: file, line: line)

        if success {
            DebugLogger.shared.info("Copied \(text.count) characters to clipboard", source: "ClipboardService")
        } else {
            DebugLogger.shared.error("Failed to copy text to clipboard", source: "ClipboardService")
        }

        return success
    }

    /// Retrieves the current text content from the clipboard
    /// - Returns: The clipboard text, or nil if no text is available
    static func getFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        return pasteboard.string(forType: .string)
    }
}

/// Event-bound metadata only: no clipboard text, URLs, data payloads, or polling.
enum ClipboardAudit {
    #if DEBUG
    private nonisolated static let tracedKeyCodes = ClipboardAudit.shortcutTraceKeyCodes(environment: ProcessInfo.processInfo.environment)
    #endif

    /// Explicit, bounded debug opt-in. Reject the whole selection if any physical
    /// key code is invalid or more than two entries were supplied.
    nonisolated static func shortcutTraceKeyCodes(environment: [String: String]) -> Set<Int64> {
        #if DEBUG
        guard let selection = environment["PICHI_SHORTCUT_TRACE_KEY_CODES"] else { return [] }
        let entries = selection.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(entries.count) else { return [] }
        var codes = Set<Int64>()
        for entry in entries {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let code = Int64(value), (0...127).contains(code) else { return [] }
            codes.insert(code)
        }
        return codes
        #else
        return []
        #endif
    }

    nonisolated static func shortcutTraceMetadata(
        type: CGEventType,
        event: CGEvent,
        environment: [String: String]
    ) -> String? {
        self.shortcutTraceMetadata(type: type, event: event, keyCodes: self.shortcutTraceKeyCodes(environment: environment))
    }

    private nonisolated static func shortcutTraceMetadata(type: CGEventType, event: CGEvent, keyCodes: Set<Int64>) -> String? {
        guard type == .keyDown || type == .keyUp,
              keyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) else { return nil }
        return "eventType=\(type.rawValue) keyCode=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(event.flags.rawValue) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID)) targetPID=\(event.getIntegerValueField(.eventTargetUnixProcessID)) userData=\(event.getIntegerValueField(.eventSourceUserData)) eventTimestamp=\(event.timestamp)"
    }

    nonisolated static func recordShortcutTrace(type: CGEventType, event: CGEvent, cancelResult: String? = nil) {
        #if DEBUG
        guard DebugLogger.diagnosticsEnabled,
              let metadata = self.shortcutTraceMetadata(type: type, event: event, keyCodes: self.tracedKeyCodes) else { return }
        let phase = cancelResult.map { "cancel_result result=\($0)" } ?? "received"
        DebugLogger.shared.benchmark(
            "SHORTCUT_TRACE",
            message: "observerPID=\(ProcessInfo.processInfo.processIdentifier) phase=\(phase) \(metadata)",
            source: "ClipboardAudit"
        )
        #endif
    }

    /// Physical ANSI C/X/V candidates only; do not collect ordinary typing.
    /// Raw key codes avoid doing keyboard-layout queries in the event tap.
    nonisolated static func shortcutMetadata(type: CGEventType, event: CGEvent) -> String? {
        guard type == .keyDown, event.flags.contains(.maskCommand) else { return nil }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard [7, 8, 9].contains(keyCode) else { return nil }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let userData = event.getIntegerValueField(.eventSourceUserData)
        return "keyCode=\(keyCode) flags=\(event.flags.rawValue) sourcePID=\(sourcePID) targetPID=\(targetPID) userData=\(userData) eventTimestamp=\(event.timestamp)"
    }

    nonisolated static func recordShortcut(type: CGEventType, event: CGEvent) {
        guard DebugLogger.diagnosticsEnabled else { return }
        guard let metadata = self.shortcutMetadata(type: type, event: event) else { return }
        DebugLogger.shared.benchmark("CLIPBOARD_INPUT", message: metadata, source: "ClipboardAudit")
    }

    static func metadata(for pasteboard: NSPasteboard) -> String {
        let before = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        let types = items.first?.types ?? []
        let after = pasteboard.changeCount
        let transient = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let concealed = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let generated = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let chromium = types.contains(NSPasteboard.PasteboardType("org.chromium.source-url"))
        return "changeCount=\(after) stable=\(before == after) items=\(items.count) firstTypes=\(types.count) " +
            "text=\(types.contains(.string)) transient=\(transient) concealed=\(concealed) generated=\(generated) html=\(types.contains(.html)) chromium=\(chromium)"
    }

    static func record(
        _ event: String,
        pasteboard: @autoclosure () -> NSPasteboard = .general,
        detail: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) {
        guard DebugLogger.diagnosticsEnabled else { return }
        let pasteboard = pasteboard()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let metadata = self.metadata(for: pasteboard)
        let auditMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        DebugLogger.shared.benchmark(
            "CLIPBOARD_AUDIT",
            message: "schema=1 pid=\(ProcessInfo.processInfo.processIdentifier) event=\(event) caller=\(file):\(line) \(detail()) \(metadata) auditMs=\(auditMs)",
            source: "ClipboardAudit"
        )
    }
}
