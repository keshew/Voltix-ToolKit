import SwiftUI

enum VoltixTheme {
    static let background = Color(hex: 0x09090B)
    static let surface = Color(hex: 0x141417)
    static let blue = Color(hex: 0x3B82F6)
    static let cyan = Color(hex: 0x22D3EE)
    static let green = Color(hex: 0x34D399)
    static let orange = Color(hex: 0xFB923C)
    static let red = Color(hex: 0xF87171)
    static let secondaryText = Color(hex: 0xA1A1AA)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

struct VoltixBackground: View {
    var body: some View {
        ZStack {
            VoltixTheme.background.ignoresSafeArea()
            Circle().fill(VoltixTheme.blue.opacity(0.09)).frame(width: 330).blur(radius: 90).offset(x: 150, y: -330)
            Circle().fill(VoltixTheme.cyan.opacity(0.045)).frame(width: 260).blur(radius: 90).offset(x: -170, y: 280)
        }
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(VoltixTheme.surface.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.055), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.075), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
            }
    }
}

struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased()).font(.caption2.weight(.bold)).tracking(1.8).foregroundStyle(VoltixTheme.cyan)
            Text(title).font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-0.8)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(VoltixTheme.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ValueInput: View {
    let label: String
    let unit: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = VoltixTheme.blue
    @FocusState private var isEditing: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(VoltixTheme.secondaryText)
                    Spacer()
                    Button { value = max(range.lowerBound, value - step) } label: {
                        Image(systemName: "minus").font(.caption.bold()).frame(width: 30, height: 30).background(.white.opacity(0.05), in: Circle())
                    }.buttonStyle(.plain)
                    TextField("0", value: $value, format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                        .frame(minWidth: 72, maxWidth: 120)
                        .focused($isEditing)
                    Button { value = min(range.upperBound, value + step) } label: {
                        Image(systemName: "plus").font(.caption.bold()).frame(width: 30, height: 30).background(.white.opacity(0.05), in: Circle())
                    }.buttonStyle(.plain)
                    Text(unit).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                }
                Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }), in: range, step: step)
                    .tint(tint)
            }
        }
        .onChange(of: isEditing) { active in
            if !active { value = min(max(value, range.lowerBound), range.upperBound) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
            }
        }
    }
}

struct ChoicePills<Option: Hashable & CustomStringConvertible>: View {
    let options: [Option]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Text(option.description)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(selection == option ? .white : VoltixTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(selection == option ? VoltixTheme.blue : .white.opacity(0.045), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GaugeRing: View {
    let progress: Double
    let value: String
    let caption: String
    var color: Color = VoltixTheme.cyan

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.06), lineWidth: 18)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(AngularGradient(colors: [VoltixTheme.blue, color], center: .center), style: .init(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.35), radius: 10)
            VStack(spacing: 4) {
                Text(value).font(.system(size: 31, weight: .bold, design: .rounded)).monospacedDigit()
                Text(caption.uppercased()).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(VoltixTheme.secondaryText)
            }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(VoltixTheme.secondaryText)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResultHero: View {
    let label: String
    let value: String
    let unit: String
    var tint: Color = VoltixTheme.cyan
    var body: some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(VoltixTheme.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value).font(.system(size: 54, weight: .bold, design: .rounded)).tracking(-2).monospacedDigit().minimumScaleFactor(0.6)
                    Text(unit).font(.title3.weight(.bold)).foregroundStyle(tint)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SaveResultButton: View {
    @EnvironmentObject private var store: ProjectStore
    let calculation: SavedCalculation
    @State private var saved = false

    var body: some View {
        Button {
            store.save(calculation)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { saved = false } }
        } label: {
            HStack {
                Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                Text(saved ? "Saved to Projects" : "Save calculation").fontWeight(.semibold)
                Spacer()
            }
            .foregroundStyle(saved ? VoltixTheme.green : .white)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(saved ? VoltixTheme.green.opacity(0.12) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(saved ? VoltixTheme.green.opacity(0.35) : .white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}

extension View {
    func voltixScreen() -> some View {
        self.background(VoltixBackground()).foregroundStyle(.white).toolbarBackground(VoltixTheme.background.opacity(0.92), for: .navigationBar)
    }
}
