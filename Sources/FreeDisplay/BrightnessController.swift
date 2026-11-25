import Foundation
import CoreGraphics
import IOKit

/// Brightness and warmth, per display. Brightness goes to the display over DDC/CI (VCP 0x10) through that display's
/// own IOAVService when it answers and warmth is off; otherwise brightness and warmth go into the display's gamma
/// table. Each display keeps its own values.
public final class BrightnessController {
    public static let shared = BrightnessController()

    public struct Settings: Equatable {
        public let brightness: Double
        public let warmth: Double

        public init(brightness: Double, warmth: Double) {
            self.brightness = min(100, max(20, brightness))
            self.warmth = min(50, max(0, warmth))
        }

        public static let neutral = Settings(brightness: 100, warmth: 0)

        /// Leaves the display as ColorSync set it up.
        public var isNeutral: Bool { brightness >= 99.5 && warmth <= 0.5 }
    }

    private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias DisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private let createAV: CreateWithServiceFn?
    private let writeI2C: I2CFn?
    private let readI2C: I2CFn?
    private let displayInfo: DisplayInfoFn?

    private let defaults = UserDefaults.standard
    private let settingsKey = "FreeDisplay.displayColor"
    // Up to 1.3.1, one brightness and warmth for every display; read once by adoptLegacySettings(for:).
    private let legacyBrightnessKey = "FreeDisplay.softwareBrightness"
    private let legacyWarmthKey = "FreeDisplay.softwareWarmth"

    /// Each display's DDC/CI service, looked up once per connection; nil when it has none FreeDisplay can use.
    private var ddcServices: [CGDirectDisplayID: (identity: String, service: CFTypeRef?)] = [:]
    /// Displays whose gamma table this process has changed.
    private var adjustedGamma: Set<CGDirectDisplayID> = []

