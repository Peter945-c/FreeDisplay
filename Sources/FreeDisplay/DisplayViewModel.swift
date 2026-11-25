import Foundation
import AppKit
import CoreGraphics
import ServiceManagement
import Combine

@MainActor
public final class DisplayViewModel: ObservableObject {
    @Published public var displays: [DisplayDevice] = []
    @Published public var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID() {
        didSet {
            if selectedDisplayID != oldValue {
                loadColorSettings()
            }
        }
    }
    // Brightness and warmth of the selected display; each display keeps its own (BrightnessController).
    @Published public var brightness: Double = 100.0
    @Published public var warmth: Double = 0.0
    /// Whether the selected display takes brightness over DDC/CI.
    @Published public private(set) var hardwareDDC: Bool = false
    @Published public var launchAtLogin: Bool = false
    @Published public var statusMessage: String? = nil
    @Published public var language: AppLanguage = L10n.current

    // Safety revert state when changing refresh rate
    @Published public var pendingRevertSeconds: Int = 0
    private var revertTimer: Timer?
    private var previousModeForRevert: (displayID: CGDirectDisplayID, modeNumber: Int32, targetModeNumber: Int32)?

    // Virtual-display HiDPI fallback (VirtualDisplayEngine): seconds left before an unconfirmed start is undone
    @Published public var virtualConfirmSeconds: Int = 0
    @Published public var virtualBusy: Bool = false
    private var virtualTimer: Timer?
    private var virtualRestoreTried: Set<String> = []
    private let virtualDisplaysKey = "FreeDisplay.virtualHiDPIDisplays"

    private var screenObserver: NSObjectProtocol?
    private var localeObserver: NSObjectProtocol?

