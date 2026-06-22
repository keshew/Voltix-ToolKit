import SwiftUI

enum ReferenceKind: String, CaseIterable, Identifiable {
    case awg = "AWG Scale", ampacity = "Cable Ampacity", colors = "Color Codes", formulas = "Formula Library"
    var id: String { rawValue }
    var detail: String { switch self { case .awg: "Wire diameter visualizer"; case .ampacity: "Current carrying capacity"; case .colors: "IEC & NEC conductors"; case .formulas: "Essential field equations" } }
    var icon: String { switch self { case .awg: "circle.dotted"; case .ampacity: "thermometer.medium"; case .colors: "paintpalette.fill"; case .formulas: "function" } }
}

struct ReferenceHubView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                ScreenHeader(eyebrow: "Offline knowledge", title: "Reference Hub", subtitle: "Field answers without a signal")
                ForEach(ReferenceKind.allCases) { item in
                    NavigationLink(value: item) {
                        GlassCard {
                            HStack(spacing: 16) {
                                ZStack { Circle().fill(VoltixTheme.blue.opacity(0.14)).frame(width: 52); Image(systemName: item.icon).foregroundStyle(VoltixTheme.cyan) }
                                VStack(alignment: .leading, spacing: 4) { Text(item.rawValue).font(.headline); Text(item.detail).font(.caption).foregroundStyle(VoltixTheme.secondaryText) }
                                Spacer(); Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundStyle(VoltixTheme.secondaryText)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(18)
        }
        .navigationDestination(for: ReferenceKind.self) { item in
            switch item {
            case .awg: AWGReferenceView()
            case .ampacity: AmpacityReferenceView()
            case .colors: ColorCodeView()
            case .formulas: FormulaReferenceView()
            }
        }
        .voltixScreen()
    }
}

struct AWGReferenceView: View {
    @State private var gauge = 10.0
    private var diameter: Double { 0.127 * pow(92, (36-gauge)/39) }
    private var area: Double { .pi * pow(diameter, 2) / 4 }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 18) {
            ScreenHeader(eyebrow: "Wire scale", title: "AWG Reference")
            GlassCard { VStack(spacing: 20) { ZStack { ForEach(0..<5) { index in Circle().stroke(index == 4 ? VoltixTheme.cyan : .white.opacity(0.08), lineWidth: index == 4 ? 3 : 1).frame(width: max(28, CGFloat(diameter) * 21) + CGFloat(index * 9)) }; Circle().fill(LinearGradient(colors: [Color(hex: 0xE7A94B), Color(hex: 0x9B5B19)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: max(24, CGFloat(diameter)*20)) }; Text("\(Int(gauge)) AWG").font(.system(size: 42, weight: .bold, design: .rounded)); HStack { Metric(label: "Diameter", value: String(format: "%.2f mm", diameter)); Metric(label: "Area", value: String(format: "%.2f mm²", area), tint: VoltixTheme.cyan) } } }
            ValueInput(label: "Gauge", unit: "AWG", value: $gauge, range: 0...24, step: 1)
            Text("Smaller gauge number means a larger conductor.").font(.caption).foregroundStyle(VoltixTheme.secondaryText)
        }.padding(18) }.voltixScreen()
    }
}

struct AmpacityReferenceView: View {
    @State private var query = ""
    private let cables: [(String, String, String)] = [("1.5 mm²", "14 A", "Lighting"), ("2.5 mm²", "20 A", "Outlets"), ("4 mm²", "27 A", "Small loads"), ("6 mm²", "34 A", "Feeders"), ("10 mm²", "46 A", "Heavy loads"), ("16 mm²", "62 A", "Distribution")]
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 14) {
            ScreenHeader(eyebrow: "Copper · PVC 70°C", title: "Cable Ampacity")
            GlassCard(padding: 13) { HStack { Image(systemName: "magnifyingglass").foregroundStyle(VoltixTheme.secondaryText); TextField("Find cable size", text: $query).textInputAutocapitalization(.never) } }
            ForEach(cables.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }, id: \.0) { cable in
                GlassCard { HStack { ZStack { Circle().stroke(VoltixTheme.orange, lineWidth: 5).frame(width: 48); Circle().fill(Color(hex: 0xB56B24)).frame(width: 24) }; VStack(alignment: .leading, spacing: 3) { Text(cable.0).font(.headline); Text(cable.2).font(.caption).foregroundStyle(VoltixTheme.secondaryText) }; Spacer(); Text(cable.1).font(.title3.bold()).foregroundStyle(VoltixTheme.cyan) } }
            }
            Text("Reference values vary by installation method and local code.").font(.caption2).foregroundStyle(VoltixTheme.secondaryText).padding(.horizontal)
        }.padding(18) }.voltixScreen()
    }
}

struct ColorCodeView: View {
    private let codes: [(String, String, Color)] = [("Protective earth", "PE", Color(hex: 0x34D399)), ("Neutral", "N", Color(hex: 0x60A5FA)), ("Line 1", "L1", Color(hex: 0xA78BFA)), ("Line 2", "L2", Color(hex: 0x111827)), ("Line 3", "L3", Color(hex: 0x9B5B19)), ("DC positive", "+", Color(hex: 0xF87171))]
    var body: some View { ScrollView(showsIndicators: false) { VStack(spacing: 14) { ScreenHeader(eyebrow: "IEC conductor guide", title: "Color Codes"); ForEach(codes, id: \.0) { code in GlassCard { HStack(spacing: 16) { ZStack { Circle().fill(code.2).frame(width: 48); Text(code.1).font(.caption.bold()).foregroundStyle(.white).shadow(radius: 2) }; Text(code.0).font(.headline); Spacer(); Capsule().fill(code.2).frame(width: 52, height: 8) } } } }.padding(18) }.voltixScreen() }
}

struct FormulaReferenceView: View {
    private let formulas = [("Ohm’s Law", "I = V ÷ R", "Current from voltage and resistance"), ("Single-phase power", "P = V × I × PF", "Real electrical power"), ("Three-phase power", "P = √3 × V × I × PF", "Balanced three-phase load"), ("Voltage drop", "ΔV = 2 × L × I × ρ ÷ A", "Two-conductor circuit")]
    var body: some View { ScrollView(showsIndicators: false) { VStack(spacing: 14) { ScreenHeader(eyebrow: "Engineering essentials", title: "Formula Library"); ForEach(formulas, id: \.0) { item in GlassCard { VStack(alignment: .leading, spacing: 10) { Text(item.0.uppercased()).font(.caption2.bold()).foregroundStyle(VoltixTheme.cyan); Text(item.1).font(.system(size: 22, weight: .semibold, design: .monospaced)); Text(item.2).font(.caption).foregroundStyle(VoltixTheme.secondaryText) }.frame(maxWidth: .infinity, alignment: .leading) } } }.padding(18) }.voltixScreen() }
}
