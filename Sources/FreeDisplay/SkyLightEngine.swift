import Foundation
import AppKit
import CoreGraphics

public struct DisplayModeItem: Identifiable, Equatable, Hashable {
    public let modeNumber: Int32
    public let width: Int
    public let height: Int
    public let pixelsWide: Int
    public let pixelsHigh: Int
    public let scale: Float
    public let refreshRate: Int
    public let depth: Int
    public let flags: UInt32
    public let ioFlags: UInt32

    public var id: Int32 { modeNumber }
    public var isHiDPI: Bool { scale > 1.5 || pixelsWide > width }
    public var isSafe: Bool { (ioFlags & 0x00000002) != 0 && (flags & 0x00000001) != 0 }
    public var isNativePanel: Bool { (ioFlags & 0x02000000) != 0 && !isHiDPI }
    public var isDefault: Bool { (flags & 0x00000004) != 0 }
    public var bitsPerChannel: Int { depth >= 8 ? 10 : 8 }
    public var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 0.0 }
    public var resolutionText: String { "\(width) × \(height)" }
    public var framebufferText: String { "\(pixelsWide) × \(pixelsHigh)" }
}

public struct DisplayPreset: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let badge: String?
    public let mode: DisplayModeItem
}

public struct DisplayDevice: Identifiable, Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let diagonalInches: Double
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let nativePPI: Int
    public let currentMode: DisplayModeItem?
    public let safeModes: [DisplayModeItem]
    /// The virtual HiDPI display a real panel mirrors (VirtualDisplayEngine), listed under the panel's name and size.
    public var virtualHiDPI: Bool = false

    public var nativeAspectRatio: Double {
        nativeHeight > 0 ? Double(nativeWidth) / Double(nativeHeight) : (16.0 / 9.0)
    }

    public func scalePercent(for logicalWidth: Int) -> Int {
        guard logicalWidth > 0, nativeWidth > 0 else { return 100 }
        return Int((Double(nativeWidth) / Double(logicalWidth) * 100.0).rounded())
    }

    /// HiDPI modes between the integer 2× mode and native (2048, 1920 and 1600 wide on a 2560 panel): the only way to
    /// get larger text that stays sharp. macOS decides whether a display gets any; when it offers only the 2× mode
    /// (1280 × 720 on a 2560 × 1440 panel), scaling is integer-only and FreeDisplay has nothing to switch to.
    public var fractionalHiDPIModes: [DisplayModeItem] {
        safeModes.filter {
            $0.isHiDPI && abs($0.aspectRatio - nativeAspectRatio) < 0.04
                && $0.width * 2 > nativeWidth + 8 && $0.width < nativeWidth - 8
        }
    }

    /// The HiDPI mode with the largest canvas macOS offers for this display, if any.
    public var largestHiDPIMode: DisplayModeItem? {
        safeModes.filter { $0.isHiDPI }.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
    }

    public var allRefreshRates: [Int] {
        Array(Set(safeModes.map { $0.refreshRate })).filter { $0 > 0 }.sorted(by: >)
    }

    public var maxRefreshRate: Int {
        allRefreshRates.first ?? (currentMode?.refreshRate ?? 60)
    }

    public func findBestMode(width: Int, height: Int, hiDPI: Bool, preferredHz: Int? = nil) -> DisplayModeItem? {
        let targetHz = preferredHz ?? currentMode?.refreshRate ?? maxRefreshRate
        let candidates = safeModes.filter {
            $0.width == width && $0.height == height && $0.isHiDPI == hiDPI
        }
        if let exact = candidates.first(where: { $0.refreshRate == targetHz }) {
            return exact
        }
        return candidates.sorted { $0.refreshRate > $1.refreshRate }.first
    }

    public func sliderModes(hiDPI: Bool, refreshRate: Int) -> [DisplayModeItem] {
        let ratio = nativeAspectRatio
        var byRes: [String: DisplayModeItem] = [:]
        for m in safeModes where m.isHiDPI == hiDPI && m.width >= 1024 && m.width <= nativeWidth {
            if abs(m.aspectRatio - ratio) < 0.04 {
                let key = "\(m.width)x\(m.height)"
                if let existing = byRes[key] {
                    // Prefer matching refreshRate, otherwise highest refreshRate
                    let curMatch = (existing.refreshRate == refreshRate)
                    let newMatch = (m.refreshRate == refreshRate)
                    if newMatch && !curMatch {
                        byRes[key] = m
                    } else if curMatch == newMatch && m.refreshRate > existing.refreshRate {
                        byRes[key] = m
                    }
                } else {
                    byRes[key] = m
                }
            }
        }
        // Sort from largest UI (smallest width) to smallest UI (largest width, 100%)
        return byRes.values.sorted { $0.width < $1.width }
    }

    public var recommendedPresets: [DisplayPreset] {
        let hz = currentMode?.refreshRate ?? maxRefreshRate
        var list: [DisplayPreset] = []

        // 1. ~125% Sweet Spot (e.g. 2048x1152 HiDPI on 2560x1440, or 3008x1692 on 4K)
        let target125W = Int((Double(nativeWidth) / 1.25).rounded())
        if let m125 = safeModes
            .filter({ $0.isHiDPI && abs($0.aspectRatio - nativeAspectRatio) < 0.04 && abs($0.width - target125W) <= 80 })
            .sorted(by: { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) })
            .first {
            let pct = scalePercent(for: m125.width)
            list.append(DisplayPreset(
                id: "125_hidpi",
                title: "\(m125.width) × \(m125.height)",
                subtitle: L10n.tr(zh: "HiDPI 高清 · 等效 \(pct)% 放大", en: "HiDPI Crisp · \(pct)% Scale"),
                badge: L10n.tr(zh: "黄金推荐", en: "Best"),
                mode: m125
            ))
        }

        // 2. ~133%-150% Larger Comfortable Text (e.g. 1920x1080 HiDPI on 2560x1440)
        let target133W = Int((Double(nativeWidth) / (4.0 / 3.0)).rounded())
        if let m133 = safeModes
            .filter({ $0.isHiDPI && abs($0.aspectRatio - nativeAspectRatio) < 0.04 && abs($0.width - target133W) <= 80 && $0.width != list.first?.mode.width })
            .sorted(by: { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) })
            .first {
            let pct = scalePercent(for: m133.width)
            list.append(DisplayPreset(
                id: "133_hidpi",
                title: "\(m133.width) × \(m133.height)",
                subtitle: L10n.tr(zh: "HiDPI 高清 · 等效 \(pct)% 大字", en: "HiDPI Crisp · \(pct)% Larger"),
                badge: L10n.tr(zh: "舒适护眼", en: "Comfort"),
                mode: m133
            ))
        }

        // 3. ~160% Extra Large (e.g. 1600x900 HiDPI)
        let target160W = Int((Double(nativeWidth) / 1.6).rounded())
        if let m160 = safeModes
            .filter({ $0.isHiDPI && abs($0.aspectRatio - nativeAspectRatio) < 0.04 && abs($0.width - target160W) <= 80 })
            .sorted(by: { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) })
            .first {
            let pct = scalePercent(for: m160.width)
            list.append(DisplayPreset(
                id: "160_hidpi",
                title: "\(m160.width) × \(m160.height)",
                subtitle: L10n.tr(zh: "HiDPI 高清 · 等效 \(pct)% 超大", en: "HiDPI Crisp · \(pct)% XL"),
                badge: nil,
                mode: m160
            ))
        }

        // 4. 100% Native Pixel-for-Pixel (e.g. 2560x1440 LoDPI)
        if let mNative = findBestMode(width: nativeWidth, height: nativeHeight, hiDPI: false, preferredHz: hz) {
            list.append(DisplayPreset(
                id: "100_native",
                title: "\(mNative.width) × \(mNative.height)",
                subtitle: L10n.tr(zh: "原生点对点 · 100% 最大视野", en: "Native 1:1 · 100% Max Space"),
                badge: L10n.tr(zh: "原生面板", en: "Native"),
                mode: mNative
            ))
        }

        return list
    }
}

