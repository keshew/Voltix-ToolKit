import SwiftUI

enum AppTab: String, CaseIterable {
    case calculate = "Calculate", tools = "Tools", reference = "Reference", projects = "Projects", settings = "Settings"
    var icon: String {
        switch self {
        case .calculate: "bolt.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .reference: "books.vertical.fill"
        case .projects: "square.stack.3d.up.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainTabView: View {
    @State private var tab: AppTab = .calculate
    @StateObject private var projectStore = ProjectStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .calculate: NavigationStack { CalculationHubView() }
                case .tools: NavigationStack { ToolsHubView() }
                case .reference: NavigationStack { ReferenceHubView() }
                case .projects: NavigationStack { ProjectsView() }
                case .settings: NavigationStack { SettingsView() }
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 82) }

            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { tab = item }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .semibold))
                            Text(item.rawValue).font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(tab == item ? VoltixTheme.cyan : VoltixTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if tab == item { Capsule().fill(VoltixTheme.blue.opacity(0.13)).padding(.horizontal, 5) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(.white.opacity(0.1)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(VoltixTheme.background.ignoresSafeArea())
        .environmentObject(projectStore)
    }
}

enum CalculatorKind: String, CaseIterable, Identifiable {
    case current = "Current", voltageDrop = "Voltage Drop", cable = "Cable Size", power = "Power"
    case resistance = "Resistance", breaker = "Breaker", conduit = "Conduit Fill", energy = "Energy Cost"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .current: "bolt.horizontal.fill"
        case .voltageDrop: "arrow.down.right"
        case .cable: "cable.connector"
        case .power: "waveform.path.ecg"
        case .resistance: "alternatingcurrent"
        case .breaker: "switch.2"
        case .conduit: "circle.circle.fill"
        case .energy: "chart.line.uptrend.xyaxis"
        }
    }
    var subtitle: String {
        switch self {
        case .current: "V · W · Phase"
        case .voltageDrop: "Distance · Cable"
        case .cable: "Ampacity · Length"
        case .power: "W · kW · PF"
        case .resistance: "Ohm’s law"
        case .breaker: "Safe sizing"
        case .conduit: "Fill capacity"
        case .energy: "Monthly spend"
        }
    }
}

struct CalculationHubView: View {
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                HStack(alignment: .top) {
                    ScreenHeader(eyebrow: "Voltix field suite", title: "Calculation Hub", subtitle: "What are we solving today?")
                    StatusOrb()
                }
                FeaturedCurrentCard()
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(CalculatorKind.allCases) { calculator in
                        NavigationLink(value: calculator) { CalculatorTile(kind: calculator) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 110)
        }
        .navigationDestination(for: CalculatorKind.self) { kind in
            switch kind {
            case .current: CurrentCalculatorView()
            case .voltageDrop: VoltageDropView()
            case .cable: CableSizeView()
            case .power: PowerCalculatorView()
            case .resistance: OhmsLawView()
            case .breaker: BreakerView()
            case .conduit: ConduitFillView()
            case .energy: EnergyCostView()
            }
        }
        .voltixScreen()
    }
}

private struct StatusOrb: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(VoltixTheme.green.opacity(pulse ? 0.22 : 0.1)).frame(width: 48)
            Circle().fill(VoltixTheme.green).frame(width: 9).shadow(color: VoltixTheme.green, radius: 8)
        }.onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private struct FeaturedCurrentCard: View {
    var body: some View {
        NavigationLink(value: CalculatorKind.current) {
            GlassCard(padding: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("MOST USED", systemImage: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(VoltixTheme.cyan)
                        Text("Current\nCalculator").font(.system(size: 27, weight: .bold, design: .rounded))
                        Text("Instant load current").font(.caption).foregroundStyle(VoltixTheme.secondaryText)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(.white.opacity(0.06), lineWidth: 11)
                        Circle().trim(from: 0, to: 0.72).stroke(LinearGradient(colors: [VoltixTheme.blue, VoltixTheme.cyan], startPoint: .top, endPoint: .bottom), style: .init(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 0) { Text("13.6").font(.title2.bold()).monospacedDigit(); Text("AMPS").font(.system(size: 8, weight: .bold)).foregroundStyle(VoltixTheme.secondaryText) }
                    }.frame(width: 112, height: 112)
                }
            }
        }.buttonStyle(.plain)
    }
}

