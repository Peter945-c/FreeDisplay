import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject var vm: DisplayViewModel
    @State private var showAllModes: Bool = false

    public init(vm: DisplayViewModel) {
        self.vm = vm
    }

    public var body: some View {
        let _ = vm.language
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if vm.pendingRevertSeconds > 0 {
                safetyRevertBanner
            }

            if let disp = vm.selectedDisplay {
                currentStatusCard(disp)
                if disp.fractionalHiDPIModes.isEmpty {
                    integerScalingNotice(disp)
                }
                presetsSection(disp)
                sliderAndModeControls(disp)
                brightnessSection
                allModesDisclosure(disp)
            } else {
                Text(L10n.tr(zh: "未检测到活动显示器", en: "No active display detected"))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 12)
            }

            Divider()
            footerSection
        }
        .padding(14)
        .frame(width: 356)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)

            if vm.displays.count > 1 {
                Picker("", selection: $vm.selectedDisplayID) {
                    ForEach(vm.displays) { d in
                        Text("\(d.name) (\(String(format: "%.1f\"", d.diagonalInches)))").tag(d.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            } else if let d = vm.selectedDisplay {
                Text("\(d.name)")
                    .font(.system(size: 14, weight: .bold))
                Text(String(format: "%.1f\" · %d PPI", d.diagonalInches, d.nativePPI))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("FreeDisplay")
                    .font(.system(size: 14, weight: .bold))
            }

            Spacer()

            Text(L10n.tr(zh: "永久免费开源", en: "100% Free & OSS"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.14))
                .cornerRadius(4)
        }
    }

    // MARK: - Safety Auto-Revert Banner
    private var safetyRevertBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(
                zh: "刷新率已变更，当前画面正常吗？（\(vm.pendingRevertSeconds) 秒后自动还原）",
                en: "Refresh rate changed. Keep this setting? (Reverting in \(vm.pendingRevertSeconds)s)"
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.orange)

            HStack(spacing: 8) {
                Button(L10n.tr(zh: "确认保留", en: "Keep Changes")) {
                    vm.confirmRefreshRateChange()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(L10n.tr(zh: "立即还原", en: "Revert Now")) {
                    vm.revertRefreshRateChange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Current Mode Status Card
    private func currentStatusCard(_ disp: DisplayDevice) -> some View {
        let cur = disp.currentMode
        let scalePct = cur != nil ? disp.scalePercent(for: cur!.width) : 100
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(cur?.resolutionText ?? "\(disp.nativeWidth) × \(disp.nativeHeight)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    if cur?.isHiDPI == true {
                        Text("HiDPI 2×")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor)
                            .cornerRadius(4)
                    } else {
                        Text(L10n.tr(zh: "1× 原生", en: "1× Native"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text("\(cur?.refreshRate ?? 60)Hz")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.85))
                }

                if let c = cur {
                    Text(L10n.tr(
                        zh: "等效 \(scalePct)% 缩放 · 渲染画布 \(c.framebufferText) · \(c.bitsPerChannel)-bit",
                        en: "\(scalePct)% UI Scale · Canvas \(c.framebufferText) · \(c.bitsPerChannel)-bit"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Integer-only HiDPI Notice
    // macOS decides which HiDPI modes a display gets. On some Mac and display pairs it offers only the 2× mode
    // (1280 × 720 on a 2560 × 1440 panel), so no HiDPI preset exists; say why instead of leaving the panel looking broken.
    private func integerScalingNotice(_ disp: DisplayDevice) -> some View {
        let detail: String
        if let m = disp.largestHiDPIMode {
            detail = L10n.tr(
                zh: "macOS 只为它提供了 \(m.width) × \(m.height) HiDPI（画布 \(m.pixelsWide) × \(m.pixelsHigh)），没有 125%、133%、160% 这类介于中间的 HiDPI 模式。FreeDisplay 只在系统已有的模式之间切换，不改 EDID、不建虚拟显示器，因此无法在这里开启。",
                en: "macOS offers only \(m.width) × \(m.height) HiDPI for it (canvas \(m.pixelsWide) × \(m.pixelsHigh)), with nothing in between such as 125%, 133% or 160%. FreeDisplay only switches among the modes macOS provides, with no EDID changes or virtual displays, so it can't turn them on here."
            )
        } else {
            detail = L10n.tr(
                zh: "macOS 没有为它提供任何 HiDPI 模式。FreeDisplay 只在系统已有的模式之间切换，不改 EDID、不建虚拟显示器，因此无法在这里开启。",
                en: "macOS offers no HiDPI mode for it. FreeDisplay only switches among the modes macOS provides, with no EDID changes or virtual displays, so it can't turn HiDPI on here."
            )
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(zh: "这台显示器只能整数倍缩放", en: "Integer scaling only on this display"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(8)
    }

    // MARK: - Recommended Presets
    private func presetsSection(_ disp: DisplayDevice) -> some View {
        let presets = disp.recommendedPresets
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(zh: "一键常用档位", en: "Quick Scaling Presets"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(presets) { preset in
                    let isSelected = (disp.currentMode?.width == preset.mode.width &&
                                      disp.currentMode?.height == preset.mode.height &&
                                      disp.currentMode?.isHiDPI == preset.mode.isHiDPI)
                    Button {
                        vm.selectMode(preset.mode, requireConfirmIfHzChanges: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(preset.title)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(isSelected ? .white : .primary)
                                Spacer(minLength: 2)
                                if let badge = preset.badge {
                                    Text(badge)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(isSelected ? Color.white : Color.accentColor.opacity(0.14))
                                        .cornerRadius(3)
                                }
                            }
                            Text(preset.subtitle)
                                .font(.system(size: 10))
                                .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                                .lineLimit(1)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Resolution Slider + HiDPI Toggle + Refresh Rate
    private func sliderAndModeControls(_ disp: DisplayDevice) -> some View {
        let cur = disp.currentMode
        let isHiDPI = cur?.isHiDPI ?? true
        let curHz = cur?.refreshRate ?? disp.maxRefreshRate
        let steps = disp.sliderModes(hiDPI: isHiDPI, refreshRate: curHz)
        let currentIdx = steps.firstIndex(where: { $0.width == cur?.width && $0.height == cur?.height }) ?? max(0, steps.count - 1)

        return VStack(alignment: .leading, spacing: 8) {
            if steps.count > 1 {
                HStack {
                    Text(L10n.tr(zh: "界面缩放滑块", en: "UI Scale Slider"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(L10n.tr(zh: "字体更大 ← → 空间更多", en: "Larger Text ← → More Space"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(currentIdx) },
                        set: { newVal in
                            let idx = min(steps.count - 1, max(0, Int(newVal.rounded())))
                            if idx < steps.count {
                                vm.selectMode(steps[idx], requireConfirmIfHzChanges: false)
                            }
                        }
                    ),
                    in: 0...Double(max(1, steps.count - 1)),
                    step: 1
                )
            }

            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { cur?.isHiDPI ?? false },
                    set: { vm.toggleHiDPI($0) }
                )) {
                    Text(L10n.tr(zh: "HiDPI 高清渲染", en: "HiDPI Retina Mode"))
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                HStack(spacing: 4) {
                    Text(L10n.tr(zh: "刷新率", en: "Refresh"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { curHz },
                        set: { vm.selectRefreshRate($0) }
                    )) {
                        ForEach(disp.allRefreshRates, id: \.self) { hz in
                            Text("\(hz) Hz").tag(hz)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 86)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Brightness & Warmth
    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(BrightnessController.shared.supportsHardwareDDC
                     ? L10n.tr(zh: "屏幕亮度（硬件 DDC）", en: "Brightness (Hardware DDC)")
                     : L10n.tr(zh: "屏幕亮度与护眼调节", en: "Brightness & Eye Care"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if vm.brightness < 99.5 || vm.warmth > 0.5 {
                    Button(L10n.tr(zh: "重置 100%", en: "Reset 100%")) {
                        vm.resetColorAdjustments()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.link)
                } else {
                    Text("\(Int(vm.brightness.rounded()))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { vm.brightness },
                        set: { vm.updateBrightness($0) }
                    ),
                    in: 20...100
                )
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "moon")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { vm.warmth },
                        set: { vm.updateWarmth($0) }
                    ),
                    in: 0...50
                )
                Text(L10n.tr(
                    zh: "护眼暖色 \(Int(vm.warmth.rounded()))%",
                    en: "Warmth \(Int(vm.warmth.rounded()))%"
                ))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
            }
        }
    }

    // MARK: - Full Mode List Disclosure
    private func allModesDisclosure(_ disp: DisplayDevice) -> some View {
        let curHz = disp.currentMode?.refreshRate ?? disp.maxRefreshRate
        let filteredModes = disp.safeModes.filter { $0.refreshRate == curHz && $0.width >= 1024 }

        return DisclosureGroup(isExpanded: $showAllModes) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(filteredModes) { m in
                        let active = (disp.currentMode?.modeNumber == m.modeNumber)
                        Button {
                            vm.selectMode(m, requireConfirmIfHzChanges: false)
                        } label: {
                            HStack {
                                Text("\(m.width) × \(m.height)")
                                    .font(.system(size: 11.5, weight: active ? .bold : .regular, design: .monospaced))
                                if m.isHiDPI {
                                    Text("HiDPI")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                } else {
                                    Text("1×")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(L10n.tr(
                                    zh: "画布 \(m.pixelsWide)×\(m.pixelsHigh) · \(m.refreshRate)Hz",
                                    en: "Canvas \(m.pixelsWide)×\(m.pixelsHigh) · \(m.refreshRate)Hz"
                                ))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 140)
        } label: {
            Text(L10n.tr(
                zh: "全部可用分辨率（当前 \(curHz)Hz 共 \(filteredModes.count) 项）",
                en: "All Safe Resolutions (\(filteredModes.count) modes @ \(curHz)Hz)"
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Footer
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = vm.statusMessage {
                Text(msg)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }

            HStack {
                Toggle(L10n.tr(zh: "开机自启", en: "Launch at Login"), isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { vm.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                Spacer()

                Button(L10n.tr(zh: "系统显示器设置…", en: "Display Settings…")) {
                    vm.openSystemDisplaySettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))

                Button(L10n.tr(zh: "退出", en: "Quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }
}
