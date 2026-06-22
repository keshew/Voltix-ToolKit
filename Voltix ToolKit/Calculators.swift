import SwiftUI

enum Phase: String, CaseIterable, CustomStringConvertible {
    case single = "1Φ", three = "3Φ"
    var description: String { rawValue }
}

enum ConductorMaterial: String, CaseIterable, CustomStringConvertible {
    case copper = "Copper", aluminum = "Aluminum"
    var description: String { rawValue }
    var resistivity: Double { self == .copper ? 0.0175 : 0.0282 }
}

struct CurrentCalculatorView: View {
    @State private var voltage = 230.0
    @State private var power = 3000.0
    @State private var phase: Phase = .single
    @State private var powerFactor = 0.96
    private var current: Double { ElectricalCalculation.current(power: power, voltage: voltage, powerFactor: powerFactor, threePhase: phase == .three) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ScreenHeader(eyebrow: "Live calculation", title: "Current", subtitle: "Load current updates instantly")
                ResultHero(label: "Calculated current", value: current.formatted(.number.precision(.fractionLength(2))), unit: "A")
                ValueInput(label: "Voltage", unit: "V", value: $voltage, range: 12...480)
                ValueInput(label: "Power", unit: "W", value: $power, range: 100...25000, step: 100, tint: VoltixTheme.cyan)
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PHASE").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText)
                        ChoicePills(options: Phase.allCases, selection: $phase)
                    }
                }
                SaveResultButton(calculation: SavedCalculation(type: "Current", summary: "\(Int(power)) W · \(Int(voltage)) V · \(phase.rawValue)", result: String(format: "%.2f A", current)))
                NavigationLink {
                    CurrentDetailsView(current: current)
                } label: {
                    HStack { Text("Analyze load").fontWeight(.semibold); Spacer(); Image(systemName: "chart.pie.fill") }
                        .padding(.horizontal, 18).frame(height: 56).background(VoltixTheme.blue, in: RoundedRectangle(cornerRadius: 19))
                }.buttonStyle(.plain)
            }.padding(18)
        }.navigationTitle("Current").navigationBarTitleDisplayMode(.inline).voltixScreen()
    }
}

struct CurrentDetailsView: View {
    let current: Double
    private var breaker: Double { Double(ElectricalCalculation.breaker(for: current, continuous: true)) }
    private var load: Double { current / breaker }
    private var exceedsStandardRange: Bool { current * 1.25 > Double(ElectricalCalculation.standardBreakers.last ?? 250) }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                ScreenHeader(eyebrow: "Load analysis", title: "Current Details")
                GaugeRing(progress: load, value: "\(Int(load * 100))%", caption: "breaker load", color: load > 0.8 ? VoltixTheme.orange : VoltixTheme.green).frame(width: 220, height: 220).padding(.vertical, 12)
                GlassCard { HStack { Metric(label: "Current", value: String(format: "%.2f A", current)); Metric(label: "Breaker", value: "\(Int(breaker)) A", tint: VoltixTheme.cyan); Metric(label: "Margin", value: String(format: "%.1f A", breaker-current), tint: VoltixTheme.green) } }
                GlassCard { Label(exceedsStandardRange ? "Load exceeds the built-in standard breaker range. Engineered protection is required." : "Designed with a 125% continuous-load safety factor.", systemImage: exceedsStandardRange ? "exclamationmark.triangle.fill" : "checkmark.shield.fill").font(.subheadline).foregroundStyle(exceedsStandardRange ? VoltixTheme.red : VoltixTheme.secondaryText) }
            }.padding(18)
        }.voltixScreen()
    }
}

struct VoltageDropView: View {
    @State private var distance = 30.0
    @State private var current = 20.0
    @State private var cable = 4.0
    @State private var voltage = 230.0
    @State private var material: ConductorMaterial = .copper
    private var drop: Double { ElectricalCalculation.voltageDrop(distance: distance, current: current, resistivity: material.resistivity, area: cable) }
    private var percentage: Double { drop / voltage * 100 }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ScreenHeader(eyebrow: "Circuit integrity", title: "Voltage Drop", subtitle: "Keep delivery efficient and safe")
                CableDropGraphic(source: voltage, drop: drop, percentage: percentage)
                ValueInput(label: "Distance", unit: "m", value: $distance, range: 1...250)
                ValueInput(label: "Current", unit: "A", value: $current, range: 1...100)
                ValueInput(label: "Cable", unit: "mm²", value: $cable, range: 1.5...35, step: 0.5, tint: VoltixTheme.cyan)
                GlassCard { ChoicePills(options: ConductorMaterial.allCases, selection: $material) }
                SaveResultButton(calculation: SavedCalculation(type: "Voltage Drop", summary: "\(Int(distance)) m · \(cable.formatted()) mm² · \(Int(current)) A", result: String(format: "%.2f V · %.2f%%", drop, percentage)))
            }.padding(18)
        }.navigationTitle("Voltage Drop").navigationBarTitleDisplayMode(.inline).voltixScreen()
    }
}

