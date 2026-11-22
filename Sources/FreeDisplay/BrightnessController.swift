import Foundation
import CoreGraphics
import IOKit

public final class BrightnessController {
    public static let shared = BrightnessController()

    private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias IOAVServiceWriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias IOAVServiceReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let createAV: IOAVServiceCreateFn?
    private let writeI2C: IOAVServiceWriteI2CFn?
    private let readI2C: IOAVServiceReadI2CFn?

    private let defaults = UserDefaults.standard
    private let brightnessKey = "FreeDisplay.softwareBrightness"
    private let warmthKey = "FreeDisplay.softwareWarmth"

    public private(set) var supportsHardwareDDC: Bool = false

    private init() {
        if let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) {
            if let s1 = dlsym(handle, "IOAVServiceCreate") {
                createAV = unsafeBitCast(s1, to: IOAVServiceCreateFn.self)
            } else { createAV = nil }

            if let s2 = dlsym(handle, "IOAVServiceWriteI2C") {
                writeI2C = unsafeBitCast(s2, to: IOAVServiceWriteI2CFn.self)
            } else { writeI2C = nil }

            if let s3 = dlsym(handle, "IOAVServiceReadI2C") {
                readI2C = unsafeBitCast(s3, to: IOAVServiceReadI2CFn.self)
            } else { readI2C = nil }
        } else {
            createAV = nil
            writeI2C = nil
            readI2C = nil
        }
        supportsHardwareDDC = probeHardwareDDC() != nil
    }

    public func savedBrightness() -> Double {
        if defaults.object(forKey: brightnessKey) == nil { return 100.0 }
        return min(100.0, max(20.0, defaults.double(forKey: brightnessKey)))
    }

    public func savedWarmth() -> Double {
        if defaults.object(forKey: warmthKey) == nil { return 0.0 }
        return min(50.0, max(0.0, defaults.double(forKey: warmthKey)))
    }

    public func probeHardwareDDC() -> Int? {
        guard let createAV = createAV, let writeI2C = writeI2C, let readI2C = readI2C,
              let av = createAV(kCFAllocatorDefault) else {
            return nil
        }
        var send: [UInt8] = [0x82, 0x01, 0x10, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10]
        guard writeI2C(av, 0x37, 0x51, &send, UInt32(send.count)) == KERN_SUCCESS else {
            return nil
        }
        usleep(40_000)
        var recv = [UInt8](repeating: 0, count: 12)
        guard readI2C(av, 0x37, 0x51, &recv, UInt32(recv.count)) == KERN_SUCCESS else {
            return nil
        }
        let maxVal = (Int(recv[6]) << 8) | Int(recv[7])
        let curVal = (Int(recv[8]) << 8) | Int(recv[9])
        guard maxVal > 0 else { return nil }
        return Int((Double(curVal) / Double(maxVal) * 100.0).rounded())
    }

    @discardableResult
    public func setHardwareDDCBrightness(_ percent: Int) -> Bool {
        guard let createAV = createAV, let writeI2C = writeI2C,
              let av = createAV(kCFAllocatorDefault) else {
            return false
        }
        let clamped = UInt8(min(100, max(0, percent)))
        // DDC/CI Set VCP 0x10 (Brightness): [0x84, 0x03, 0x10, 0x00, value, checksum]
        let chk: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ clamped
        var packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, clamped, chk]
        return writeI2C(av, 0x37, 0x51, &packet, UInt32(packet.count)) == KERN_SUCCESS
    }

    public func setColorTable(displayID: CGDirectDisplayID, brightnessPercent: Double, warmthPercent: Double, persist: Bool = true) {
        let b = min(100.0, max(20.0, brightnessPercent))
        let w = min(50.0, max(0.0, warmthPercent))
        if persist {
            defaults.set(b, forKey: brightnessKey)
            defaults.set(w, forKey: warmthKey)
        }

        if supportsHardwareDDC && w < 0.5 {
            if setHardwareDDCBrightness(Int(b.rounded())) {
                CGDisplayRestoreColorSyncSettings()
                return
            }
        }

        if b >= 99.5 && w <= 0.5 {
            CGDisplayRestoreColorSyncSettings()
            return
        }

        let gain = CGGammaValue(b / 100.0)
        let warmFactor = CGGammaValue(w / 100.0)
        let rMax = gain
        let gMax = gain * (1.0 - warmFactor * 0.28)
        let bMax = gain * (1.0 - warmFactor * 0.65)

        _ = CGSetDisplayTransferByFormula(
            displayID,
            0.0, rMax, 1.0,
            0.0, max(0.05, gMax), 1.0,
            0.0, max(0.05, bMax), 1.0
        )
    }

    public func resetColorTable(displayID: CGDirectDisplayID) {
        defaults.set(100.0, forKey: brightnessKey)
        defaults.set(0.0, forKey: warmthKey)
        if supportsHardwareDDC {
            _ = setHardwareDDCBrightness(100)
        }
        CGDisplayRestoreColorSyncSettings()
    }
}
