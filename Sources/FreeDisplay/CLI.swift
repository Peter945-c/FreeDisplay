import Foundation
import CoreGraphics

public enum CLIRunner {
    public static func run(args: [String]) -> Int32 {
        guard let cmd = args.first?.lowercased() else {
            printHelp()
            return 0
        }

        switch cmd {
        case "status", "info":
            return cmdStatus()
        case "list", "modes":
            return cmdList(args: Array(args.dropFirst()))
        case "set":
            return cmdSet(args: Array(args.dropFirst()))
        case "preset":
            return cmdPreset(args: Array(args.dropFirst()))
        case "brightness":
            return cmdBrightness(args: Array(args.dropFirst()))
        case "reset":
            BrightnessController.shared.resetColorTable(displayID: CGMainDisplayID())
            print(L10n.tr(
                zh: "已重置屏幕亮度与色彩为 100% 原生状态。",
                en: "Reset screen brightness and color table to 100% native default."
            ))
            return 0
        case "help", "-h", "--help":
            printHelp()
            return 0
        default:
            fputs(L10n.tr(zh: "未知命令: \(cmd)\n\n", en: "Unknown command: \(cmd)\n\n"), stderr)
            printHelp()
            return 1
        }
    }

    private static func cmdStatus() -> Int32 {
        let displays = SkyLightEngine.shared.queryDisplays()
        if displays.isEmpty {
            print(L10n.tr(zh: "未检测到显示器。", en: "No active display detected."))
            return 1
        }
        for d in displays {
            let cur = d.currentMode
            let pct = cur != nil ? d.scalePercent(for: cur!.width) : 100
            if L10n.isChinese {
                print("显示器: \(d.name) (ID: \(d.id))")
                print(String(format: "  物理规格: %.1f 英寸 · 原生面板 %d × %d (%d PPI)", d.diagonalInches, d.nativeWidth, d.nativeHeight, d.nativePPI))
                if let c = cur {
                    print("  当前逻辑分辨率: \(c.width) × \(c.height) (等效 \(pct)% 缩放)")
                    print("  高清渲染模式:   \(c.isHiDPI ? "HiDPI 2× (画布 \(c.pixelsWide) × \(c.pixelsHigh))" : "1× 原生点对点")")
                    print("  刷新率与色深:   \(c.refreshRate)Hz · \(c.bitsPerChannel)-bit (Mode #\(c.modeNumber))")
                }
            } else {
                print("Display: \(d.name) (ID: \(d.id))")
                print(String(format: "  Physical Specs: %.1f\" · Native Panel %d × %d (%d PPI)", d.diagonalInches, d.nativeWidth, d.nativeHeight, d.nativePPI))
                if let c = cur {
                    print("  Logical UI Res: \(c.width) × \(c.height) (\(pct)% UI Scale)")
                    print("  Rendering Mode: \(c.isHiDPI ? "HiDPI 2× (Canvas \(c.pixelsWide) × \(c.pixelsHigh))" : "1× Native Pixel-for-Pixel")")
                    print("  Refresh & BPC:  \(c.refreshRate)Hz · \(c.bitsPerChannel)-bit (Mode #\(c.modeNumber))")
                }
            }
        }
        return 0
    }

    private static func cmdList(args: [String]) -> Int32 {
        let displays = SkyLightEngine.shared.queryDisplays()
        guard let d = displays.first else {
            fputs(L10n.tr(zh: "未检测到显示器。\n", en: "No active display detected.\n"), stderr)
            return 1
        }
        let onlyHiDPI = args.contains("--hidpi")
        print(L10n.tr(zh: "\(d.name) 可用安全显示模式:", en: "Safe display modes for \(d.name):"))
        for m in d.safeModes {
            if onlyHiDPI && !m.isHiDPI { continue }
            let mark = (d.currentMode?.modeNumber == m.modeNumber) ? "*" : " "
            let tag = m.isHiDPI ? "HiDPI 2x" : "LoDPI 1x"
            let pct = d.scalePercent(for: m.width)
            let canvasWord = L10n.tr(zh: "画布", en: "Canvas")
            let scaleWord = L10n.tr(zh: "等效", en: "Scale")
            print(String(format: "%@ [%3d] %-11s  %-8s  %@ %-11s  %3dHz  %2dbit  (%@ %d%%)",
                         mark,
                         m.modeNumber,
                         ("\(m.width)x\(m.height)" as NSString).utf8String!,
                         (tag as NSString).utf8String!,
                         canvasWord,
                         ("\(m.pixelsWide)x\(m.pixelsHigh)" as NSString).utf8String!,
                         m.refreshRate,
                         m.bitsPerChannel,
                         scaleWord,
                         pct))
        }
        return 0
    }

