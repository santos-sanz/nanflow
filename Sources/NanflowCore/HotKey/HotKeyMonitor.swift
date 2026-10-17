import ApplicationServices
import CoreGraphics
import Foundation

public enum HotKey: String, CaseIterable, Sendable {
    case rightCommand
    case rightOption
    case fn
    case f5

    public var label: String {
        switch self {
        case .rightCommand: return "⌘ derecho (mantener)"
        case .rightOption: return "⌥ derecho (mantener)"
        case .fn: return "Fn (mantener)"
        case .f5: return "F5 (mantener)"
        }
    }

    public var keyCodes: Set<UInt32> {
        switch self {
        case .rightCommand: return [54]
        case .rightOption: return [58]
        case .fn: return [63]
        case .f5: return [96]
        }
    }
}

/// Global hold-to-talk hotkey using a CGEventTap. Fires onPress / onRelease.
public final class HotKeyMonitor {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onCancel: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let lifecycleLock = NSLock()
    private var shouldStop = false
    private var hotKey: HotKey = .rightCommand
    private var isDown = false

    public init() {}

    public var current: HotKey { hotKey }

    public func start(hotKey: HotKey) {
        stop()
        lifecycleLock.lock()
        shouldStop = false
        lifecycleLock.unlock()
        self.hotKey = hotKey
        isDown = false

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = monitor.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let passThrough = monitor.handle(type: type, event: event)
            return passThrough ? Unmanaged.passUnretained(event) : nil
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            // Sin permiso de Accesibilidad: intenta listen-only (no puede suprimir la tecla)
            if let listenOnly = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: refcon
            ) {
                NFLog.write("hotkey: listenOnly fallback (sin Accesibilidad)")
                install(tap: listenOnly)
            }
            return
        }
        NFLog.write("hotkey: tap activo")
        install(tap: port)
    }

    private func install(tap: CFMachPort) {
        lifecycleLock.lock()
        shouldStop = false
        self.tap = tap
        lifecycleLock.unlock()

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lifecycleLock.lock()
        runLoopSource = source
        lifecycleLock.unlock()

        // El tap vive en su propio hilo con su propio run loop: así los cambios de modo
        // del run loop de NSApplication (burbuja, micrófono, paneles) no lo silencian.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)

            self.lifecycleLock.lock()
            let stopping = self.shouldStop
            if !stopping { self.tapRunLoop = runLoop }
            self.lifecycleLock.unlock()

            if stopping {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                return
            }

            CGEvent.tapEnable(tap: tap, enable: true)
            NFLog.write("hotkey: tap run loop arrancado")
            CFRunLoopRun()
            NFLog.write("hotkey: tap run loop terminado")
        }
        thread.name = "nanflow.hotkey"
        thread.stackSize = 256 * 1024
        tapThread = thread
        thread.start()
    }

    public func stop() {
        lifecycleLock.lock()
        shouldStop = true
        let port = tap
        let runLoop = tapRunLoop
        let source = runLoopSource
        tap = nil
        tapRunLoop = nil
        runLoopSource = nil
        isDown = false
        lifecycleLock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoop, let source {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    /// Returns true if the event should pass through, false to suppress it.
    @discardableResult
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown, code == 53, onCancel?() == true {
            return false
        }

        if UserDefaults.standard.bool(forKey: "nanflow.debug.taplog") {
            NFLog.write("tap: type=\(type.rawValue) code=\(code) flags=\(event.flags.rawValue)")
        }

        // Eventos sintéticos (System Events / AppleScript): flagsChanged con code=0.
        // Los mapeamos por flag de modificador si el hotkey es una tecla modificadora.
        if type == .flagsChanged, code == 0, hotKey != .f5 {
            let flags = event.flags
            let modifierSet: Bool
            switch hotKey {
            case .rightCommand, .rightOption: modifierSet = flags.contains(.maskCommand) || flags.contains(.maskAlternate)
            case .fn: modifierSet = flags.contains(.maskSecondaryFn)
            case .f5: modifierSet = true
            }
            if modifierSet, !isDown {
                press()
            } else if !modifierSet, isDown {
                release()
            }
            return false
        }

        let keycodes = hotKey.keyCodes
        guard keycodes.contains(UInt32(code)) else { return true }

        // Teclas modificadoras (⌘⌥Fn) emiten flagsChanged en vez de keyDown/keyUp:
        // decidimos por el estado del flag del modificador.
        if type == .flagsChanged, hotKey != .f5 {
            let flags = event.flags
            let modifierSet: Bool
            switch hotKey {
            case .rightCommand: modifierSet = flags.contains(.maskCommand)
            case .rightOption: modifierSet = flags.contains(.maskAlternate)
            case .fn: modifierSet = flags.contains(.maskSecondaryFn)
            case .f5: modifierSet = true
            }
            if modifierSet, !isDown {
                press()
            } else if !modifierSet, isDown {
                release()
            }
            return false
        }

        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 1 { return false }
            if !isDown { press() }
            return false
        case .keyUp:
            if isDown { release() }
            return false
        default:
            return true
        }
    }

    private func press() {
        isDown = true
        NFLog.write("hotkey: DOWN")
        DispatchQueue.main.async { [weak self] in self?.onPress?() }
    }

    private func release() {
        isDown = false
        NFLog.write("hotkey: UP")
        DispatchQueue.main.async { [weak self] in self?.onRelease?() }
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }
}