private struct CableDropGraphic: View {
    let source: Double, drop: Double, percentage: Double
    @State private var flow = false
    var statusColor: Color { percentage <= 3 ? VoltixTheme.green : percentage <= 5 ? VoltixTheme.orange : VoltixTheme.red }
    var body: some View {
        GlassCard(padding: 20) {
            VStack(spacing: 17) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) { Text("SOURCE").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); Text("\(Int(source)) V").font(.title3.bold()) }
                    Spacer()
                    VStack(alignment: .trailing) { Text("DELIVERED").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); Text(String(format: "%.1f V", source-drop)).font(.title3.bold()).foregroundStyle(statusColor) }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07)).frame(height: 7)
                        Capsule().fill(LinearGradient(colors: [VoltixTheme.blue, statusColor], startPoint: .leading, endPoint: .trailing)).frame(height: 7)
                        Circle().fill(.white).frame(width: 11).shadow(color: VoltixTheme.cyan, radius: 8).offset(x: flow ? geo.size.width - 11 : 0)
                    }
                }.frame(height: 11)
                HStack { Text(String(format: "−%.2f V", drop)).font(.headline.monospacedDigit()); Spacer(); Text(String(format: "%.2f%% drop", percentage)).font(.caption.bold()).foregroundStyle(statusColor) }
            }
        }.onAppear { withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { flow = true } }
    }
}

struct CableSizeView: View {
    @State private var current = 28.0
    @State private var length = 35.0
    @State private var material: ConductorMaterial = .copper
    @State private var install = 0
    private var required: Double {
        ElectricalCalculation.cableSize(current: current, length: length, resistivity: material.resistivity, ampacityFactor: [0.72, 0.8, 0.9][install] * (material == .copper ? 7.0 : 5.2))
    }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ScreenHeader(eyebrow: "Smart recommendation", title: "Cable Size", subtitle: "Ampacity and voltage drop combined")
                GlassCard(padding: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("RECOMMENDED", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(VoltixTheme.green)
                        HStack(alignment: .firstTextBaseline) { Text(required.formatted(.number.precision(.fractionLength(required == 1.5 || required == 2.5 ? 1 : 0)))).font(.system(size: 58, weight: .bold, design: .rounded)); Text("mm²").font(.title2.bold()).foregroundStyle(VoltixTheme.cyan); Spacer() }
                        Text("Balanced for safe load and ≤3% drop").font(.caption).foregroundStyle(VoltixTheme.secondaryText)
                    }
                }
                ValueInput(label: "Current", unit: "A", value: $current, range: 1...160)
                ValueInput(label: "Length", unit: "m", value: $length, range: 1...250, tint: VoltixTheme.cyan)
                GlassCard { VStack(alignment: .leading, spacing: 12) { Text("MATERIAL").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); ChoicePills(options: ConductorMaterial.allCases, selection: $material) } }
                GlassCard { VStack(alignment: .leading, spacing: 12) { Text("INSTALLATION").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); ChoicePills(options: ["Conduit", "Clipped", "Free air"], selection: Binding(get: { ["Conduit", "Clipped", "Free air"][install] }, set: { install = ["Conduit", "Clipped", "Free air"].firstIndex(of: $0) ?? 0 })) } }
                SaveResultButton(calculation: SavedCalculation(type: "Cable Size", summary: "\(Int(current)) A · \(Int(length)) m · \(material.rawValue)", result: "\(required.formatted()) mm²"))
            }.padding(18)
        }.navigationTitle("Cable Size").navigationBarTitleDisplayMode(.inline).voltixScreen()
    }
}

