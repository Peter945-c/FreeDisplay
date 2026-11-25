import AppKit
import CoreGraphics
import ObjectiveC

// The private CoreGraphics classes behind the virtual-display HiDPI fallback, reached through @objc protocols so that
// no header and no linking is needed. VirtualDisplayEngine checks that every selector it sends exists before using
// them, so a macOS that drops or renames one gets "unavailable", never an unrecognized-selector crash.
@objc private protocol VirtualDisplayDescriptorAPI: NSObjectProtocol {
    init()
    func setDispatchQueue(_ queue: DispatchQueue)
    func setName(_ name: NSString)
    func setMaxPixelsWide(_ value: UInt32)
    func setMaxPixelsHigh(_ value: UInt32)
    func setSizeInMillimeters(_ size: CGSize)
    func setVendorID(_ value: UInt32)
    func setProductID(_ value: UInt32)
    func setSerialNum(_ value: UInt32)
    func setRedPrimary(_ point: CGPoint)
    func setGreenPrimary(_ point: CGPoint)
    func setBluePrimary(_ point: CGPoint)
    func setWhitePoint(_ point: CGPoint)
}

@objc private protocol VirtualDisplayModeAPI: NSObjectProtocol {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}

@objc private protocol VirtualDisplaySettingsAPI: NSObjectProtocol {
    init()
    func setModes(_ modes: NSArray)
    func setHiDPI(_ value: UInt32)
}

@objc private protocol VirtualDisplayAPI: NSObjectProtocol {
    init(descriptor: AnyObject)
    func applySettings(_ settings: AnyObject) -> Bool
    var displayID: UInt32 { get }
}

/// HiDPI fallback for an external display that macOS gives no HiDPI mode between 2× and native (only 1280 × 720 HiDPI
/// on a 2560 × 1440 panel): a virtual display with HiDPI modes up to twice the panel's size, which the real display
/// mirrors, so macOS renders at, say, 4096 × 2304 and the panel shows it scaled to 2560 × 1440.
///
/// The virtual display exists only while FreeDisplay runs. It costs HDR and some GPU time, which is why it is offered
/// only when no native fractional HiDPI mode exists and only when the user turns it on.
@MainActor
public final class VirtualDisplayEngine {
    public static let shared = VirtualDisplayEngine()

    public struct Session {
        public let physicalID: CGDirectDisplayID
        public let virtualID: CGDirectDisplayID
        public let physicalKey: String
        public let physicalName: String
        public let nativeWidth: Int
        public let nativeHeight: Int
        public let diagonalInches: Double
        public let nativePPI: Int
        let previousPhysicalMode: Int32
        let display: AnyObject // keeps the virtual display alive; releasing it removes the display
    }

    public enum StartError: Error {
        case unavailable, createFailed, noHiDPIModes, mirrorFailed

        public var message: String {
            switch self {
            case .unavailable:
                return L10n.tr(zh: "这台 Mac 的 macOS 不支持虚拟屏", en: "this macOS has no virtual display support")
            case .createFailed:
                return L10n.tr(zh: "macOS 拒绝创建虚拟屏", en: "macOS refused to create the virtual display")
            case .noHiDPIModes:
                return L10n.tr(zh: "macOS 没有给虚拟屏更大的 HiDPI 画布", en: "macOS gave the virtual display no larger HiDPI canvas")
            case .mirrorFailed:
                return L10n.tr(zh: "无法让显示器镜像虚拟屏", en: "the display could not mirror the virtual display")
            }
        }
    }

    public private(set) var session: Session?

    public var isAvailable: Bool { api != nil }

    private struct API {
        let descriptor: VirtualDisplayDescriptorAPI.Type
        let mode: VirtualDisplayModeAPI.Type
        let settings: VirtualDisplaySettingsAPI.Type
        let display: VirtualDisplayAPI.Type
    }

    private let api: API?

    private init() {
        api = Self.loadAPI()
    }

