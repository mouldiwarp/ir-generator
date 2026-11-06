import AppKit
import SwiftUI

// Controls in the Mixdeck / Axeio Silicon style: lamp-like latch buttons, recessed wells, LED meters.

/// Small latching button that lights like a lamp when on.
struct LatchButton: View {
    let title: String
    let on: Bool
    var tint: Color = Theme.accent
    var height: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(10.5))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 4)
                .foregroundStyle(on ? Theme.obsidian : Theme.text.opacity(0.8))
                .background(LampFace(on: on, tint: tint))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Button face: dark recessed face with a tinted rim, or a lit, glowing face when on.
struct LampFace: View {
    let on: Bool
    var tint: Color = Theme.accent
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [.white.opacity(on ? 0.35 : 0.04), .clear], startPoint: .top, endPoint: .center)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(on ? 0.9 : 0.28), lineWidth: 0.75))
            .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 5)
    }
}

/// A row of latch buttons acting as a segmented picker.
struct LampSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { o in
                LatchButton(title: label(o), on: o == selection, tint: tint) { selection = o }
            }
        }
    }
}

/// Uppercase section caption with a gold hairline.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(Theme.caption(10))
                .tracking(1.2)
                .foregroundStyle(Theme.gold)
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(Theme.gold.opacity(0.25)).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Label on the left, control on the right.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(Theme.caption(9.5))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
                .frame(width: 70, alignment: .leading)
            content
        }
    }
}

/// Horizontal level slider: recessed track, gold fill, metal knob. Drag or scroll; ⇧ for fine steps.
struct LevelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    var tint: Color = Theme.gold
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 14
            let usable = max(1, w - knob)
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = knob / 2 + usable * CGFloat(frac)
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    let track = CGRect(x: knob / 2, y: mid - 2.5, width: usable, height: 5)
                    ctx.fill(Path(roundedRect: track, cornerRadius: 2.5), with: .color(Theme.track))
                    ctx.stroke(Path(roundedRect: track, cornerRadius: 2.5), with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    let fill = CGRect(x: knob / 2, y: mid - 1.5, width: x - knob / 2, height: 3)
                    ctx.fill(Path(roundedRect: fill, cornerRadius: 1.5), with: .color(tint))
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.2)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: knob * 0.75))
                    .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                    let dv = Double(g.translation.width / usable) * (range.upperBound - range.lowerBound) * fine
                    set((dragStart ?? value) + dv)
                }
                .onEnded { _ in dragStart = nil })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { dir in set(value + (dir == .increment ? step : -step) * 2) }
    }

    private func set(_ v: Double) {
        value = min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
    }
}

/// Mono horizontal peak meter, −60…0 dBFS, as glowing LED segments.
struct HMeter: View {
    var level: Float          // linear peak
    var hold: Float = 0

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 1.2, segW: CGFloat = 3
            let n = max(1, Int((size.width + gap) / (segW + gap)))
            let db = level > 0 ? 20 * log10(Double(level)) : -100
            let frac = max(0, min(1, (db + 60) / 60))
            var lit: [(CGRect, Color)] = []
            for k in 0..<n {
                let pos = (Double(k) + 0.5) / Double(n)
                let color = pos < 0.7 ? Theme.ok : pos < 0.9 ? Theme.warn : Theme.danger
                let rect = CGRect(x: CGFloat(k) * (segW + gap), y: 0, width: segW, height: size.height)
                if pos <= frac { lit.append((rect, color)) } else { ctx.fill(Path(rect), with: .color(color.opacity(0.10))) }
            }
            guard !lit.isEmpty else { return }
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 2))
                for (r, c) in lit { glow.fill(Path(r), with: .color(c.opacity(0.8))) }
            }
            for (r, c) in lit { ctx.fill(Path(r), with: .color(c)) }
        }
        .frame(height: 8)
        .padding(3)
        .gmWell(radius: 3)
        .accessibilityHidden(true)
    }
}

/// Large lit transport button (Capture / Stop).
struct BigLampButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.gold
    var lit = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                Text(title).font(Theme.caption(13)).tracking(1.4)
            }
            .foregroundStyle(lit && enabled ? Theme.obsidian : Theme.text.opacity(enabled ? 0.85 : 0.35))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(LampFace(on: lit && enabled, tint: enabled ? tint : Theme.steel, radius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Recessed text field.
struct WellField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.heading(12))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .gmWell()
    }
}

/// A styled pop-up menu showing the current choice.
struct WellMenu<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(label(o), systemImage: "checkmark") } else { Text(label(o)) }
                }
            }
        } label: {
            HStack {
                Text(label(selection)).font(Theme.heading(11.5)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.gold)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gmWell()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A themed checkbox row.
struct LampCheck: View {
    let text: String
    @Binding var on: Bool
    var detail: String? = nil

    var body: some View {
        Button { on.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.track)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.gold.opacity(on ? 0.9 : 0.35), lineWidth: 0.75))
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.gold)
                            .shadow(color: Theme.gold.opacity(0.8), radius: 2)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text).font(Theme.heading(11.5)).foregroundStyle(Theme.text.opacity(on ? 0.95 : 0.8))
                    if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.dim) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
