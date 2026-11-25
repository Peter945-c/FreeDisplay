import SwiftUI
import AppKit

public struct MenuBarPopoverView: View {
    @ObservedObject var vm: DisplayViewModel
    @ObservedObject var updater: Updater
    @State private var showAllModes: Bool = false

    @MainActor
    public init(vm: DisplayViewModel) {
        self.init(vm: vm, updater: Updater.shared)
    }

    init(vm: DisplayViewModel, updater: Updater) {
        self.vm = vm
        self.updater = updater
    }

    public var body: some View {
        let _ = vm.language
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            updateCard

            if vm.pendingRevertSeconds > 0 {
                safetyRevertBanner
            }

            if vm.virtualConfirmSeconds > 0 {
                virtualConfirmBanner
            }

            if let disp = vm.selectedDisplay {
                currentStatusCard(disp)
                if disp.virtualHiDPI {
                    virtualActiveCard
                } else if disp.fractionalHiDPIModes.isEmpty {
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
    // (1280 × 720 on a 2560 × 1440 panel), so no HiDPI preset exists. Say why, and offer the virtual-display fallback.
    private func integerScalingNotice(_ disp: DisplayDevice) -> some View {
        let detail: String
        if let m = disp.largestHiDPIMode {
            detail = L10n.tr(
                zh: "macOS 只为它提供了 \(m.width) × \(m.height) HiDPI（画布 \(m.pixelsWide) × \(m.pixelsHigh)），没有 125%、133%、160% 这类介于中间的 HiDPI 模式。",
                en: "macOS offers only \(m.width) × \(m.height) HiDPI for it (canvas \(m.pixelsWide) × \(m.pixelsHigh)), with nothing in between such as 125%, 133% or 160%."
            )
        } else {
            detail = L10n.tr(zh: "macOS 没有为它提供任何 HiDPI 模式。", en: "macOS offers no HiDPI mode for it.")
        }
        let canOffer = vm.virtualHiDPIAvailable && !disp.isBuiltIn
        let size = VirtualDisplayEngine.logicalSizes(nativeWidth: disp.nativeWidth, nativeHeight: disp.nativeHeight)[1]
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(zh: "这台显示器只能整数倍缩放", en: "Integer scaling only on this display"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canOffer {
                Text(L10n.tr(
                    zh: "可以改用虚拟屏：FreeDisplay 新建一块带 HiDPI 模式的虚拟屏，让这台显示器镜像它，就能用上 \(size.0) × \(size.1) 等档位。代价是不支持 HDR、GPU 占用略高，且需要 FreeDisplay 保持运行；开启后 15 秒内不确认会自动还原。",
                    en: "Workaround: FreeDisplay can create a virtual display with HiDPI modes and have this display mirror it, giving you sizes such as \(size.0) × \(size.1). It costs HDR and a little GPU time, and FreeDisplay has to keep running; unless you confirm within 15 seconds, it switches back."
                ))
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.tr(zh: "开启虚拟屏 HiDPI（实验性）", en: "Turn On Virtual HiDPI (Experimental)")) {
                        vm.enableVirtualHiDPI()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.virtualBusy)
                    if vm.virtualBusy {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Text(L10n.tr(
                    zh: "FreeDisplay 只能在系统已有的模式之间切换，这台 Mac 也不支持虚拟屏方案。",
                    en: "FreeDisplay can only switch among the modes macOS provides, and this Mac doesn't support the virtual display workaround."
                ))
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(8)
    }

    // MARK: - Virtual HiDPI Fallback
    private var virtualActiveCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(zh: "虚拟屏 HiDPI 已开启", en: "Virtual HiDPI is on"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(L10n.tr(
                zh: "这台显示器正在镜像 FreeDisplay 新建的虚拟屏，下面的档位都来自虚拟屏。不支持 HDR；退出 FreeDisplay 后自动恢复原生模式。",
                en: "This display mirrors a virtual display FreeDisplay created; the sizes below come from it. No HDR; quitting FreeDisplay puts the native modes back."
            ))
            .font(.system(size: 10.5))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(L10n.tr(zh: "关闭虚拟屏", en: "Turn Off Virtual Display")) {
                vm.disableVirtualHiDPI()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .cornerRadius(8)
    }

    private var virtualConfirmBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr(
                zh: "虚拟屏 HiDPI 已开启，画面正常吗？（\(vm.virtualConfirmSeconds) 秒后自动关闭）",
                en: "Virtual HiDPI is on. Does it look right? (Turning off in \(vm.virtualConfirmSeconds)s)"
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.orange)

            HStack(spacing: 8) {
                Button(L10n.tr(zh: "保留", en: "Keep")) {
                    vm.confirmVirtualHiDPI()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(L10n.tr(zh: "立即关闭", en: "Turn Off Now")) {
                    vm.disableVirtualHiDPI()
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

    // MARK: - Updates
    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    @ViewBuilder
    private var updateCard: some View {
        switch updater.state {
        case .available(let release):
            updateCardBox(tint: .accentColor) {
                Text(L10n.tr(zh: "发现新版本 v\(release.version)", en: "FreeDisplay \(release.version) is available"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(updater.canInstallInPlace
                     ? L10n.tr(
                        zh: "当前 v\(updater.currentVersion)。更新会下载 \(Self.bytes(release.dmgSize))，校验 SHA-256 和开发者签名后替换应用并自动重启。",
                        en: "You have \(updater.currentVersion). Updating downloads \(Self.bytes(release.dmgSize)), checks its SHA-256 and developer signature, replaces the app and reopens it.")
                     : L10n.tr(
                        zh: "当前 v\(updater.currentVersion)。这个副本无法自行替换（开发版、只读位置或没有写权限），请从下载页更新。",
                        en: "You have \(updater.currentVersion). This copy can't replace itself (a development build, a read-only location or no write access); update from the download page."))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(updater.canInstallInPlace
                           ? L10n.tr(zh: "更新并重启", en: "Update and Reopen")
                           : L10n.tr(zh: "前往下载页", en: "Open Download Page")) {
                        updater.install(release)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(L10n.tr(zh: "更新说明", en: "Release Notes")) {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        case .downloading(let release, let received, let total, let speed):
            updateCardBox(tint: .accentColor) {
                HStack {
                    Text(L10n.tr(zh: "正在下载 v\(release.version)", en: "Downloading \(release.version)"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Spacer()
                    Button(L10n.tr(zh: "取消", en: "Cancel")) {
                        updater.cancelDownload()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                ProgressView(value: Double(min(received, total)), total: Double(max(total, 1)))
                HStack {
                    Text("\(Self.bytes(received)) / \(Self.bytes(total))")
                    Spacer()
                    if speed > 1 {
                        let left = Int((Double(max(total - received, 0)) / speed).rounded(.up))
                        Text(L10n.tr(
                            zh: "\(Self.bytes(Int64(speed)))/s · 剩余 \(left) 秒",
                            en: "\(Self.bytes(Int64(speed)))/s · \(left) s left"
                        ))
                    } else {
                        Text(L10n.tr(zh: "正在连接…", en: "Connecting…"))
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
            }
        case .installing(let release):
            updateCardBox(tint: .accentColor) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr(
                        zh: "正在校验并安装 v\(release.version)，FreeDisplay 将自动重启…",
                        en: "Verifying and installing \(release.version); FreeDisplay will reopen…"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let message, let release):
            updateCardBox(tint: .orange) {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let release = release {
                        Button(L10n.tr(zh: "前往下载页", en: "Open Download Page")) {
                            NSWorkspace.shared.open(release.pageURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button(L10n.tr(zh: "关闭", en: "Dismiss")) {
                        updater.dismissFailure()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        default:
            if let from = updater.justUpdatedFrom {
                updateCardBox(tint: .green) {
                    Text(L10n.tr(
                        zh: "已更新到 v\(updater.currentVersion)（原 v\(from)）",
                        en: "Updated to \(updater.currentVersion) (was \(from))"
                    ))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                }
            }
        }
    }

    private func updateCardBox<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10))
            .cornerRadius(8)
    }

    private var updateRow: some View {
        HStack(spacing: 8) {
            Text("v\(updater.currentVersion)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
            Toggle(L10n.tr(zh: "自动检查更新", en: "Check Automatically"), isOn: $updater.autoCheck)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            switch updater.state {
            case .checking:
                ProgressView().controlSize(.mini)
                Text(L10n.tr(zh: "正在检查…", en: "Checking…"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .upToDate:
                Text(L10n.tr(zh: "已是最新版本", en: "Up to date"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            default:
                Button(L10n.tr(zh: "检查更新", en: "Check for Updates")) {
                    Task { await updater.check(userInitiated: true) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
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

            if updater.isEnabled {
                updateRow
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