struct PowerCalculatorView: View {
    @State private var voltage = 230.0
    @State private var current = 10.0
    @State private var factor = 0.9
    private var watts: Double { ElectricalCalculation.power(voltage: voltage, current: current, powerFactor: factor) }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 14) {
            ScreenHeader(eyebrow: "Power flow", title: "Power")
            ResultHero(label: "Real power", value: String(format: "%.2f", watts / 1000), unit: "kW", tint: VoltixTheme.orange)
            GlassCard { HStack { Metric(label: "Watts", value: "\(Int(watts)) W"); Metric(label: "Apparent", value: String(format: "%.2f kVA", voltage*current/1000), tint: VoltixTheme.cyan) } }
            ValueInput(label: "Voltage", unit: "V", value: $voltage, range: 12...480)
            ValueInput(label: "Current", unit: "A", value: $current, range: 0.5...100, step: 0.5)
            ValueInput(label: "Power Factor", unit: "PF", value: $factor, range: 0.5...1, step: 0.01, tint: VoltixTheme.orange)
        }.padding(18) }.voltixScreen()
    }
}

struct OhmsLawView: View {
    @State private var voltage = 12.0
    @State private var resistance = 6.0
    private var current: Double { voltage / resistance }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 15) {
            ScreenHeader(eyebrow: "Interactive explorer", title: "Ohm’s Law", subtitle: "Move the controls. See the circuit react.")
            ZStack {
                GaugeRing(progress: min(current / 10, 1), value: String(format: "%.2f A", current), caption: "current", color: VoltixTheme.cyan)
                VStack { Text("V").font(.title.bold()); Divider().frame(width: 34).overlay(.white); Text("R").font(.title.bold()) }.offset(y: 91)
            }.frame(width: 230, height: 275)
            ValueInput(label: "Voltage", unit: "V", value: $voltage, range: 1...240, step: 1)
            ValueInput(label: "Resistance", unit: "Ω", value: $resistance, range: 1...100, step: 0.5, tint: VoltixTheme.orange)
            GlassCard { Text("I = V ÷ R  =  \(String(format: "%.1f", voltage)) V ÷ \(String(format: "%.1f", resistance)) Ω  =  \(String(format: "%.2f", current)) A").font(.system(.subheadline, design: .monospaced)).foregroundStyle(VoltixTheme.secondaryText) }
        }.padding(18) }.voltixScreen()
    }
}

struct BreakerView: View {
    @State private var load = 13.0
    @State private var continuous = true
    private var recommendation: Int { ElectricalCalculation.breaker(for: load, continuous: continuous) }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 15) {
            ScreenHeader(eyebrow: "Circuit protection", title: "Breaker Size")
            GlassCard(padding: 22) { VStack(alignment: .leading, spacing: 9) { Text("SAFE RECOMMENDATION").font(.caption2.bold()).foregroundStyle(VoltixTheme.green); HStack(alignment: .firstTextBaseline) { Text("\(recommendation)").font(.system(size: 62, weight: .bold, design: .rounded)); Text("A").font(.title.bold()).foregroundStyle(VoltixTheme.cyan); Spacer(); Image(systemName: "checkmark.shield.fill").font(.largeTitle).foregroundStyle(VoltixTheme.green) }; Text("Next standard rating above design current").font(.caption).foregroundStyle(VoltixTheme.secondaryText) } }
            ValueInput(label: "Load Current", unit: "A", value: $load, range: 1...100, step: 0.5)
            GlassCard { Toggle(isOn: $continuous) { VStack(alignment: .leading) { Text("Continuous load").fontWeight(.semibold); Text("Applies 125% safety factor").font(.caption).foregroundStyle(VoltixTheme.secondaryText) } }.tint(VoltixTheme.blue) }
            SaveResultButton(calculation: SavedCalculation(type: "Breaker", summary: String(format: "%.1f A load · %@", load, continuous ? "continuous" : "standard"), result: "\(recommendation) A"))
            HStack(spacing: 8) { ForEach([16, 20, 25, 32], id: \.self) { size in Text("\(size)A").font(.caption.bold()).foregroundStyle(size == recommendation ? .white : VoltixTheme.secondaryText).frame(maxWidth: .infinity).padding(.vertical, 13).background(size == recommendation ? VoltixTheme.blue : .white.opacity(0.05), in: Capsule()) } }
        }.padding(18) }.voltixScreen()
    }
}

