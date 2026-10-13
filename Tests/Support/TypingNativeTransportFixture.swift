import Foundation
import CoreFoundation

// Concatenated only into the synthetic source fixture, never the application.
// These local names model the final OS edges without linking input frameworks.
// The owner supplies syntheticAX, allowCGEvents and onEventConstruct.
nonisolated final class CGEventSource: NSObject, @unchecked Sendable {}

nonisolated enum CGEventTapLocation {
    case cghidEventTap
}

nonisolated final class CGEvent: NSObject, @unchecked Sendable {
    private let keyDown: Bool
    private var unicode: [UInt16] = []

    init?(keyboardEventSource: CGEventSource?, virtualKey: UInt16, keyDown: Bool) {
        guard syntheticAX.allowCGEvents else { return nil }
        syntheticAX.onEventConstruct?()
        guard syntheticAX.allowCGEvents else { return nil }
        self.keyDown = keyDown
        super.init()
    }

    func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UInt16>) {
        self.unicode = Array(UnsafeBufferPointer(start: unicodeString, count: max(0, stringLength)))
    }

    func postToPid(_ pid: pid_t) {
        guard let field = syntheticAX.focus, field.pid == pid else { return }
        self.insert(into: field.id)
    }

    func post(tap: CGEventTapLocation) {
        guard let field = syntheticAX.focus else { return }
        self.insert(into: field.id)
    }

    private func insert(into id: String) {
        guard self.keyDown, !self.unicode.isEmpty else { return }
        syntheticAX.values[id, default: ""] += String(decoding: self.unicode, as: UTF16.self)
        syntheticAX.insertions.append(id)
    }
}

nonisolated enum AXValueType {
    case cfRange
}

nonisolated final class AXValue: NSObject, @unchecked Sendable {
    let range: CFRange

    init(range: CFRange) {
        self.range = range
        super.init()
    }
}

nonisolated func AXValueGetTypeID() -> CFTypeID { 125 }

nonisolated func AXValueGetValue(
    _ value: AXValue,
    _ type: AXValueType,
    _ range: UnsafeMutablePointer<CFRange>
) -> Bool {
    range.pointee = value.range
    return true
}

nonisolated func AXValueCreate(_ type: AXValueType, _ range: UnsafePointer<CFRange>) -> AXValue? {
    AXValue(range: range.pointee)
}

nonisolated enum NSPasteboard {
    nonisolated struct PasteboardType: RawRepresentable, Hashable {
        let rawValue: String

        init(rawValue: String) { self.rawValue = rawValue }
        init(_ rawValue: String) { self.rawValue = rawValue }

        static let string = Self("public.utf8-plain-text")
    }
}
