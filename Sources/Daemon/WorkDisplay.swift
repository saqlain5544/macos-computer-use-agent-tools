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

    // Smaller than any Mac's built-in display on purpose. macOS places a new
    // display at the origin — and therefore makes it the main display — when it
    // is at least as large as the real one; a smaller display is placed beside
    // it and the person's screen is untouched. Measured: 1512x950 stole the main
    // role on a 1512x982 display, 1200x800 did not.
    private static let width = 1512
    private static let height = 950

    private static var lastError = ""
    private var display: AnyObject?
    /// Where each app is parked. Cascaded so two apps never overlap exactly.
    private var regions: [String: CGRect] = [:]
    private(set) var staged: [(identity: String, agent: String, label: String, region: CGRect)] = []

    func region(for identity: String) -> CGRect {
        if let r = regions[identity] { return r }
        let b = bounds
        let index = regions.count
        let offset = CGFloat(index % 6) * 26
        let r = CGRect(x: b.minX + 20 + offset, y: b.minY + 20 + offset,
                       width: b.width - 40 - offset, height: b.height - 40 - offset)
        regions[identity] = r
        return r
    }

    func note(identity: String, agent: String, label: String) {
        let r = region(for: identity)
        staged.removeAll { $0.identity == identity }
        staged.append((identity, agent, label, r))
    }

    func forget(identity: String) {
        regions.removeValue(forKey: identity)
        staged.removeAll { $0.identity == identity }
    }
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
        // The person's main display must stay theirs. Creating a display can, on
        // some arrangements, make macOS promote the new one to main — which would
        // re-arrange what the person sees. Check, and give it straight back.
        let mainBefore = CGMainDisplayID()
        // Creating a display is occasionally refused or slow to activate, more so
        // right after another one was released. Try a few times before deciding
        // the machine will not have it.
        var made: Made?
        for attempt in 0..<3 {
            made = Self.create(width: Self.width, height: Self.height)
            if made != nil { break }
            usleep(1_200_000)
            if attempt == 1 { failure = "could not create a virtual display (\(Self.lastError))" }
        }
        guard let made else {
            failure = "could not create a virtual display (\(Self.lastError))"
            return false
        }
        // A new virtual display is placed at the origin, which makes it the main
        // display and moves the person's screen. Position it to the right of the
        // real one instead: the display at the origin stays main.
        if made.id != mainBefore {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                let mainW = CGDisplayPixelsWide(mainBefore)
                CGConfigureDisplayOrigin(config, made.id, Int32(mainW), 0)
                _ = CGCompleteDisplayConfiguration(config, .forSession)
            }
        }
        // The main display can flip to the new one for a moment while the
        // arrangement settles. Give it time to come back before deciding: a
        // display that steals the main role for good is refused.
        var returned = false
        for _ in 0..<40 {
            if CGMainDisplayID() == mainBefore { returned = true; break }
            usleep(100_000)
        }
        if !returned {
            display = nil
            failure = "creating the work display changed the person's main display, so it was released"
            return false
        }
        display = made.object
        displayID = made.id
        return true
    }

    /// Put a window on the work display. Returns the frame it was moved to.
    func stage(identity: String, windowId: UInt32, size: CGSize,
               helper: Helper, pid: Int32) -> (frame: CGRect, error: String?, wasFullscreen: Bool) {
        guard ensure() else { return (.zero, failure ?? "no work display", false) }
        var wasFullscreen = false
        let b = bounds
        // Each app parks in its own region of the one work display: separate
        // spaces for separate apps, without a second virtual display (creating
        // another one can be promoted to main display by macOS, which would
        // re-arrange the person's screen).
        let r = region(for: identity)
        _ = b
        let w = min(max(size.width, 200), r.width)
        let h = min(max(size.height, 150), r.height)
        let origin = CGPoint(x: r.minX, y: r.minY)
        do {
            let moved = try helper.moveWindow(windowId: windowId, pid: pid,
                                              x: origin.x, y: origin.y, w: w, h: h)
            guard moved.ok else {
                return (.zero, "the app would not let the driver move its window", false)
            }
            wasFullscreen = moved.wasFullscreen
            // Report the frame the window actually has: an app may refuse the
            // resize while still accepting the move.
            let frame = (try? helper.windowFrame(windowId: windowId, pid: pid)) ?? Rect()
            let actual = frame.w > 1
                ? CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
                : CGRect(origin: origin, size: CGSize(width: w, height: h))
            return (actual, nil, wasFullscreen)
        } catch {
            return (.zero, "\(error)", false)
        }
    }

    /// Put a window back where it was.
    func restore(windowId: UInt32, pid: Int32, frame: CGRect, helper: Helper,
                 fullscreen: Bool = false) -> Bool {
        let moved = (try? helper.moveWindow(windowId: windowId, pid: pid,
                                            x: frame.origin.x, y: frame.origin.y,
                                            w: frame.width, h: frame.height))
        if fullscreen { helper.setWindowFullscreen(windowId: windowId, pid: pid, fullscreen: true) }
        return moved?.ok ?? false
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