    private static func cmdSet(args: [String]) -> Int32 {
        guard let resArg = args.first else {
            fputs(L10n.tr(
                zh: "用法: freedisplay set <宽x高> [--hidpi | --lodpi] [--hz <刷新率>]\n例如: freedisplay set 2048x1152 --hidpi --hz 144\n",
                en: "Usage: freedisplay set <WxH> [--hidpi | --lodpi] [--hz <rate>]\nExample: freedisplay set 2048x1152 --hidpi --hz 144\n"
            ), stderr)
            return 1
        }
        let parts = resArg.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
            fputs(L10n.tr(
                zh: "分辨率格式错误: \(resArg)，请使用如 2048x1152 的格式。\n",
                en: "Invalid resolution format: \(resArg). Expected format like 2048x1152.\n"
            ), stderr)
            return 1
        }

        let displays = SkyLightEngine.shared.queryDisplays()
        guard let d = displays.first else {
            fputs(L10n.tr(zh: "未检测到显示器。\n", en: "No active display detected.\n"), stderr)
            return 1
        }

        var wantHiDPI = true
        if args.contains("--lodpi") {
            wantHiDPI = false
        } else if args.contains("--hidpi") {
            wantHiDPI = true
        } else if w == d.nativeWidth && h == d.nativeHeight {
            wantHiDPI = false
        }

        var targetHz: Int? = nil
        if let hzIdx = args.firstIndex(of: "--hz"), hzIdx + 1 < args.count {
            targetHz = Int(args[hzIdx + 1].replacingOccurrences(of: "Hz", with: "", options: .caseInsensitive))
        }

        guard let mode = d.findBestMode(width: w, height: h, hiDPI: wantHiDPI, preferredHz: targetHz) else {
            fputs(L10n.tr(
                zh: "未找到匹配的显示模式: \(w)x\(h) \(wantHiDPI ? "HiDPI" : "LoDPI")\n可运行 `freedisplay list` 查看全部支持的分辨率。\n",
                en: "No matching safe mode found for \(w)x\(h) \(wantHiDPI ? "HiDPI" : "LoDPI").\nRun `freedisplay list` to view available modes.\n"
            ), stderr)
            return 1
        }

