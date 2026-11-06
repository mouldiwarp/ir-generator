import IRCore
import SwiftUI

/// Mic Swap: removes the capture mic's response (e.g. an SM57) from an IR, leaving the speaker, and optionally
/// applies another mic's response in its place.
struct MicSwapSheet: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    let meta: CaptureMeta
    @State private var name = ""
    @State private var saved: String?

    private var t: Binding<ToolSettings> { $model.tools }
    private var source: MicCurve { model.mic(model.tools.micSourceID) ?? MicLibrary.builtIn[0] }
    private var target: MicCurve? { model.mic(model.tools.micTargetID) }

    private static let distances: [Double] = [0.006, 0.025, 0.05, 0.15, 0.3]
    private static func distanceLabel(_ d: Double) -> String {
        d < 0.01 ? "\(Int((d * 1000).rounded())) MM" : String(format: d * 100 == (d * 100).rounded() ? "%.0f CM" : "%.1f CM", d * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ImpulseGlyph().frame(width: 22, height: 16)
                Text("MIC SWAP").font(Theme.headingBold(14)).tracking(2)
                Spacer()
                Text(meta.name).font(Theme.heading(12)).foregroundStyle(Theme.dim).lineLimit(1)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel("Captured with")
                    WellMenu(options: model.micCurves.map(\.id), selection: t.micSourceID) { id in micLabel(model.mic(id)) }
                    patternEditor(source)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .topLeading).gmWell(radius: 6)

                Image(systemName: "arrow.right").foregroundStyle(Theme.gold).padding(.top, 34)

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel("Replace with")
                    WellMenu(options: [String?.none] + model.micCurves.map { Optional($0.id) }, selection: t.micTargetID) { id in
                        id == nil ? "None · speaker only" : micLabel(model.mic(id))
                    }
                    if let target { patternEditor(target) } else {
                        Text("Removes the mic's response and proximity bass, leaving an estimate of the speaker alone.")
                            .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .topLeading).gmWell(radius: 6)
            }

            HStack(spacing: 16) {
                FieldRow(label: "Distance") {
                    LampSegmented(options: Self.distances, selection: t.mic.distance) { Self.distanceLabel($0) }.frame(width: 300)
                }
                FieldRow(label: "Max boost") {
                    LampSegmented(options: [6.0, 12, 18], selection: t.mic.maxBoostDB) { "+\(Int($0)) DB" }.frame(width: 190)
                }
            }
            .help("Mic distance from the grille, for the proximity effect (bass lift) of directional mics")

            let original = model.audio(meta.id)?.ir ?? []
            let result = original.isEmpty ? [] : MicSwap.apply(original, sampleRate: meta.sampleRate, source: source, target: target,
                                                               options: model.tools.mic)
            VStack(spacing: 4) {
                FrequencyPlot(series: [
                    .init(id: UUID(), curve: IRCore.Analysis.response(result, sampleRate: meta.sampleRate, smoothing: 6, points: 500),
                          color: Theme.gold, name: "Result"),
                    .init(id: UUID(), curve: IRCore.Analysis.response(original, sampleRate: meta.sampleRate, smoothing: 6, points: 500),
                          color: Theme.haze, name: "Original"),
                ])
                .frame(height: 250)
                FrequencyPlot(series: [
                    .init(id: UUID(), curve: MicSwap.correctionCurve(source: source, target: target, options: model.tools.mic),
                          color: Theme.amber, name: "Correction", normalize: false, dashed: true),
                ], dbStep: 6, dbTop: 18, dbBottom: -18, autoRange: false)
                .frame(height: 120)
            }
            .padding(6)
            .gmWell(radius: 6)
            HStack(spacing: 14) {
                legend(Theme.haze, "Original")
                legend(Theme.gold, "Result")
                legend(Theme.amber, "Correction filter (lower graph)")
                Spacer()
            }

            Text("The built-in curves are smoothed approximations of the published on-axis responses. Individual mics and off-axis placement vary, so for accuracy import a measured or official curve (\"frequency dB\" text, REW, .frd or .csv). Removal can't undo comb filtering or room reflections in the capture.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)

            FieldRow(label: "Save as") { WellField(placeholder: "Name", text: $name) }
            if let saved { HStack { LedDot(on: true); Text(saved).font(Theme.heading(12)).foregroundStyle(Theme.ok) } }
            HStack {
                LatchButton(title: "IMPORT CURVE…", on: false, height: 28) { model.importMicCurve() }.frame(width: 130)
                Spacer()
                LatchButton(title: "CLOSE", on: false, height: 28) { dismiss() }.frame(width: 90).keyboardShortcut(.cancelAction)
                BigLampButton(title: "SAVE AS NEW IR", systemImage: "square.and.arrow.down.on.square", enabled: !result.isEmpty) {
                    save(result)
                }
            }
        }
        .padding(18)
        .frame(width: 820)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { name = defaultName }
        .onChange(of: model.tools.micTargetID) { _, _ in name = defaultName }
        .onChange(of: model.tools.micSourceID) { _, _ in name = defaultName }
    }

    private var defaultName: String {
        "\(meta.name) · " + (target.map { "as \($0.name)" } ?? "speaker only")
    }

    private func micLabel(_ c: MicCurve?) -> String {
        guard let c else { return "—" }
        return "\(c.name) · \(c.kind.lowercased()), \(c.pattern.label.lowercased())"
    }

    /// Imported curves need their polar pattern set; built-in ones show theirs.
    @ViewBuilder private func patternEditor(_ c: MicCurve) -> some View {
        if c.builtIn {
            Text("\(c.kind) · \(c.pattern.label)").font(Theme.caption(9.5)).tracking(0.8).foregroundStyle(Theme.dim)
        } else {
            HStack(spacing: 6) {
                WellMenu(options: MicPattern.allCases, selection: Binding(get: { c.pattern }, set: { p in
                    var u = c; u.pattern = p; model.updateMicCurve(u)
                })) { $0.label }
                .frame(width: 150)
                LatchButton(title: "REMOVE CURVE", on: false, tint: Theme.danger) { model.deleteMicCurve(c.id) }.frame(width: 110)
            }
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(c).frame(width: 16, height: 3)
            Text(s).font(Theme.heading(11)).foregroundStyle(Theme.text.opacity(0.9))
        }
    }

    private func save(_ ir: [Double]) {
        let o = model.tools.mic
        let note = String(format: "Mic swap: %@ → %@, %@, max boost +%.0f dB", source.name, target?.name ?? "speaker only",
                          Self.distanceLabel(o.distance).lowercased(), o.maxBoostDB)
        let m = model.addDerived(from: meta, name: name.isEmpty ? defaultName : name, note: note, ir: ir, select: false)
        saved = "Saved “\(m.name)” to the library."
    }
}