public final class SkyLightEngine {
    public static let shared = SkyLightEngine()

    private typealias GetCurrentModeFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    private typealias GetModeCountFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    private typealias GetModeDescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError
    private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    private let getCurrentMode: GetCurrentModeFn?
    private let getModeCount: GetModeCountFn?
    private let getModeDesc: GetModeDescFn?
    private let configureMode: ConfigureModeFn?

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) {
            if let sym = dlsym(handle, "CGSGetCurrentDisplayMode") {
                getCurrentMode = unsafeBitCast(sym, to: GetCurrentModeFn.self)
            } else { getCurrentMode = nil }

            if let sym = dlsym(handle, "CGSGetNumberOfDisplayModes") {
                getModeCount = unsafeBitCast(sym, to: GetModeCountFn.self)
            } else { getModeCount = nil }

            if let sym = dlsym(handle, "CGSGetDisplayModeDescriptionOfLength") {
                getModeDesc = unsafeBitCast(sym, to: GetModeDescFn.self)
            } else { getModeDesc = nil }

            if let sym = dlsym(handle, "CGSConfigureDisplayMode") {
                configureMode = unsafeBitCast(sym, to: ConfigureModeFn.self)
            } else { configureMode = nil }
        } else {
            getCurrentMode = nil
            getModeCount = nil
            getModeDesc = nil
            configureMode = nil
        }
    }

    public func queryDisplays() -> [DisplayDevice] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displayIDs, &displayCount) == .success else {
            return []
        }

        var screenNames: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screenNames[num] = screen.localizedName
            }
        }

        var results: [DisplayDevice] = []
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            let allModes = fetchAllModes(for: id)
            let curModeNum = fetchCurrentModeNumber(for: id)
            let currentMode = allModes.first(where: { $0.modeNumber == curModeNum })

            // Deduplicate safe modes by (width, height, isHiDPI, refreshRate), preferring highest color depth & lower mode index
            var bestMap: [String: DisplayModeItem] = [:]
            for m in allModes where m.isSafe && m.refreshRate > 0 {
                let key = "\(m.width)x\(m.height)_\(m.isHiDPI ? 2 : 1)_\(m.refreshRate)"
                if let existing = bestMap[key] {
                    if m.depth > existing.depth || (m.depth == existing.depth && m.isDefault && !existing.isDefault) {
                        bestMap[key] = m
                    }
                } else {
                    bestMap[key] = m
                }
            }

            let safeModes = bestMap.values.sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI && !$1.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }

            // Detect native panel resolution
            let nativeCandidate = allModes.filter { $0.isNativePanel }.max(by: { $0.width < $1.width })
                ?? safeModes.filter { !$0.isHiDPI }.max(by: { $0.width < $1.width })
            let nativeW = nativeCandidate?.width ?? currentMode?.width ?? 2560
            let nativeH = nativeCandidate?.height ?? currentMode?.height ?? 1440

            // Calculate physical size & PPI
            let mm = CGDisplayScreenSize(id)
            let diagInches: Double
            let ppi: Int
            if mm.width > 10 && mm.height > 10 {
                let diagMM = hypot(mm.width, mm.height)
                diagInches = (diagMM / 25.4 * 10.0).rounded() / 10.0
                let diagPx = hypot(Double(nativeW), Double(nativeH))
                ppi = Int((diagPx / (diagMM / 25.4)).rounded())
            } else {
                diagInches = 24.0
                ppi = 110
            }

            let fallbackName = CGDisplayIsBuiltin(id) != 0
                ? L10n.tr(zh: "内置显示器", en: "Built-in Display")
                : L10n.tr(zh: "外接显示器 #\(id)", en: "External Display #\(id)")
            let name = screenNames[id] ?? fallbackName
            results.append(DisplayDevice(
                id: id,
                name: name,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                diagonalInches: diagInches,
                nativeWidth: nativeW,
                nativeHeight: nativeH,
                nativePPI: ppi,
                currentMode: currentMode,
                safeModes: safeModes
            ))
        }
        return results
    }

    public func fetchCurrentModeNumber(for displayID: CGDirectDisplayID) -> Int32 {
        guard let getCurrentMode = getCurrentMode else { return -1 }
        var modeNum: Int32 = -1
        _ = getCurrentMode(displayID, &modeNum)
        return modeNum
    }

    public func fetchAllModes(for displayID: CGDirectDisplayID) -> [DisplayModeItem] {
        guard let getModeCount = getModeCount, let getModeDesc = getModeDesc else {
            return []
        }
        var count: Int32 = 0
        guard getModeCount(displayID, &count) == .success, count > 0 else {
            return []
        }

        let recordLen = 0xD4
        var buf = [UInt8](repeating: 0, count: recordLen)
        var modes: [DisplayModeItem] = []
        modes.reserveCapacity(Int(count))

        for idx in 0..<count {
            for b in 0..<recordLen { buf[b] = 0 }
            guard getModeDesc(displayID, idx, &buf, Int32(recordLen)) == .success else {
                continue
            }
            let modeNumber = buf.withUnsafeBytes { Int32($0.load(fromByteOffset: 0, as: UInt32.self)) }
            let flags = buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let width = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 8, as: UInt32.self)) }
            let height = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 12, as: UInt32.self)) }
            let depth = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 16, as: UInt32.self)) }
            let refreshRate = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 36, as: UInt32.self)) }
            let ioFlags = buf.withUnsafeBytes { $0.load(fromByteOffset: 0xC0, as: UInt32.self) }
            let pixelsWide = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 0xC8, as: UInt32.self)) }
            let pixelsHigh = buf.withUnsafeBytes { Int($0.load(fromByteOffset: 0xCC, as: UInt32.self)) }
            let scale = buf.withUnsafeBytes { $0.load(fromByteOffset: 0xD0, as: Float.self) }

            modes.append(DisplayModeItem(
                modeNumber: modeNumber,
                width: width,
                height: height,
                pixelsWide: pixelsWide > 0 ? pixelsWide : width,
                pixelsHigh: pixelsHigh > 0 ? pixelsHigh : height,
                scale: scale > 0 ? scale : 1.0,
                refreshRate: refreshRate,
                depth: depth,
                flags: flags,
                ioFlags: ioFlags
            ))
        }
        return modes
    }

    @discardableResult
    public func applyMode(_ modeNumber: Int32, to displayID: CGDirectDisplayID, permanently: Bool = true) -> Bool {
        guard let configureMode = configureMode else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        let err = configureMode(config, displayID, modeNumber)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let option: CGConfigureOption = permanently ? .permanently : .forSession
        return CGCompleteDisplayConfiguration(config, option) == .success
    }
}
