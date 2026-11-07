#if os(macOS)
import AppKit
import Foundation

/// Passive Space observation only. It does not suppress, synthesize, inspect or log text input.
final nonisolated class MeetingMutePTTListener: @unchecked Sendable {
    enum Event: Sendable {
        case key(held: Bool, timestampNanoseconds: UInt64?, keyCode: UInt16 = 49, modifierFlags: UInt64 = 0)
        case modifiersChanged(timestampNanoseconds: UInt64?, modifierFlags: UInt64)
        case disabled
    }
    private let keyCodes: Set<Int64>
    private let handler: @Sendable (Event) -> Void
    private let started = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?

    init(keyCodes: Set<Int64> = [49], handler: @escaping @Sendable (Event) -> Void) { self.keyCodes = keyCodes; self.handler = handler }

    func start() -> Bool {
        guard self.thread == nil, CGPreflightListenEventAccess() else { return false }
        let thread = Thread { [self] in
            defer { self.exited.signal() }
            let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
            self.tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: { _, type, event, pointer in
                    guard let pointer else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<MeetingMutePTTListener>.fromOpaque(pointer).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.handler(.disabled)
                        return Unmanaged.passUnretained(event)
                    }
                    if type == .flagsChanged {
                        owner.handler(.modifiersChanged(timestampNanoseconds: event.timestamp > 0 ? event.timestamp : nil, modifierFlags: event.flags.rawValue))
                        return Unmanaged.passUnretained(event)
                    }
                    let code = event.getIntegerValueField(.keyboardEventKeycode)
                    guard owner.keyCodes.contains(code), let keyCode = UInt16(exactly: code) else { return Unmanaged.passUnretained(event) }
                    if type == .keyDown {
                        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return Unmanaged.passUnretained(event) }
                        owner.handler(.key(held: true, timestampNanoseconds: event.timestamp > 0 ? event.timestamp : nil, keyCode: keyCode, modifierFlags: event.flags.rawValue))
                    } else if type == .keyUp {
                        owner.handler(.key(held: false, timestampNanoseconds: event.timestamp > 0 ? event.timestamp : nil, keyCode: keyCode, modifierFlags: event.flags.rawValue))
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            self.runLoop = CFRunLoopGetCurrent()
            if let tap = self.tap {
                CFRunLoopAddSource(self.runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            self.started.signal()
            if self.tap != nil { CFRunLoopRun() }
            if let tap = self.tap { CFMachPortInvalidate(tap) }
        }
        thread.name = "meeting.microphone-mute.ptt"
        self.thread = thread
        thread.start()
        self.started.wait()
        return self.tap != nil
    }

    func stop() {
        guard self.thread != nil else { return }
        if let runLoop = self.runLoop { CFRunLoopStop(runLoop) }
        self.exited.wait()
        self.thread = nil
        self.runLoop = nil
        self.tap = nil
    }
}
#endif
