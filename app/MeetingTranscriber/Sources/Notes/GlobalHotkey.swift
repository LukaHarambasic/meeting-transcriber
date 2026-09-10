import Carbon.HIToolbox
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "GlobalHotkey")

/// Registers a single global hotkey via Carbon's `RegisterEventHotKey`,
/// deliberately not `NSEvent.addGlobalMonitorForEvents`: the NSEvent
/// global-monitor route only delivers events to a process holding an
/// Accessibility grant, which this app never requests, so it would silently
/// never fire. Carbon's hotkey API needs no such grant.
///
/// The C callback Carbon invokes is a bare `@convention(c)` function pointer
/// and cannot capture Swift state, so every registered instance is tracked
/// in a static table keyed by the hotkey ID Carbon hands back on each event;
/// the callback looks itself up there and calls its handler. Carbon
/// dispatches hotkey events on the main run loop, so the callback bridges
/// onto the main actor with `MainActor.assumeIsolated` rather than hopping
/// through an async `Task` (which would let a second press register before
/// the first was handled).
@MainActor
final class GlobalHotkey {
    /// Virtual key code for "N" on a US keyboard layout — the fixed Carbon
    /// keycode table, independent of the current input source.
    static let virtualKeyCodeN: UInt32 = 45

    /// ⌥⌘N.
    static let optionCommandModifiers = UInt32(optionKey | cmdKey)

    /// Four-char signature identifying this app's hotkey registrations to
    /// Carbon. Arbitrary but must be non-zero.
    private static let signature: OSType = 0x6E6F_7465 // 'note'

    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var didInstallHandler = false

    private let id: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    /// Whether `RegisterEventHotKey` succeeded. False when, for example,
    /// another process already owns this key combination; callers should
    /// surface that rather than assume the shortcut works.
    private(set) var isRegistered = false

    init(
        keyCode: UInt32 = GlobalHotkey.virtualKeyCodeN,
        modifiers: UInt32 = GlobalHotkey.optionCommandModifiers,
        handler: @escaping () -> Void,
    ) {
        id = Self.nextID
        Self.nextID += 1
        self.handler = handler
        Self.registry[id] = self
        Self.installHandlerIfNeeded()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    /// `isolated deinit`: without it, `deinit` runs on no actor at all (Swift
    /// deinitializers are non-isolated by default even on a `@MainActor`
    /// class) and cannot touch `registry`, which is main-actor state shared
    /// with the Carbon callback.
    isolated deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.registry[id] = nil
    }

    /// Unregisters the hotkey. Safe to call more than once.
    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        Self.registry[id] = nil
        isRegistered = false
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref,
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            isRegistered = true
        } else {
            isRegistered = false
            logger.error("RegisterEventHotKey failed with OSStatus \(status)")
        }
    }

    /// Installs the single process-wide Carbon event handler on first use.
    /// One handler serves every `GlobalHotkey` instance; it dispatches by
    /// the hotkey ID carried on each event.
    private static func installHandlerIfNeeded() {
        guard !didInstallHandler else { return }
        didInstallHandler = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed),
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID,
            )
            guard status == noErr else { return status }
            MainActor.assumeIsolated {
                // `Self` here would make this closure capture the dynamic
                // Self type, which a C function pointer cannot do — the
                // qualified name is required, not a style choice.
                // swiftlint:disable:next prefer_self_in_static_references
                GlobalHotkey.registry[pressedID.id]?.handler()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