    private init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        createAV = iokit.flatMap { dlsym($0, "IOAVServiceCreateWithService") }
            .map { unsafeBitCast($0, to: CreateWithServiceFn.self) }
        writeI2C = iokit.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }
        readI2C = iokit.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }
        let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        displayInfo = coreDisplay.flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }
            .map { unsafeBitCast($0, to: DisplayInfoFn.self) }
    }

    // MARK: - Saved values

    /// The saved brightness and warmth of display `id`; neutral when it has none.
    public func settings(for id: CGDirectDisplayID) -> Settings {
        guard let saved = savedSettings()[Self.identity(of: id)] else { return .neutral }
        return Settings(brightness: saved["brightness"] ?? 100, warmth: saved["warmth"] ?? 0)
    }

    /// Up to 1.3.1, FreeDisplay kept one brightness and warmth and applied them to the display the panel started on.
    /// Gives those values to that display, once, so an upgrade keeps them without dimming any other display.
    public func adoptLegacySettings(for id: CGDirectDisplayID) {
        guard defaults.object(forKey: settingsKey) == nil else { return }
        let brightness = defaults.object(forKey: legacyBrightnessKey) == nil ? 100 : defaults.double(forKey: legacyBrightnessKey)
        let legacy = Settings(brightness: brightness, warmth: defaults.double(forKey: legacyWarmthKey))
        defaults.set([String: [String: Double]](), forKey: settingsKey)
        save(legacy, for: id)
    }

    private func savedSettings() -> [String: [String: Double]] {
        defaults.dictionary(forKey: settingsKey) as? [String: [String: Double]] ?? [:]
    }

    private func save(_ settings: Settings, for id: CGDirectDisplayID) {
        var all = savedSettings()
        all[Self.identity(of: id)] = settings.isNeutral ? nil : ["brightness": settings.brightness, "warmth": settings.warmth]
        defaults.set(all, forKey: settingsKey)
    }

    /// A display's identity across reconnects and relaunches, the one the virtual-display fallback keeps too.
    private static func identity(of id: CGDirectDisplayID) -> String {
        VirtualDisplayEngine.key(for: id)
    }

    // MARK: - Applying

    /// Saves `settings` for display `id` and applies them.
    public func set(_ settings: Settings, for id: CGDirectDisplayID) {
        save(settings, for: id)
        apply(settings, to: id)
    }

    /// Back to 100% and no warmth: full DDC brightness where the display answers, and its ColorSync gamma table.
    public func reset(_ id: CGDirectDisplayID) {
        save(.neutral, for: id)
        if let service = ddcService(for: id) {
            _ = writeBrightness(100, to: service)
        }
        restoreColorSync(id, always: true)
    }

    /// Puts the saved values back on `ids`, after launch or a display change, which can reset gamma tables, and
    /// forgets the displays that went away.
    public func reapply(to ids: [CGDirectDisplayID]) {
        ddcServices = ddcServices.filter { ids.contains($0.key) }
        adjustedGamma.formIntersection(ids)
        for id in ids {
            let saved = settings(for: id)
            if !saved.isNeutral {
                apply(saved, to: id)
            }
        }
    }

    /// Whether display `id` takes brightness over DDC/CI.
    public func supportsHardwareDDC(for id: CGDirectDisplayID) -> Bool {
        ddcService(for: id) != nil
    }

    private func apply(_ settings: Settings, to id: CGDirectDisplayID) {
        if settings.warmth < 0.5, let service = ddcService(for: id) {
            if writeBrightness(Int(settings.brightness.rounded()), to: service) {
                restoreColorSync(id)
                return
            }
            ddcServices[id] = nil // look it up again next time
        }
        if settings.isNeutral {
            restoreColorSync(id)
        } else {
            setGamma(settings, on: id)
        }
    }

    private func setGamma(_ settings: Settings, on id: CGDirectDisplayID) {
        let gain = CGGammaValue(settings.brightness / 100)
        let warm = CGGammaValue(settings.warmth / 100)
        _ = CGSetDisplayTransferByFormula(
            id,
            0, gain, 1,
            0, max(0.05, gain * (1 - warm * 0.28)), 1,
            0, max(0.05, gain * (1 - warm * 0.65)), 1
        )
        adjustedGamma.insert(id)
    }

    /// Puts display `id` back on its ColorSync gamma table. CoreGraphics can only restore every display at once, so
    /// the other displays this process adjusted get their values back right after.
    private func restoreColorSync(_ id: CGDirectDisplayID, always: Bool = false) {
        guard always || adjustedGamma.contains(id) else { return }
        CGDisplayRestoreColorSyncSettings()
        let others = adjustedGamma.subtracting([id])
        adjustedGamma.removeAll()
        for other in others where CGDisplayIsOnline(other) != 0 {
            let saved = settings(for: other)
            if !saved.isNeutral {
                setGamma(saved, on: other)
            }
        }
    }

    // MARK: - DDC/CI

    private func ddcService(for id: CGDirectDisplayID) -> CFTypeRef? {
        let identity = Self.identity(of: id)
        if let known = ddcServices[id], known.identity == identity {
            return known.service
        }
        var service: CFTypeRef?
        if let createAV = createAV, let proxy = Self.avServiceProxy(for: id, location: location(of: id)) {
            if let candidate = createAV(kCFAllocatorDefault, proxy)?.takeRetainedValue(), answersDDC(candidate) {
                service = candidate
            }
            IOObjectRelease(proxy)
        }
        ddcServices[id] = (identity, service)
        return service
    }

    /// The registry path of the framebuffer behind display `id`, from CoreDisplay.
    private func location(of id: CGDirectDisplayID) -> String? {
        guard let info = displayInfo?(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        return info["IODisplayLocation"] as? String
    }

    /// The external DCPAVServiceProxy that drives display `id` (Apple silicon), retained; nil when there is none or
    /// it is unclear which one it is. The registry lists each framebuffer just before the AV service of its display
    /// coprocessor. With the framebuffer's `location` (from CoreDisplay) only that framebuffer's service counts;
    /// without it, the only framebuffer with the display's vendor, product and serial number, or the only external
    /// service while this is the only external display.
    static func avServiceProxy(for id: CGDirectDisplayID, location: String?) -> io_service_t? {
        guard CGDisplayIsBuiltin(id) == 0 else { return nil }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var framebuffer: (path: String, sameProduct: Bool)?
        var proxies: [(service: io_service_t, path: String, sameProduct: Bool)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let name = registryName(of: entry)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                framebuffer = (registryPath(of: entry), isSameProduct(entry, as: id))
            } else if name == "DCPAVServiceProxy" {
                let external = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String == "External"
                if external, let fb = framebuffer {
                    proxies.append((entry, fb.path, fb.sameProduct))
                    framebuffer = nil
                    continue // keeps the reference
                }
                framebuffer = nil
            }
            IOObjectRelease(entry)
        }

        let chosen: io_service_t?
        if let location = location {
            chosen = proxies.first { $0.path == location }?.service
        } else {
            let sameProduct = proxies.filter { $0.sameProduct }
            if sameProduct.count == 1 {
                chosen = sameProduct[0].service
            } else if sameProduct.isEmpty, proxies.count == 1, onlineExternalDisplays() == [id] {
                chosen = proxies[0].service
            } else {
                chosen = nil
            }
        }
        for proxy in proxies where proxy.service != chosen {
            IOObjectRelease(proxy.service)
        }
        return chosen
    }

    /// Whether the framebuffer `entry` shows the same product as display `id`: vendor, product and serial number.
    private static func isSameProduct(_ entry: io_registry_entry_t, as id: CGDirectDisplayID) -> Bool {
        guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let vendor = product["LegacyManufacturerID"] as? Int,
              let model = product["ProductID"] as? Int else {
            return false
        }
        let serial = product["SerialNumber"] as? Int ?? 0
        return vendor == Int(CGDisplayVendorNumber(id)) && model == Int(CGDisplayModelNumber(id))
            && serial == Int(CGDisplaySerialNumber(id))
    }

    private static func onlineExternalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != VirtualDisplayEngine.vendorID
        }
    }

    private static func registryName(of entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return "" }
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func registryPath(of entry: io_registry_entry_t) -> String {
        var path = [CChar](repeating: 0, count: 1024)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return "" }
        return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Asks for VCP 0x10 to see whether the display answers DDC/CI.
    private func answersDDC(_ service: CFTypeRef) -> Bool {
        guard let writeI2C = writeI2C, let readI2C = readI2C else { return false }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10]
        guard writeI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS else { return false }
        usleep(40_000)
        var reply = [UInt8](repeating: 0, count: 12)
        guard readI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == KERN_SUCCESS else { return false }
        let maximum = (Int(reply[6]) << 8) | Int(reply[7])
        return maximum > 0
    }

    /// DDC/CI Set VCP 0x10 (brightness): [0x84, 0x03, 0x10, 0x00, value, checksum].
    private func writeBrightness(_ percent: Int, to service: CFTypeRef) -> Bool {
        guard let writeI2C = writeI2C else { return false }
        let value = UInt8(min(100, max(0, percent)))
        var packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, value, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ value]
        return writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == KERN_SUCCESS
    }
}