    private static func loadAPI() -> API? {
        guard let descriptor = NSClassFromString("CGVirtualDisplayDescriptor"),
              let mode = NSClassFromString("CGVirtualDisplayMode"),
              let settings = NSClassFromString("CGVirtualDisplaySettings"),
              let display = NSClassFromString("CGVirtualDisplay") else {
            return nil
        }
        let needed: [(AnyClass, [String])] = [
            (descriptor, ["init", "setDispatchQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:",
                          "setSizeInMillimeters:", "setVendorID:", "setProductID:", "setSerialNum:",
                          "setRedPrimary:", "setGreenPrimary:", "setBluePrimary:", "setWhitePoint:"]),
            (mode, ["initWithWidth:height:refreshRate:"]),
            (settings, ["init", "setModes:", "setHiDPI:"]),
            (display, ["initWithDescriptor:", "applySettings:", "displayID"]),
        ]
        for entry in needed {
            let cls: AnyClass = entry.0
            for name in entry.1 where !class_respondsToSelector(cls, NSSelectorFromString(name)) {
                return nil
            }
        }
        return API(
            descriptor: unsafeBitCast(descriptor, to: VirtualDisplayDescriptorAPI.Type.self),
            mode: unsafeBitCast(mode, to: VirtualDisplayModeAPI.Type.self),
            settings: unsafeBitCast(settings, to: VirtualDisplaySettingsAPI.Type.self),
            display: unsafeBitCast(display, to: VirtualDisplayAPI.Type.self)
        )
    }