private struct CalculatorTile: View {
    let kind: CalculatorKind
    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack { RoundedRectangle(cornerRadius: 13).fill(VoltixTheme.blue.opacity(0.15)).frame(width: 42, height: 42); Image(systemName: kind.icon).foregroundStyle(VoltixTheme.cyan) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.rawValue).font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(kind.subtitle).font(.caption2).foregroundStyle(VoltixTheme.secondaryText)
                }
                HStack { Spacer(); Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundStyle(VoltixTheme.secondaryText) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolsHubView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                ScreenHeader(eyebrow: "Specialized", title: "Field Tools", subtitle: "Purpose-built calculators")
                NavigationLink { BatteryRuntimeView() } label: { ToolCard(title: "Battery Runtime", detail: "Ah · watts · efficiency", icon: "battery.75percent", color: VoltixTheme.green) }.buttonStyle(.plain)
                NavigationLink { MotorCalculatorView() } label: { ToolCard(title: "Motor Calculator", detail: "HP · kW · current", icon: "gearshape.2.fill", color: VoltixTheme.orange) }.buttonStyle(.plain)
                NavigationLink { LightingCalculatorView() } label: { ToolCard(title: "LED Lighting", detail: "Room lux planning", icon: "lightbulb.led.fill", color: VoltixTheme.cyan) }.buttonStyle(.plain)
                NavigationLink { TransformerCalculatorView() } label: { ToolCard(title: "Transformer", detail: "Primary · secondary · VA", icon: "arrow.triangle.2.circlepath", color: VoltixTheme.blue) }.buttonStyle(.plain)
                NavigationLink { QuickCompareView() } label: { ToolCard(title: "Quick Compare", detail: "Cable options side by side", icon: "square.split.2x1.fill", color: VoltixTheme.cyan) }.buttonStyle(.plain)
            }.padding(18)
        }.voltixScreen()
    }
}

private struct ToolCard: View {
    let title: String, detail: String, icon: String, color: Color
    var body: some View {
        GlassCard {
            HStack(spacing: 15) {
                ZStack { RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.15)).frame(width: 54, height: 54); Image(systemName: icon).font(.title3).foregroundStyle(color) }
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(VoltixTheme.secondaryText) }
                Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(VoltixTheme.secondaryText)
            }
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var showCreate = false
    @State private var projectName = ""
    @State private var projectLocation = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                ScreenHeader(eyebrow: "Workspace", title: "Projects", subtitle: "Your calculations, organized")
                if store.projects.isEmpty {
                    GlassCard { VStack(spacing: 14) { Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundStyle(VoltixTheme.secondaryText); Text("No projects yet").font(.headline); Text("Create a project or save a result from any calculator.").font(.caption).multilineTextAlignment(.center).foregroundStyle(VoltixTheme.secondaryText) }.frame(maxWidth: .infinity).padding(.vertical, 22) }
                }
                ForEach(store.projects) { project in
                    NavigationLink { ProjectDetailView(projectID: project.id) } label: {
                        ProjectCard(name: project.name, location: project.location, count: project.calculations.count, color: project.name == "Field Calculations" ? VoltixTheme.cyan : VoltixTheme.blue)
                    }.buttonStyle(.plain)
                }
                Button { showCreate = true } label: { GlassCard { HStack { Image(systemName: "plus.circle.fill").foregroundStyle(VoltixTheme.blue); Text("Create new project").fontWeight(.semibold); Spacer() } } }.buttonStyle(.plain)
            }.padding(18)
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                ZStack { VoltixBackground(); VStack(spacing: 14) { GlassCard { TextField("Project name", text: $projectName) }; GlassCard { TextField("Location or description", text: $projectLocation) }; Spacer() }.padding(18) }
                    .navigationTitle("New Project").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCreate = false } }; ToolbarItem(placement: .confirmationAction) { Button("Create") { store.create(name: projectName, location: projectLocation); projectName = ""; projectLocation = ""; showCreate = false }.disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
            }.preferredColorScheme(.dark)
        }
        .voltixScreen()
    }
}