struct ConduitFillView: View {
    @State private var conduit = 25.0
    @State private var wires = [2.5, 2.5, 4.0]
    private var conduitArea: Double { .pi * pow(conduit - 3, 2) / 4 }
    private var wireArea: Double { wires.reduce(0) { $0 + .pi * pow(sqrt($1) * 1.8, 2) / 4 } }
    private var fill: Double { wireArea / conduitArea }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 15) {
            ScreenHeader(eyebrow: "Raceway planning", title: "Conduit Fill")
            GaugeRing(progress: fill / 0.4, value: String(format: "%.0f%%", fill*100), caption: "fill", color: fill <= 0.4 ? VoltixTheme.green : VoltixTheme.red).frame(width: 220, height: 220).overlay { WireBundleView(count: wires.count).frame(width: 105, height: 105).offset(y: -55).opacity(0.35) }
            ValueInput(label: "Conduit", unit: "mm", value: $conduit, range: 16...63, step: 1)
            GlassCard { VStack(alignment: .leading, spacing: 14) { HStack { Text("CONDUCTORS").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); Spacer(); Text("\(wires.count)").fontWeight(.bold) }; HStack { ForEach([1.5, 2.5, 4, 6], id: \.self) { size in Button("+ \(size.formatted())") { wires.append(size) }.font(.caption.bold()).padding(.vertical, 10).frame(maxWidth: .infinity).background(VoltixTheme.blue.opacity(0.16), in: Capsule()).buttonStyle(.plain) } }; Button("Remove last") { if !wires.isEmpty { wires.removeLast() } }.font(.caption).foregroundStyle(VoltixTheme.secondaryText) } }
        }.padding(18) }.voltixScreen()
    }
}

private struct WireBundleView: View {
    let count: Int
    var body: some View { ZStack { ForEach(0..<count, id: \.self) { index in Circle().fill([VoltixTheme.blue, VoltixTheme.cyan, VoltixTheme.orange, VoltixTheme.green][index % 4]).frame(width: 30, height: 30).offset(x: cos(Double(index) * 2.4) * 25, y: sin(Double(index) * 2.4) * 25) } } }
}

struct EnergyCostView: View {
    @State private var watts = 1200.0
    @State private var hours = 5.0
    @State private var rate = 0.18
    private var monthly: Double { ElectricalCalculation.monthlyEnergyCost(watts: watts, hoursPerDay: hours, rate: rate) }
    var body: some View {
        ScrollView(showsIndicators: false) { VStack(spacing: 15) {
            ScreenHeader(eyebrow: "Usage forecast", title: "Energy Cost")
            ResultHero(label: "Estimated monthly", value: String(format: "$%.2f", monthly), unit: "", tint: VoltixTheme.green)
            MiniBarChart(base: monthly)
            ValueInput(label: "Equipment", unit: "W", value: $watts, range: 50...10000, step: 50)
            ValueInput(label: "Daily use", unit: "h", value: $hours, range: 0.5...24, step: 0.5)
            ValueInput(label: "Energy rate", unit: "$/kWh", value: $rate, range: 0.05...0.8, step: 0.01, tint: VoltixTheme.green)
        }.padding(18) }.voltixScreen()
    }
}

private struct MiniBarChart: View {
    let base: Double
    var body: some View { GlassCard { VStack(alignment: .leading, spacing: 15) { Text("6 MONTH OUTLOOK").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText); HStack(alignment: .bottom, spacing: 9) { ForEach(0..<6, id: \.self) { index in VStack { RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [VoltixTheme.cyan, VoltixTheme.blue], startPoint: .top, endPoint: .bottom)).frame(height: 45 + CGFloat(index) * 7); Text(["J", "A", "S", "O", "N", "D"][index]).font(.caption2).foregroundStyle(VoltixTheme.secondaryText) }.frame(maxWidth: .infinity) } } } } }
}