    /// A physical display's identity across reconnects and relaunches.
    public nonisolated static func key(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// Vendor ID of the virtual displays FreeDisplay creates, so a leftover one can be told apart from real panels.
    public nonisolated static let vendorID: UInt32 = 0xF0D1

    /// HiDPI sizes for the virtual display at the panel's aspect ratio: native, ~125%, ~133%, ~160% and 2×, the same
    /// steps as the presets. macOS adds its usual list of smaller sizes on top.
    nonisolated static func logicalSizes(nativeWidth w: Int, nativeHeight h: Int) -> [(Int, Int)] {
        let even = { (x: Double) -> Int in Int((x / 2).rounded()) * 2 }
        return [1.0, 1.25, 4.0 / 3.0, 1.6, 2.0].map { (even(Double(w) / $0), even(Double(h) / $0)) }
    }

    /// Creates the virtual display and mirrors `physical` onto it, starting at the ~125% size. Returns the virtual
    /// display's ID. On failure nothing is left behind.
    public func start(for physical: DisplayDevice) async -> Result<CGDirectDisplayID, StartError> {
        guard let api = api else { return .failure(.unavailable) }
        stop()
        // A virtual display released moments ago can still be online for a fraction of a second; let it go first
        // (up to 3 s, with the fallback commit after 1 s).
        for attempt in 0..<30 {
            if Self.leftoverVirtualDisplays().isEmpty { break }
            if attempt == 10 { Self.flushReleasedDisplays() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let w = physical.nativeWidth, h = physical.nativeHeight
        let hz = Double(physical.currentMode?.refreshRate ?? physical.maxRefreshRate)
        let serial = CGDisplaySerialNumber(physical.id)

        // CoreGraphics autoreleases the new virtual display during setup. Drain that here, so that our reference is
        // the only one and releasing it removes the display at once (Swift tasks don't drain the pool promptly).
        var display: VirtualDisplayAPI? = autoreleasepool {
            let descriptor = api.descriptor.init()
            descriptor.setDispatchQueue(DispatchQueue.main)
            descriptor.setName("\(physical.name) HiDPI" as NSString)
            descriptor.setMaxPixelsWide(UInt32(w * 2))
            descriptor.setMaxPixelsHigh(UInt32(h * 2))
            descriptor.setSizeInMillimeters(CGDisplayScreenSize(physical.id))
            descriptor.setVendorID(Self.vendorID)
            descriptor.setProductID(CGDisplayModelNumber(physical.id) & 0xFFFF)
            descriptor.setSerialNum(serial == 0 ? 1 : serial)
            // sRGB / Rec. 709 primaries and D65 white
            descriptor.setRedPrimary(CGPoint(x: 0.640, y: 0.330))
            descriptor.setGreenPrimary(CGPoint(x: 0.300, y: 0.600))
            descriptor.setBluePrimary(CGPoint(x: 0.150, y: 0.060))
            descriptor.setWhitePoint(CGPoint(x: 0.3127, y: 0.3290))

            let display = api.display.init(descriptor: descriptor)
            let settings = api.settings.init()
            settings.setHiDPI(1)
            let modes = Self.logicalSizes(nativeWidth: w, nativeHeight: h).map {
                api.mode.init(width: UInt32($0.0), height: UInt32($0.1), refreshRate: hz)
            }
            settings.setModes(modes as NSArray)
            guard display.applySettings(settings), display.displayID != 0 else { return nil }
            return display
        }
        guard let virtualID = display?.displayID else {
            sweepLeftovers()
            return .failure(.createFailed)
        }

        // The virtual display comes online asynchronously; wait up to 3 s for its fractional HiDPI modes.
        var fractional: [DisplayModeItem] = []
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            fractional = SkyLightEngine.shared.fetchAllModes(for: virtualID).filter {
                $0.isHiDPI && $0.isSafe && $0.width * 2 > w + 8 && $0.width < w - 8
            }
            if !fractional.isEmpty { break }
        }
        guard !fractional.isEmpty else {
            Self.discard(&display)
            sweepLeftovers()
            return .failure(.noHiDPIModes)
        }

        let previous = SkyLightEngine.shared.fetchCurrentModeNumber(for: physical.id)
        guard Self.mirror(physical.id, onto: virtualID), let created = display else {
            Self.discard(&display)
            sweepLeftovers()
            return .failure(.mirrorFailed)
        }
        session = Session(
            physicalID: physical.id,
            virtualID: virtualID,
            physicalKey: Self.key(for: physical.id),
            physicalName: physical.name,
            nativeWidth: w,
            nativeHeight: h,
            diagonalInches: physical.diagonalInches,
            nativePPI: physical.nativePPI,
            previousPhysicalMode: previous,
            display: created
        )
        display = nil // the session now holds the only reference

        let target = Int((Double(w) / 1.25).rounded())
        if let first = fractional.min(by: { abs($0.width - target) < abs($1.width - target) }) {
            SkyLightEngine.shared.applyMode(first.modeNumber, to: virtualID, permanently: true)
        }
        return .success(virtualID)
    }

    /// Stops mirroring, removes the virtual display and puts the real display back in the mode it had before.
    public func stop() {
        guard let physical = session?.physicalID, let previous = session?.previousPhysicalMode else { return }
        Self.mirror(physical, onto: kCGNullDirectDisplay)
        // The session holds the only reference to the virtual display; dropping it releases the display.
        autoreleasepool {
            session = nil
        }
        sweepLeftovers()
        // macOS normally restores the panel's previous mode by itself; check once it has settled.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if previous >= 0, CGDisplayIsOnline(physical) != 0,
               SkyLightEngine.shared.fetchCurrentModeNumber(for: physical) != previous {
                SkyLightEngine.shared.applyMode(previous, to: physical, permanently: true)
            }
        }
    }

    /// Releases a virtual display that never became a session (setup failed part-way).
    private static func discard(_ display: inout VirtualDisplayAPI?) {
        autoreleasepool {
            display = nil
        }
    }

    /// Online FreeDisplay virtual displays that no session owns: released ones macOS has not removed yet.
    nonisolated static func leftoverVirtualDisplays(except active: CGDirectDisplayID? = nil) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { $0 != active && CGDisplayVendorNumber($0) == vendorID }
    }

    /// Makes sure no released virtual display is left behind as an invisible extended desktop. macOS removes one
    /// within a fraction of a second; if it is still online after a second, the fallback commit makes it go.
    public func sweepLeftovers() {
        Task { @MainActor in
            for attempt in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Self.leftoverVirtualDisplays(except: self.session?.virtualID).isEmpty { return }
                if attempt >= 3 { Self.flushReleasedDisplays() }
            }
        }
    }

    /// Fallback for a released virtual display that stays online: an empty permanent configuration commit makes
    /// WindowServer drop it. Normally not needed; macOS removes the display on release.
    private static func flushReleasedDisplays() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    @discardableResult
    private static func mirror(_ display: CGDirectDisplayID, onto primary: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(config, display, primary) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