private struct ProjectCard: View {
    let name: String, location: String, count: Int, color: Color
    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 25) {
                HStack { Image(systemName: "building.2.fill").foregroundStyle(color); Spacer(); Text("\(count) CALCS").font(.caption2.bold()).foregroundStyle(VoltixTheme.secondaryText) }
                VStack(alignment: .leading, spacing: 5) { Text(name).font(.title3.bold()); Text(location).font(.caption).foregroundStyle(VoltixTheme.secondaryText) }
                HStack(spacing: 4) { ForEach(0..<min(count, 7), id: \.self) { _ in Capsule().fill(color.opacity(0.7)).frame(height: 3) } }
            }
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    let projectID: UUID
    private var project: VoltixProject? { store.projects.first { $0.id == projectID } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                if let project {
                    ScreenHeader(eyebrow: project.location, title: project.name, subtitle: "\(project.calculations.count) saved calculations")
                    if project.calculations.isEmpty { GlassCard { Text("Save a result from a calculator to start this timeline.").font(.subheadline).foregroundStyle(VoltixTheme.secondaryText) } }
                    ForEach(project.calculations) { calculation in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) { Circle().fill(VoltixTheme.cyan).frame(width: 10, height: 10); Rectangle().fill(VoltixTheme.blue.opacity(0.25)).frame(width: 2, height: 90) }
                            GlassCard { VStack(alignment: .leading, spacing: 7) { HStack { Text(calculation.type.uppercased()).font(.caption2.bold()).foregroundStyle(VoltixTheme.cyan); Spacer(); Text(calculation.createdAt, style: .date).font(.caption2).foregroundStyle(VoltixTheme.secondaryText) }; Text(calculation.result).font(.title3.bold()); Text(calculation.summary).font(.caption).foregroundStyle(VoltixTheme.secondaryText); Button(role: .destructive) { store.deleteCalculation(calculation.id, from: projectID) } label: { Label("Delete", systemImage: "trash").font(.caption) } } }
                        }
                    }
                } else { GlassCard { Label("Project not found", systemImage: "exclamationmark.triangle").foregroundStyle(VoltixTheme.secondaryText) } }
            }.padding(18)
        }.voltixScreen()
    }
}

struct SettingsView: View {
    @State private var haptics = true
    @State private var metric = true
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                ScreenHeader(eyebrow: "Voltix", title: "Settings", subtitle: "Tune your field experience")
                GlassCard {
                    VStack(spacing: 22) {
                        Toggle(isOn: $haptics) { Label("Haptic feedback", systemImage: "waveform") }.tint(VoltixTheme.blue)
                        Divider().overlay(.white.opacity(0.08))
                        Toggle(isOn: $metric) { Label("Metric units", systemImage: "ruler") }.tint(VoltixTheme.blue)
                    }
                }
                GlassCard { HStack { VStack(alignment: .leading) { Text("Voltix ToolKit").fontWeight(.bold); Text("Version 1.0 · Offline ready").font(.caption).foregroundStyle(VoltixTheme.secondaryText) }; Spacer(); Image(systemName: "bolt.shield.fill").foregroundStyle(VoltixTheme.cyan) } }
            }.padding(18)
        }.voltixScreen()
    }
}
