import AppKit
import CoreGraphics

/// A display that exists only for the driver, so agent windows can be made
/// visible to the window server without ever appearing on the person's screen.
///
/// Why this exists: the window server routes synthetic mouse events only to
/// windows that are on the Space that is showing. An app on another Space — or
/// behind a fullscreen window — ignores every click, which is what stalled the
/// first real-world drives. Accessibility and keyboard still work there, but a
/// canvas app needs the mouse.
///
/// The fix is to give the driver its own display. A window moved onto it is
/// ordinary "on screen" as far as macOS is concerned, so clicks posted to the
/// owning process land — and the person never sees it, because a virtual display
/// has no physical output. Their Space, focus and pointer are untouched.
///
/// This uses the private CGVirtualDisplay API, the same one BetterDisplay, DeskPad
/// and the headless-agent tools use. It is looked up at runtime rather than
/// linked, so the driver still starts on a machine where the symbols are gone.
final class WorkDisplay {
    static let shared = WorkDisplay()

    private static let width = 1512
    private static let height = 950

    private static var lastError = ""
    private var display: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var failure: String?

    var bounds: CGRect {
        guard displayID != 0 else { return CGRect(x: 0, y: 0, width: Self.width, height: Self.height) }
        return CGDisplayBounds(displayID)
    }

    var isAvailable: Bool { displayID != 0 }

    /// The work display can be turned off: `QD_WORK_DISPLAY=0` keeps the driver
    /// from adding a display to the person's arrangement (some people do not
    /// want an extra screen in System Settings, and an agent that only uses
    /// accessibility and the keyboard does not need one).
    static var enabled: Bool { ProcessInfo.processInfo.environment["QD_WORK_DISPLAY"] != "0" }

    /// Create the display on first use. Cheap to call repeatedly.
    @discardableResult
    func ensure() -> Bool {
        if displayID != 0 { return true }
        guard Self.enabled else {
            failure = "the work display is disabled (QD_WORK_DISPLAY=0)"
            return false
        }
        // The daemon does its GUI work in workers, so it may not have a window
        // server connection of its own; creating a display needs one. Touching
        // NSApplication establishes it.
        _ = NSApplication.shared
        guard let made = Self.create(width: Self.width, height: Self.height) else {
            failure = "could not create a virtual display (\(Self.lastError))"
            return false
        }
        display = made.object
        displayID = made.id
        return true
    }

    /// Put a window on the work display. Returns the frame it was moved to.
    func stage(windowId: UInt32, size: CGSize, helper: Helper, pid: Int32) -> (frame: CGRect, error: String?) {
        guard ensure() else { return (.zero, failure ?? "no work display") }
        let b = bounds
        // Leave a margin so window shadows and resize handles stay on the display.
        let w = min(max(size.width, 200), b.width - 40)
        let h = min(max(size.height, 150), b.height - 40)
        let origin = CGPoint(x: b.minX + 20, y: b.minY + 20)
        do {
            let moved = try helper.moveWindow(windowId: windowId, pid: pid,
                                              x: origin.x, y: origin.y, w: w, h: h)
            guard moved else {
                return (.zero, "the app would not let the driver move its window")
            }
            // Report the frame the window actually has: an app may refuse the
            // resize while still accepting the move.
            let frame = (try? helper.windowFrame(windowId: windowId, pid: pid)) ?? Rect()
            let actual = frame.w > 1
                ? CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
                : CGRect(origin: origin, size: CGSize(width: w, height: h))
            return (actual, nil)
        } catch {
            return (.zero, "\(error)")
        }
    }

    /// Put a window back where it was.
    func restore(windowId: UInt32, pid: Int32, frame: CGRect, helper: Helper) -> Bool {
        (try? helper.moveWindow(windowId: windowId, pid: pid,
                                x: frame.origin.x, y: frame.origin.y,
                                w: frame.width, h: frame.height)) ?? false
    }

    // MARK: - the private API

    private struct Made {
        var object: AnyObject
        var id: CGDirectDisplayID
    }

    private static func objcAlloc(_ cls: AnyClass) -> AnyObject {
        // These classes do not answer +alloc, so the object is created through
        // the runtime directly.
        class_createInstance(cls, 0)! as AnyObject
    }

    private static func imp(_ cls: AnyClass, _ name: String) -> IMP? {
        guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return nil }
        return method_getImplementation(m)
    }

    private static func create(width: Int, height: Int) -> Made? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else {
            return nil
        }

        let descriptor = objcAlloc(descriptorClass) as! NSObject
        _ = descriptor.perform(NSSelectorFromString("init"))
        descriptor.setValue("Quiet Driver Work Display", forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 700, height: 440)), forKey: "sizeInMillimeters")
        descriptor.setValue(0xC0FFEE, forKey: "serialNum")
        descriptor.setValue(0x1234, forKey: "productID")
        descriptor.setValue(0x5678, forKey: "vendorID")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        typealias InitWithObject = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
        guard let displayInit = imp(displayClass, "initWithDescriptor:") else { return nil }
        let object = unsafeBitCast(displayInit, to: InitWithObject.self)(
            objcAlloc(displayClass), NSSelectorFromString("initWithDescriptor:"), descriptor) as! NSObject

        typealias ModeInit = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject
        guard let modeInit = imp(modeClass, "initWithWidth:height:refreshRate:") else { return nil }
        let mode = unsafeBitCast(modeInit, to: ModeInit.self)(
            objcAlloc(modeClass), NSSelectorFromString("initWithWidth:height:refreshRate:"),
            width, height, 60.0) as! NSObject

        let settings = objcAlloc(settingsClass) as! NSObject
        _ = settings.perform(NSSelectorFromString("init"))
        settings.setValue([mode], forKey: "modes")
        settings.setValue(true, forKey: "hiDPI")

        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Int32
        guard let applyImp = imp(displayClass, "applySettings:") else { return nil }
        let rc = unsafeBitCast(applyImp, to: Apply.self)(
            object, NSSelectorFromString("applySettings:"), settings)
        let id = (object.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        if ProcessInfo.processInfo.environment["QD_DEBUG_DISPLAY"] != nil {
            FileHandle.standardError.write(Data("work display: applySettings->\(rc) displayID->\(id)\n".utf8))
        }
        // applySettings reports 1 even when it works (the same value a working
        // proof of concept got), so the display id is what matters — and then
        // whether the display is actually active.
        guard id != 0 else {
            Self.lastError = "no display id was assigned (applySettings \(rc))"
            return nil
        }
        var active = false
        for _ in 0..<40 {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &ids, &count)
            if ids.prefix(Int(count)).contains(id) { active = true; break }
            usleep(50_000)
        }
        guard active else {
            Self.lastError = "display \(id) never became active"
            return nil
        }
        return Made(object: object, id: id)
    }
}