    public init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        language = L10n.current
        refreshDisplays()
        BrightnessController.shared.adoptLegacySettings(for: colorTargetID)
        BrightnessController.shared.reapply(to: colorDisplayIDs)
        loadColorSettings()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshDisplays()
                self.syncVirtualHiDPI()
                BrightnessController.shared.reapply(to: self.colorDisplayIDs)
                self.loadColorSettings()
            }
        }

        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.language = L10n.current
                self.refreshDisplays()
            }
        }

        syncVirtualHiDPI()
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let lobs = localeObserver {
            NotificationCenter.default.removeObserver(lobs)
        }
    }

    public var selectedDisplay: DisplayDevice? {
        displays.first(where: { $0.id == selectedDisplayID }) ?? displays.first
    }

    public func refreshDisplays() {
        language = L10n.current
        var list = SkyLightEngine.shared.queryDisplays()
        if let s = VirtualDisplayEngine.shared.session {
            // While a panel mirrors the virtual HiDPI display, list the two as one: the virtual display, whose modes
            // the controls switch, under the panel's name and size. The mirroring panel itself is hidden.
            list.removeAll { $0.id == s.physicalID }
            list = list.map { d in
                guard d.id == s.virtualID else { return d }
                return DisplayDevice(
                    id: d.id,
                    name: s.physicalName,
                    isBuiltIn: false,
                    diagonalInches: s.diagonalInches,
                    nativeWidth: s.nativeWidth,
                    nativeHeight: s.nativeHeight,
                    nativePPI: s.nativePPI,
                    currentMode: d.currentMode,
                    safeModes: d.safeModes.filter { $0.width <= s.nativeWidth },
                    virtualHiDPI: true
                )
            }
        } else {
            // a virtual display that is going away after a stop
            list.removeAll { CGDisplayVendorNumber($0.id) == VirtualDisplayEngine.vendorID }
        }
        displays = list
        if !list.contains(where: { $0.id == selectedDisplayID }), let first = list.first {
            selectedDisplayID = first.id
        }
    }

    // MARK: - Virtual-display HiDPI fallback

    public var virtualHiDPIAvailable: Bool { VirtualDisplayEngine.shared.isAvailable }

    /// The display brightness and warmth act on for an entry of `displays`: the real panel, also while it mirrors
    /// the virtual HiDPI display.
    private func colorID(for id: CGDirectDisplayID) -> CGDirectDisplayID {
        if let s = VirtualDisplayEngine.shared.session, id == s.virtualID {
            return s.physicalID
        }
        return id
    }

    private var colorTargetID: CGDirectDisplayID { colorID(for: selectedDisplayID) }

    private var colorDisplayIDs: [CGDirectDisplayID] { displays.map { colorID(for: $0.id) } }

    private func loadColorSettings() {
        let saved = BrightnessController.shared.settings(for: colorTargetID)
        brightness = saved.brightness
        warmth = saved.warmth
        hardwareDDC = BrightnessController.shared.supportsHardwareDDC(for: colorTargetID)
    }

    /// Turns the virtual-display fallback on for the selected display. It is undone after 15 seconds unless the user
    /// keeps it, the same safety net as a refresh-rate change.
    public func enableVirtualHiDPI() {
        guard let disp = selectedDisplay, !disp.isBuiltIn, !disp.virtualHiDPI, !virtualBusy else { return }
        virtualBusy = true
        Task { @MainActor in
            let result = await VirtualDisplayEngine.shared.start(for: disp)
            self.virtualBusy = false
            switch result {
            case .success(let virtualID):
                self.selectedDisplayID = virtualID
                self.refreshDisplays()
                self.startVirtualCountdown()
            case .failure(let error):
                self.refreshDisplays()
                self.showFlashMessage(L10n.tr(
                    zh: "虚拟屏开启失败：\(error.message)",
                    en: "Virtual display failed: \(error.message)"
                ))
            }
        }
    }

    /// Keeps the fallback and remembers the panel, so it comes back on the next launch or reconnect.
    public func confirmVirtualHiDPI() {
        guard let s = VirtualDisplayEngine.shared.session else { return }
        cancelVirtualTimer()
        var kept = UserDefaults.standard.stringArray(forKey: virtualDisplaysKey) ?? []
        if !kept.contains(s.physicalKey) {
            kept.append(s.physicalKey)
        }
        UserDefaults.standard.set(kept, forKey: virtualDisplaysKey)
        showFlashMessage(L10n.tr(zh: "已保留虚拟屏 HiDPI，下次启动自动开启", en: "Virtual HiDPI kept; it comes back on next launch"))
    }

    public func disableVirtualHiDPI() {
        stopVirtualHiDPI(message: L10n.tr(zh: "已关闭虚拟屏，回到原生模式", en: "Virtual display off, back to native modes"))
    }

    private func stopVirtualHiDPI(message: String) {
        guard let s = VirtualDisplayEngine.shared.session else { return }
        cancelVirtualTimer()
        // Tearing the virtual display down ends with a permanent configuration commit, which would also keep an
        // unconfirmed refresh-rate change; undo that first.
        if pendingRevertSeconds > 0 {
            revertRefreshRateChange()
        }
        let kept = (UserDefaults.standard.stringArray(forKey: virtualDisplaysKey) ?? []).filter { $0 != s.physicalKey }
        UserDefaults.standard.set(kept, forKey: virtualDisplaysKey)
        VirtualDisplayEngine.shared.stop()
        selectedDisplayID = s.physicalID
        refreshDisplays()
        showFlashMessage(message)
    }

    private func startVirtualCountdown() {
        cancelVirtualTimer()
        virtualConfirmSeconds = 15
        virtualTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.virtualConfirmSeconds > 1 {
                    self.virtualConfirmSeconds -= 1
                } else {
                    self.stopVirtualHiDPI(message: L10n.tr(
                        zh: "未确认，已自动关闭虚拟屏",
                        en: "Not confirmed; virtual display turned off"
                    ))
                }
            }
        }
    }

    private func cancelVirtualTimer() {
        virtualTimer?.invalidate()
        virtualTimer = nil
        virtualConfirmSeconds = 0
    }

    /// Keeps the fallback in step with the hardware. It is torn down when its panel goes away or stops mirroring
    /// (the virtual display would otherwise be an invisible extended desktop), and it comes back, once per
    /// connection, for a panel the user kept it on that is connected and still has no native fractional HiDPI mode.
    private func syncVirtualHiDPI() {
        if let s = VirtualDisplayEngine.shared.session {
            if CGDisplayIsOnline(s.physicalID) == 0 || CGDisplayMirrorsDisplay(s.physicalID) != s.virtualID {
                cancelVirtualTimer()
                if pendingRevertSeconds > 0 {
                    revertRefreshRateChange()
                }
                VirtualDisplayEngine.shared.stop()
                if selectedDisplayID == s.virtualID {
                    selectedDisplayID = s.physicalID
                }
                refreshDisplays()
            }
            return
        }
        guard VirtualDisplayEngine.shared.isAvailable, !virtualBusy else { return }
        VirtualDisplayEngine.shared.sweepLeftovers()
        let kept = UserDefaults.standard.stringArray(forKey: virtualDisplaysKey) ?? []
        let panels = displays.filter { !$0.isBuiltIn && !$0.virtualHiDPI }
        virtualRestoreTried.formIntersection(panels.map { VirtualDisplayEngine.key(for: $0.id) })
        guard let disp = panels.first(where: {
            let key = VirtualDisplayEngine.key(for: $0.id)
            return kept.contains(key) && !virtualRestoreTried.contains(key) && $0.fractionalHiDPIModes.isEmpty
        }) else { return }
        virtualRestoreTried.insert(VirtualDisplayEngine.key(for: disp.id))
        virtualBusy = true
        Task { @MainActor in
            let result = await VirtualDisplayEngine.shared.start(for: disp)
            self.virtualBusy = false
            if case .success(let virtualID) = result, self.selectedDisplayID == disp.id {
                self.selectedDisplayID = virtualID
            }
            self.refreshDisplays()
        }
    }

    public func selectMode(_ mode: DisplayModeItem, requireConfirmIfHzChanges: Bool = true) {
        guard let disp = selectedDisplay else { return }
        let oldMode = disp.currentMode

        if oldMode?.modeNumber == mode.modeNumber {
            return
        }

        let hzChanged = (oldMode != nil && oldMode!.refreshRate != mode.refreshRate)
        if hzChanged && requireConfirmIfHzChanges, let prev = oldMode {
            cancelRevertTimer()
            let ok = SkyLightEngine.shared.applyMode(mode.modeNumber, to: disp.id, permanently: false)
            if ok {
                previousModeForRevert = (disp.id, prev.modeNumber, mode.modeNumber)
                pendingRevertSeconds = 10
                revertTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if self.pendingRevertSeconds > 1 {
                            self.pendingRevertSeconds -= 1
                        } else {
                            self.revertRefreshRateChange()
                        }
                    }
                }
                refreshDisplays()
            } else {
                showFlashMessage(L10n.tr(zh: "切换显示模式失败", en: "Failed to switch display mode"))
            }
        } else {
            cancelRevertTimer()
            let ok = SkyLightEngine.shared.applyMode(mode.modeNumber, to: disp.id, permanently: true)
            if ok {
                refreshDisplays()
                let tag = mode.isHiDPI ? " HiDPI" : ""
                showFlashMessage(L10n.tr(
                    zh: "已切换至 \(mode.width)×\(mode.height)\(tag) @ \(mode.refreshRate)Hz",
                    en: "Switched to \(mode.width)×\(mode.height)\(tag) @ \(mode.refreshRate)Hz"
                ))
            } else {
                showFlashMessage(L10n.tr(zh: "切换显示模式失败", en: "Failed to switch display mode"))
            }
        }
    }

    public func confirmRefreshRateChange() {
        guard let info = previousModeForRevert else { return }
        cancelRevertTimer()
        _ = SkyLightEngine.shared.applyMode(info.targetModeNumber, to: info.displayID, permanently: true)
        previousModeForRevert = nil
        refreshDisplays()
        showFlashMessage(L10n.tr(zh: "已永久保存新刷新率设置", en: "Refresh rate saved permanently"))
    }

    public func revertRefreshRateChange() {
        guard let info = previousModeForRevert else { return }
        cancelRevertTimer()
        _ = SkyLightEngine.shared.applyMode(info.modeNumber, to: info.displayID, permanently: true)
        previousModeForRevert = nil
        refreshDisplays()
        showFlashMessage(L10n.tr(zh: "已自动还原至原先的显示模式", en: "Reverted to previous display mode"))
    }

    private func cancelRevertTimer() {
        revertTimer?.invalidate()
        revertTimer = nil
        pendingRevertSeconds = 0
    }

    public func toggleHiDPI(_ enable: Bool) {
        guard let disp = selectedDisplay, let cur = disp.currentMode else { return }
        if let match = disp.findBestMode(width: cur.width, height: cur.height, hiDPI: enable, preferredHz: cur.refreshRate) {
            selectMode(match, requireConfirmIfHzChanges: false)
        } else if enable {
            if let fallback = disp.sliderModes(hiDPI: true, refreshRate: cur.refreshRate).last {
                selectMode(fallback, requireConfirmIfHzChanges: false)
            }
        }
    }

    public func selectRefreshRate(_ hz: Int) {
        guard let disp = selectedDisplay, let cur = disp.currentMode else { return }
        if let match = disp.findBestMode(width: cur.width, height: cur.height, hiDPI: cur.isHiDPI, preferredHz: hz) {
            selectMode(match, requireConfirmIfHzChanges: true)
        } else if let anyMode = disp.safeModes.first(where: { $0.refreshRate == hz && $0.isHiDPI == cur.isHiDPI }) {
            selectMode(anyMode, requireConfirmIfHzChanges: true)
        }
    }

    public func updateBrightness(_ newVal: Double) {
        brightness = newVal
        BrightnessController.shared.set(.init(brightness: brightness, warmth: warmth), for: colorTargetID)
    }

    public func updateWarmth(_ newVal: Double) {
        warmth = newVal
        BrightnessController.shared.set(.init(brightness: brightness, warmth: warmth), for: colorTargetID)
    }

    public func resetColorAdjustments() {
        brightness = 100.0
        warmth = 0.0
        BrightnessController.shared.reset(colorTargetID)
        showFlashMessage(L10n.tr(zh: "已恢复默认亮度与色彩", en: "Brightness & color reset to default"))
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showFlashMessage(launchAtLogin
                ? L10n.tr(zh: "已开启开机自动启动", en: "Launch at login enabled")
                : L10n.tr(zh: "已关闭开机自动启动", en: "Launch at login disabled")
            )
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            showFlashMessage(L10n.tr(
                zh: "登录项设置提示：请在系统设置 → 登录项中允许",
                en: "Please allow in System Settings → Login Items"
            ))
        }
    }

    public func openSystemDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showFlashMessage(_ msg: String) {
        statusMessage = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.statusMessage == msg {
                self.statusMessage = nil
            }
        }
    }
}
