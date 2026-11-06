import AppKit
import IRCore
import SwiftUI

struct ExportSheet: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    let meta: CaptureMeta?
    @State private var base = ""
    @State private var written: [URL] = []
    @State private var error: String?
    @State private var includeImported = false
    @State private var progress: (done: Int, total: Int)?

    private var presets: [ExportPreset] { ExportPreset.all.filter { model.settings.exportPresetIDs.contains($0.id) } }
    private var scope: ExportScope { model.exportScope }
    private var batch: Bool { scope != .selected }
    private var targets: [CaptureMeta] { model.exportTargets(scope, includeImported: includeImported) }
    private var layout: ExportLayout { model.settings.exportLayout ?? .byPlatform }
    private var fileCount: Int { targets.count * presets.count }
    private var busy: Bool { progress != nil }

    private var folder: URL {
        model.settings.exportFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Impulse Responses")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ImpulseGlyph().frame(width: 22, height: 16)
                Text("EXPORT IMPULSE RESPONSE").font(Theme.headingBold(14)).tracking(2)
                Spacer()
                Text(batch ? "\(targets.count) IR\(targets.count == 1 ? "" : "s")" : meta?.name ?? "")
                    .font(Theme.heading(12)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            FieldRow(label: "Export") {
                LampSegmented(options: ExportScope.allCases, selection: Binding(
                    get: { model.exportScope }, set: { model.exportScope = $0; written = [] })) { scopeLabel($0) }
            }
            if batch {
                FieldRow(label: "Folders") {
                    LampSegmented(options: ExportLayout.allCases, selection: Binding(
                        get: { layout }, set: { model.settings.exportLayout = $0 })) { $0.label }
                }
                HStack(spacing: 14) {
                    Text("Files are named after each capture. Captures with the same name get _2, _3…")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    Spacer()
                    if scope == .all && model.captures.contains(where: \.isImported) {
                        LampCheck(text: "Include imported IRs", on: $includeImported).fixedSize()
                    }
                }
            } else {
                FieldRow(label: "File name") { WellField(placeholder: "Cab_Mic_Position", text: $base) }
            }

            HStack(alignment: .top, spacing: 12) {
                platform(ExportPreset.fractal, note: "Axe-Fx III · FM9 · FM3. Import the WAVs with Fractal-Bot or Axe-Edit III, which convert them to the unit's format.")
                platform(ExportPreset.ik, note: "TONEX (pedal and software) and AmpliTube 5 load WAV IRs directly in their cab/IR sections.")
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Processing")
                FieldRow(label: "Normalise") {
                    LampSegmented(options: Normalization.allCases, selection: $model.settings.export.normalization) { $0.label }
                }
                FieldRow(label: "Fade out") {
                    LampSegmented(options: [0.05, 0.1, 0.2], selection: $model.settings.export.fadeFraction) { "\(Int($0 * 100))%" }
                        .frame(width: 180)
                    Spacer()
                }
                FieldRow(label: "High cut") {
                    LampSegmented(options: [0.0, 16000, 12000, 10000, 8000], selection: Binding(
                        get: { model.settings.export.highCut }, set: { model.settings.export.highCutHz = $0 > 0 ? $0 : nil })) {
                        $0 == 0 ? "OFF" : "\(Int($0 / 1000)) kHz"
                    }
                    .frame(width: 330)
                    Spacer()
                }
                LampCheck(text: "Minimum phase", on: $model.settings.export.minimumPhase,
                          detail: "Same tone, with all the energy at the start. Short IRs keep more low end. Mic-distance phase information is lost.")
            }
            .padding(12)
            .gmWell(radius: 6)

            HStack(spacing: 8) {
                FieldRow(label: "Folder") {
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 4).gmWell()
                }
                LatchButton(title: "CHOOSE…", on: false) { chooseFolder() }.frame(width: 80)
            }

            if !presets.isEmpty { preview }
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).tint(Theme.gold)
                    Text("\(progress.done)/\(progress.total)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            if !written.isEmpty {
                HStack {
                    LedDot(on: true)
                    Text("Exported \(written.count) file\(written.count == 1 ? "" : "s").").font(Theme.heading(12)).foregroundStyle(Theme.ok)
                    Button("Show in Finder") {
                        if batch { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        else { NSWorkspace.shared.activateFileViewerSelecting(written) }
                    }
                }
            }

            HStack {
                Spacer()
                LatchButton(title: written.isEmpty ? "CANCEL" : "DONE", on: false, height: 28) { dismiss() }
                    .frame(width: 100)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                BigLampButton(title: "EXPORT \(fileCount) FILE\(fileCount == 1 ? "" : "S")", systemImage: "square.and.arrow.down",
                              enabled: fileCount > 0 && !busy) { export() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 720)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { base = meta?.name ?? "" }
    }

    private func scopeLabel(_ s: ExportScope) -> String {
        switch s {
        case .selected: return "THIS IR"
        case .graph: return "ON GRAPH (\(model.plotted.count))"
        case .all: return "ALL (\(model.exportTargets(.all, includeImported: includeImported).count))"
        }
    }

    /// The file names that will be written: all of them for one IR, the first few for a batch.
    private var preview: some View {
        let lines: [String]
        if batch {
            let paths = ExportRenderer.batchPaths(names: targets.map(\.name), presets: presets, layout: layout).joined()
            lines = Array(paths.prefix(5)) + (paths.count > 5 ? ["… and \(paths.count - 5) more"] : [])
        } else {
            lines = presets.map { model.filename(base: base.isEmpty ? (meta?.name ?? "IR") : base, preset: $0) }
        }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func platform(_ name: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(name)
            ForEach(ExportPreset.all.filter { $0.platform == name }) { p in
                LampCheck(text: "\(p.label)", on: Binding(get: { model.settings.exportPresetIDs.contains(p.id) },
                                                          set: { on in
                                                              if on { model.settings.exportPresetIDs.insert(p.id) }
                                                              else { model.settings.exportPresetIDs.remove(p.id) }
                                                          }),
                          detail: "\(p.sampleRate == 48000 ? "48" : "44.1") kHz · \(p.format.label) · mono · \(p.detail)")
            }
            Text(note).font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .gmWell(radius: 6)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.settings.exportFolder = url.path }
    }

    private func export() {
        error = nil
        written = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            self.error = "Export failed: \(error.localizedDescription)"
            return
        }
        if !batch, let meta {
            do { written = try model.export(meta, base: base.isEmpty ? meta.name : base, presets: presets, to: folder) }
            catch { self.error = "Export failed: \(error.localizedDescription)" }
            return
        }
        progress = (0, fileCount)
        model.exportBatch(targets, presets: presets, layout: layout, to: folder,
                          progress: { progress = ($0, $1) },
                          done: { result in
                              progress = nil
                              switch result {
                              case .success(let urls): written = urls
                              case .failure(let e): error = "Export failed: \(e.localizedDescription)"
                              }
                          })
    }
}
