import Foundation
import AppKit
import CoreGraphics
import ServiceManagement
import Combine

@MainActor
public final class DisplayViewModel: ObservableObject {
    @Published public var displays: [DisplayDevice] = []
    @Published public var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published public var brightness: Double = 100.0
    @Published public var warmth: Double = 0.0
    @Published public var launchAtLogin: Bool = false
    @Published public var statusMessage: String? = nil
    @Published public var language: AppLanguage = L10n.current

    // Safety revert state when changing refresh rate
    @Published public var pendingRevertSeconds: Int = 0
    private var revertTimer: Timer?
    private var previousModeForRevert: (displayID: CGDirectDisplayID, modeNumber: Int32, targetModeNumber: Int32)?

    private var screenObserver: NSObjectProtocol?
    private var localeObserver: NSObjectProtocol?

    public init() {
        brightness = BrightnessController.shared.savedBrightness()
        warmth = BrightnessController.shared.savedWarmth()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        language = L10n.current
        refreshDisplays()

        if brightness < 99.5 || warmth > 0.5 {
            BrightnessController.shared.setColorTable(
                displayID: selectedDisplayID,
                brightnessPercent: brightness,
                warmthPercent: warmth,
                persist: false
            )
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshDisplays()
                if self.brightness < 99.5 || self.warmth > 0.5 {
                    BrightnessController.shared.setColorTable(
                        displayID: self.selectedDisplayID,
                        brightnessPercent: self.brightness,
                        warmthPercent: self.warmth,
                        persist: false
                    )
                }
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
        let list = SkyLightEngine.shared.queryDisplays()
        displays = list
        if !list.contains(where: { $0.id == selectedDisplayID }), let first = list.first {
            selectedDisplayID = first.id
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
        BrightnessController.shared.setColorTable(
            displayID: selectedDisplayID,
            brightnessPercent: brightness,
            warmthPercent: warmth
        )
    }

    public func updateWarmth(_ newVal: Double) {
        warmth = newVal
        BrightnessController.shared.setColorTable(
            displayID: selectedDisplayID,
            brightnessPercent: brightness,
            warmthPercent: warmth
        )
    }

    public func resetColorAdjustments() {
        brightness = 100.0
        warmth = 0.0
        BrightnessController.shared.resetColorTable(displayID: selectedDisplayID)
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