        if SkyLightEngine.shared.applyMode(mode.modeNumber, to: d.id, permanently: true) {
            let pct = d.scalePercent(for: mode.width)
            print(L10n.tr(
                zh: "成功切换至: \(mode.width) × \(mode.height) \(mode.isHiDPI ? "HiDPI" : "LoDPI") @ \(mode.refreshRate)Hz (画布 \(mode.pixelsWide)×\(mode.pixelsHigh), 等效 \(pct)%)",
                en: "Switched to: \(mode.width) × \(mode.height) \(mode.isHiDPI ? "HiDPI" : "LoDPI") @ \(mode.refreshRate)Hz (Canvas \(mode.pixelsWide)×\(mode.pixelsHigh), \(pct)% Scale)"
            ))
            return 0
        } else {
            fputs(L10n.tr(zh: "应用显示模式失败。\n", en: "Failed to apply display mode.\n"), stderr)
            return 1
        }
    }

    private static func cmdPreset(args: [String]) -> Int32 {
        guard let name = args.first else {
            fputs(L10n.tr(
                zh: "用法: freedisplay preset <125 | 133 | 160 | 100>\n",
                en: "Usage: freedisplay preset <125 | 133 | 160 | 100>\n"
            ), stderr)
            return 1
        }
        let displays = SkyLightEngine.shared.queryDisplays()
        guard let d = displays.first else { return 1 }

        let targetId: String
        switch name {
        case "125": targetId = "125_hidpi"
        case "133": targetId = "133_hidpi"
        case "160": targetId = "160_hidpi"
        case "100": targetId = "100_native"
        default:
            fputs(L10n.tr(
                zh: "未知预设: \(name)，可选值: 125, 133, 160, 100\n",
                en: "Unknown preset: \(name). Valid options: 125, 133, 160, 100\n"
            ), stderr)
            return 1
        }

        guard let preset = d.recommendedPresets.first(where: { $0.id == targetId }) else {
            fputs(L10n.tr(
                zh: "当前显示器无此预设档位。\n",
                en: "Preset not available on current display.\n"
            ), stderr)
            return 1
        }

        if SkyLightEngine.shared.applyMode(preset.mode.modeNumber, to: d.id, permanently: true) {
            print(L10n.tr(
                zh: "已应用预设 [\(preset.title)] \(preset.subtitle) @ \(preset.mode.refreshRate)Hz",
                en: "Applied preset [\(preset.title)] \(preset.subtitle) @ \(preset.mode.refreshRate)Hz"
            ))
            return 0
        }
        return 1
    }

    private static func cmdBrightness(args: [String]) -> Int32 {
        guard let valStr = args.first, let val = Double(valStr.replacingOccurrences(of: "%", with: "")) else {
            fputs(L10n.tr(
                zh: "用法: freedisplay brightness <20-100>\n",
                en: "Usage: freedisplay brightness <20-100>\n"
            ), stderr)
            return 1
        }
        let clamped = min(100.0, max(20.0, val))
        let warmth = BrightnessController.shared.savedWarmth()
        BrightnessController.shared.setColorTable(
            displayID: CGMainDisplayID(),
            brightnessPercent: clamped,
            warmthPercent: warmth,
            persist: true
        )
        print(L10n.tr(
            zh: "已将屏幕亮度设为 \(Int(clamped.rounded()))%",
            en: "Set screen brightness to \(Int(clamped.rounded()))%"
        ))
        return 0
    }

    private static func printHelp() {
        if L10n.isChinese {
            print("""
            FreeDisplay — 免费开源的 macOS 外接显示器 HiDPI 高清缩放与亮度工具

            用法:
              freedisplay                         启动图形控制面板与菜单栏应用
              freedisplay status                  查看当前显示器规格、HiDPI 画布与刷新率状态
              freedisplay list [--hidpi]          列出当前显示器支持的所有安全分辨率模式
              freedisplay preset <125|133|160|100> 一键切换黄金预设档位（如 125% 为 2048x1152 HiDPI）
              freedisplay set <宽x高> [--hidpi|--lodpi] [--hz <刷新率>]
                                                  切换到指定分辨率，例如:
                                                  freedisplay set 2048x1152 --hidpi --hz 144
                                                  freedisplay set 1920x1080 --hidpi --hz 144
              freedisplay brightness <20-100>     调节屏幕亮度百分比
              freedisplay reset                   重置屏幕亮度与护眼色温至 100% 原生状态

            语言说明:
              默认自动跟随 macOS 系统首选语言（中文 / English），也可附加 --lang zh 或 --lang en 预览指定语言。
            """)
        } else {
            print("""
            FreeDisplay — 100% Free & Open-Source macOS External Display HiDPI & Brightness Utility

            Usage:
              freedisplay                         Launch GUI control panel & menu bar utility
              freedisplay status                  Show active display specs, HiDPI canvas & refresh rate
              freedisplay list [--hidpi]          List all safe display modes for the monitor
              freedisplay preset <125|133|160|100> Apply quick HiDPI scale preset (e.g. 125% -> 2048x1152 HiDPI)
              freedisplay set <WxH> [--hidpi|--lodpi] [--hz <rate>]
                                                  Switch to a specific resolution, e.g.:
                                                  freedisplay set 2048x1152 --hidpi --hz 144
                                                  freedisplay set 1920x1080 --hidpi --hz 144
              freedisplay brightness <20-100>     Set display brightness percentage
              freedisplay reset                   Reset brightness & eye-care warmth to 100% default

            Language:
              Automatically follows macOS system preferred language (Chinese / English).
              Pass --lang en or --lang zh to preview a specific language.
            """)
        }
    }
}