struct BatteryRuntimeView: View {
    @State private var ampHours = 100.0
    @State private var voltage = 12.0
    @State private var load = 180.0
    @State private var efficiency = 0.85
    private var runtime: Double { ElectricalCalculation.batteryRuntime(ampHours: ampHours, voltage: voltage, load: load, efficiency: efficiency) }
    var body: some View { ScrollView(showsIndicators: false) { VStack(spacing: 15) { ScreenHeader(eyebrow: "Stored energy", title: "Battery Runtime"); ResultHero(label: "Estimated runtime", value: String(format: "%.1f", runtime), unit: "hours", tint: VoltixTheme.green); Text("Includes 80% usable depth of discharge.").font(.caption).foregroundStyle(VoltixTheme.secondaryText); ValueInput(label: "Battery", unit: "Ah", value: $ampHours, range: 5...500, step: 5, tint: VoltixTheme.green); ValueInput(label: "Voltage", unit: "V", value: $voltage, range: 6...52); ValueInput(label: "Load", unit: "W", value: $load, range: 10...2500, step: 10); ValueInput(label: "Efficiency", unit: "%", value: Binding(get: { efficiency*100 }, set: { efficiency=$0/100 }), range: 60...98); SaveResultButton(calculation: SavedCalculation(type: "Battery Runtime", summary: "\(Int(ampHours)) Ah · \(Int(voltage)) V · \(Int(load)) W", result: String(format: "%.1f hours", runtime))) }.padding(18) }.voltixScreen() }
}

struct MotorCalculatorView: View {
    @State private var hp = 5.0
    @State private var voltage = 400.0
    @State private var efficiency = 0.88
    private var kw: Double { hp * 0.746 }
    private var amps: Double { kw * 1000 / (sqrt(3) * voltage * efficiency * 0.85) }
    var body: some View { ScrollView(showsIndicators: false) { VStack(spacing: 15) { ScreenHeader(eyebrow: "Three-phase drive", title: "Motor Calculator"); ResultHero(label: "Full-load current", value: String(format: "%.1f", amps), unit: "A", tint: VoltixTheme.orange); GlassCard { HStack { Metric(label: "Output", value: String(format: "%.2f kW", kw)); Metric(label: "Input", value: String(format: "%.2f kW", kw/efficiency), tint: VoltixTheme.cyan) } }; ValueInput(label: "Motor", unit: "HP", value: $hp, range: 0.5...100, step: 0.5, tint: VoltixTheme.orange); ValueInput(label: "Voltage", unit: "V", value: $voltage, range: 200...690); ValueInput(label: "Efficiency", unit: "%", value: Binding(get: { efficiency*100 }, set: { efficiency=$0/100 }), range: 60...98) }.padding(18) }.voltixScreen() }
}

struct LightingCalculatorView: View {
    @State private var length = 6.0
    @State private var width = 4.0
    @State private var lux = 300.0
    @State private var lumens = 1600.0
    private var count: Int { ElectricalCalculation.lightingFixtureCount(length: length, width: width, targetLux: lux, fixtureLumens: lumens) }
    var body: some View { ScrollView(showsIndicators: false) { VStack(spacing: 15) { ScreenHeader(eyebrow: "Lighting design", title: "LED Lighting"); ResultHero(label: "Recommended fixtures", value: "\(count)", unit: "LED", tint: VoltixTheme.cyan); ValueInput(label: "Room length", unit: "m", value: $length, range: 1...30, step: 0.5); ValueInput(label: "Room width", unit: "m", value: $width, range: 1...30, step: 0.5); ValueInput(label: "Target light", unit: "lux", value: $lux, range: 100...1000, step: 50); ValueInput(label: "Per fixture", unit: "lm", value: $lumens, range: 400...10000, step: 100) }.padding(18) }.voltixScreen() }
}

