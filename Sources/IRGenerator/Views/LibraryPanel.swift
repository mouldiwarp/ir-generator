import AppKit
import IRCore
import SwiftUI

struct LibraryPanel: View {
    @EnvironmentObject var model: CaptureModel
    @State private var confirmDelete: CaptureMeta?

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("Captures")
                    Button { model.showAlign = true } label: {
                        Label("ALIGN", systemImage: "align.horizontal.left").font(Theme.caption(9.5)).tracking(0.8)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(LampFace(on: false))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.plotted.count < 2)
                    .opacity(model.plotted.count < 2 ? 0.45 : 1)
                    .help(model.plotted.count < 2 ? "Show another IR with its eye button to align and blend it with the selected one"
                                                  : "Phase-align and blend the IRs on the graph (⌘B)")
                    Button { model.importFiles() } label: {
                        Label("IMPORT", systemImage: "plus").font(Theme.caption(9.5)).tracking(0.8)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(LampFace(on: false))
                    }
                    .buttonStyle(.plain)
                    .help("Import WAV IRs to view and compare (⌘I)")
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.captures) { m in row(m) }
                    }
                }
                .frame(maxHeight: .infinity)
                if model.captures.isEmpty {
                    Text("Captured IRs are kept here between sessions.").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
            }
            .padding(12)
            .gmCard()

            if let m = model.selected { DetailCard(meta: m).padding(12).gmCard() }
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                           set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let m = confirmDelete { model.delete(m.id) }; confirmDelete = nil }
        } message: {
            Text("This removes the capture and its recording from the library. Exported files are not affected.")
        }
    }

    private func row(_ m: CaptureMeta) -> some View {
        let selected = m.id == model.selectedID
        let color = model.plotted.first { $0.meta.id == m.id }?.color
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(color ?? Theme.track).frame(width: 3, height: 26)
                .shadow(color: (color ?? .clear).opacity(0.8), radius: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(Theme.heading(12)).foregroundStyle(selected ? Theme.offwhite : Theme.text.opacity(0.85)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(m.isImported ? "IMPORTED" : m.isDerived ? "PROCESSED" : m.date.formatted(date: .abbreviated, time: .shortened).uppercased())
                        .font(Theme.caption(8.5)).tracking(0.6).foregroundStyle(Theme.dim)
                    if let p = m.peakToNoiseDB {
                        Text(String(format: "%.0f dB", p)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(p < 45 ? Theme.warn : Theme.amber.opacity(0.85))
                    }
                    if m.clipped { Text("CLIP").font(Theme.caption(8.5)).foregroundStyle(Theme.danger) }
                }
            }
            Spacer(minLength: 0)
            if !selected {
                Button { model.toggleCompare(m.id) } label: {
                    Image(systemName: model.compareIDs.contains(m.id) ? "eye.fill" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(model.compareIDs.contains(m.id) ? Theme.gold : Theme.dim)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("Overlay on the graphs")
                .accessibilityLabel(model.compareIDs.contains(m.id) ? "Hide from comparison" : "Compare")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Theme.gold.opacity(0.12) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.gold.opacity(0.55) : .clear, lineWidth: 0.75))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = m.id }
        .contextMenu {
            Button("Export…") { model.selectedID = m.id; model.showExport = true }
            Button("Save Master WAV…") { model.saveMaster(m) }
            if m.hasRecording {
                Button("Reprocess from Recording") { model.reprocess(m) }
                Button("Save Raw Recording…") { model.saveRecording(m) }
            }
            if let src = m.importedFrom {
                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: src)]) }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = m }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DetailCard: View {
    @EnvironmentObject var model: CaptureModel
    let meta: CaptureMeta

    private func bind(_ kp: WritableKeyPath<CaptureMeta, String>) -> Binding<String> {
        Binding(get: { model.selected?[keyPath: kp] ?? "" },
                set: { v in guard var m = model.selected else { return }; m[keyPath: kp] = v; model.update(m) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Selected IR")
            WellField(placeholder: "Name (cab · mic · position)", text: bind(\.name))
            WellField(placeholder: "Notes", text: bind(\.notes))
            VStack(alignment: .leading, spacing: 3) {
                if let s = meta.settings {
                    info("Signal", "\(s.method.label.capitalized) · \(Int(s.f1)) Hz–\(Int(s.f2 / 1000)) kHz · ×\(s.averages)")
                }
                if let d = meta.derivedFrom { info("Made by", d) }
                if let r = meta.route { info("Route", r) }
                if let l = meta.levelDB { info("Level", String(format: "%.1f dBFS", l)) }
                info("Rate", String(format: "%.1f kHz", meta.sampleRate / 1000))
            }
            HStack(spacing: 6) {
                LatchButton(title: "MIC SWAP…", on: false, height: 24) { model.showMicSwap = true }
                    .help("Remove the capture mic's response, or swap it for another mic's (⌘M)")
                LatchButton(title: "SAVE MASTER", on: false, height: 24) { model.saveMaster(meta) }
            }
            LatchButton(title: "EXPORT…", on: true, height: 24) { model.showExport = true }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k.uppercased()).font(Theme.caption(8.5)).tracking(0.8).foregroundStyle(Theme.dim).frame(width: 44, alignment: .leading)
            Text(v).font(.system(size: 10.5)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(2)
        }
    }
}
