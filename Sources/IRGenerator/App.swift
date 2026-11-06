import AppKit
import SwiftUI

@main
struct IRGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = CaptureModel(demo: AppDelegate.demoMode)

    var body: some Scene {
        Window("IR Generator", id: "main") {
            MainView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import WAV IRs…") { model.importFiles() }.keyboardShortcut("i")
            }
            CommandMenu("Capture") {
                Button("Capture") { model.capture() }.keyboardShortcut("r")
                Button(model.state == .levelCheck ? "Stop Level Check" : "Level Check") { model.toggleLevelCheck() }
                    .keyboardShortcut("l")
                Button("Stop") { model.stop() }.keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button("Calibrate Latency (Loopback)") { model.calibrateLatency() }
                Divider()
                Button("Export…") { model.showExport = true }.keyboardShortcut("e").disabled(model.selected == nil)
            }
            CommandMenu("Tools") {
                Button("Align & Blend…") { model.showAlign = true }.keyboardShortcut("b").disabled(model.plotted.count < 2)
                Button("Mic Swap…") { model.showMicSwap = true }.keyboardShortcut("m").disabled(model.selected == nil)
                Button("Import Mic Curve…") { model.importMicCurve() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CaptureModel?

    /// `--demo` fills the library with simulated captures; `--snapshot <dir>` does too, renders every graph tab
    /// to PNG files and quits.
    static let snapshotDir: URL? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1])
    }()
    static let demoMode = CommandLine.arguments.contains("--demo") || snapshotDir != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--engine-test") { engineTest(); return }
        guard let dir = Self.snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.snapshot(GraphTab.allCases, dir: dir) }
    }

    private func snapshot(_ tabs: [GraphTab], dir: URL) {
        guard let tab = tabs.first else { snapshotSheets(dir: dir); return }
        MainActor.assumeIsolated { model?.setTab(tab) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let view = NSApp.windows.first(where: { $0.title == "IR Generator" })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(tab.rawValue).png"))
            }
            self.snapshot(Array(tabs.dropFirst()), dir: dir)
        }
    }

    /// Diagnostics: runs the duplex engine on the AXE I/O for 1.5 s at zero output gain (silent),
    /// prints what it saw and quits.
    private let testEngine = CaptureEngine()
    private func engineTest() {
        guard let dev = AudioDevices.duplex().first(where: \.isAxeIO) ?? AudioDevices.duplex().first else {
            print("engine-test: no duplex device"); exit(1)
        }
        let rate = AudioDevices.rate(dev.id)
        print("engine-test: \(dev.name) in \(dev.inputChannels) out \(dev.outputChannels) @ \(rate) Hz")
        let frames = Int(rate)
        do {
            try testEngine.start(device: dev, signal: [Double](repeating: 0, count: frames), loop: false,
                                 outChannels: [4, 5].filter { $0 < dev.outputChannels }, inChannel: 0,
                                 recordFrames: frames, gain: 0)
        } catch { print("engine-test: start failed: \(error.localizedDescription)"); exit(1) }
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            let s = self.testEngine.status()
            guard s.done || Date().timeIntervalSince(t0) > 4 else { return }
            t.invalidate()
            let rec = self.testEngine.stop() ?? []
            let peak = rec.reduce(0) { max($0, abs($1)) }
            print(String(format: "engine-test: done=%@ recorded=%d/%d in %.2f s, input-1 peak %.1f dBFS",
                         s.done ? "yes" : "NO", s.recorded, frames, Date().timeIntervalSince(t0), 20 * log10(max(peak, 1e-10))))
            exit(s.done ? 0 : 1)
        }
    }

    /// Opens Mic Swap, Align & Blend, Export and the checklist in turn, and writes each sheet to PNG.
    private func snapshotSheets(dir: URL) {
        let steps: [(String, @MainActor (CaptureModel) -> Void, @MainActor (CaptureModel) -> Void)] = [
            ("micswap", { $0.showMicSwap = true }, { $0.showMicSwap = false }),
            ("align", { $0.showAlign = true }, { $0.showAlign = false }),
            ("export", { $0.showExport = true }, { $0.showExport = false }),
            ("checklist", { $0.showChecklist = true }, { $0.showChecklist = false }),
        ]
        func run(_ i: Int) {
            guard i < steps.count, let model else { exit(0) }
            MainActor.assumeIsolated { steps[i].1(model) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let view = NSApp.windows.first(where: { $0.sheetParent != nil })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(steps[i].0).png"))
                }
                MainActor.assumeIsolated { steps[i].2(model) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run(i + 1) }
            }
        }
        run(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}