struct TransformerCalculatorView: View {
    @State private var primary = 400.0
    @State private var secondary = 230.0
    @State private var powerVA = 5000.0
    @State private var phase: Phase = .three
    private var ratio: Double { ElectricalCalculation.turnsRatio(primaryVoltage: primary, secondaryVoltage: secondary) }
    private var primaryCurrent: Double { ElectricalCalculation.transformerSecondaryCurrent(voltAmps: powerVA, secondaryVoltage: primary, threePhase: phase == .three) }
    private var secondaryCurrent: Double { ElectricalCalculation.transformerSecondaryCurrent(voltAmps: powerVA, secondaryVoltage: secondary, threePhase: phase == .three) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 15) {
                ScreenHeader(eyebrow: "Magnetic conversion", title: "Transformer", subtitle: "Ideal full-load values")
                GlassCard(padding: 22) {
                    VStack(spacing: 18) {
                        HStack { Metric(label: "Primary current", value: String(format: "%.2f A", primaryCurrent)); Image(systemName: "arrow.right").foregroundStyle(VoltixTheme.cyan); Metric(label: "Secondary current", value: String(format: "%.2f A", secondaryCurrent), tint: VoltixTheme.cyan) }
                        Divider().overlay(.white.opacity(0.08))
                        HStack { Text("Turns ratio").foregroundStyle(VoltixTheme.secondaryText); Spacer(); Text(String(format: "%.3f : 1", ratio)).font(.title3.bold()).monospacedDigit() }
                    }
                }
                ValueInput(label: "Primary", unit: "V", value: $primary, range: 12...15000)
                ValueInput(label: "Secondary", unit: "V", value: $secondary, range: 6...1000, tint: VoltixTheme.cyan)
                ValueInput(label: "Rated power", unit: "VA", value: $powerVA, range: 100...500000, step: 100, tint: VoltixTheme.orange)
                GlassCard { ChoicePills(options: Phase.allCases, selection: $phase) }
                SaveResultButton(calculation: SavedCalculation(type: "Transformer", summary: "\(Int(primary)) / \(Int(secondary)) V · \(phase.rawValue)", result: String(format: "%.2f A secondary", secondaryCurrent)))
            }.padding(18)
        }.navigationTitle("Transformer").navigationBarTitleDisplayMode(.inline).voltixScreen()
    }
}

struct QuickCompareView: View {
    @State private var firstSize = 4.0
    @State private var secondSize = 6.0
    @State private var current = 28.0
    @State private var length = 40.0
    @State private var voltage = 230.0
    @State private var material: ConductorMaterial = .copper
    private var first: CableComparison { CableComparison(size: firstSize, current: current, length: length, voltage: voltage, resistivity: material.resistivity) }
    private var second: CableComparison { CableComparison(size: secondSize, current: current, length: length, voltage: voltage, resistivity: material.resistivity) }
    private var winner: Double { first.dropPercent <= second.dropPercent ? firstSize : secondSize }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 15) {
                ScreenHeader(eyebrow: "Decision tool", title: "Quick Compare", subtitle: "Two cable options. One clear answer.")
                HStack(spacing: 10) {
                    ComparisonCard(comparison: first, recommended: first.dropPercent <= second.dropPercent)
                    VStack { Text("VS").font(.caption.bold()).foregroundStyle(VoltixTheme.secondaryText) }
                    ComparisonCard(comparison: second, recommended: second.dropPercent < first.dropPercent)
                }
                ValueInput(label: "Option A", unit: "mm²", value: $firstSize, range: 1.5...120, step: 0.5)
                ValueInput(label: "Option B", unit: "mm²", value: $secondSize, range: 1.5...120, step: 0.5, tint: VoltixTheme.cyan)
                ValueInput(label: "Load", unit: "A", value: $current, range: 1...250)
                ValueInput(label: "Length", unit: "m", value: $length, range: 1...500)
                GlassCard { ChoicePills(options: ConductorMaterial.allCases, selection: $material) }
                SaveResultButton(calculation: SavedCalculation(type: "Quick Compare", summary: "\(firstSize.formatted()) vs \(secondSize.formatted()) mm² · \(Int(length)) m", result: "Recommended \(winner.formatted()) mm²"))
            }.padding(18)
        }.navigationTitle("Quick Compare").navigationBarTitleDisplayMode(.inline).voltixScreen()
    }
}

private struct ComparisonCard: View {
    let comparison: CableComparison
    let recommended: Bool
    var body: some View {
        GlassCard(padding: 14) {
            VStack(spacing: 12) {
                Text(recommended ? "BETTER" : "OPTION").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(recommended ? VoltixTheme.green : VoltixTheme.secondaryText)
                Text("\(comparison.size.formatted())\nmm²").font(.system(size: 25, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                Divider().overlay(.white.opacity(0.08))
                Text(String(format: "%.2f%% drop", comparison.dropPercent)).font(.caption.bold()).foregroundStyle(comparison.dropPercent <= 3 ? VoltixTheme.green : VoltixTheme.orange)
                Text(String(format: "+%.0f A margin", comparison.safetyMargin)).font(.caption2).foregroundStyle(VoltixTheme.secondaryText)
            }.frame(maxWidth: .infinity)
        }
    }
}
