import SwiftUI

struct ContentView: View {
    var holdSplash = false

    @AppStorage("hasSeenVoltixWelcome") private var hasSeenWelcome = false
    @State private var showSplash = true
    @State private var splashProgress = 0.0
    @State private var didCompleteSplashProgress = false

    var body: some View {
        ZStack {
            if showSplash {
                SplashView(progress: splashProgress)
                    .transition(.opacity)
            } else if !hasSeenWelcome {
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        hasSeenWelcome = true
                    }
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let steps = 28
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.easeOut(duration: 0.18)) {
                    splashProgress = Double(step) / Double(steps)
                }
            }
            try? await Task.sleep(for: .milliseconds(180))
            didCompleteSplashProgress = true
            completeSplashIfReady()
        }
        .onChange(of: holdSplash) { _ in
            completeSplashIfReady()
        }
    }

    private func completeSplashIfReady() {
        guard didCompleteSplashProgress, !holdSplash, showSplash else { return }
        withAnimation(.easeOut(duration: 0.55)) {
            showSplash = false
        }
    }
}

struct SplashView: View {
    let progress: Double
    @State private var phase: CGFloat = -1
    @State private var revealed = false

    var body: some View {
        ZStack {
            VoltixTheme.background.ignoresSafeArea()

            Canvas { context, size in
                var path = Path()
                let middle = size.height / 2
                path.move(to: CGPoint(x: 0, y: middle))
                path.addLine(to: CGPoint(x: size.width * 0.24, y: middle))
                path.addLine(to: CGPoint(x: size.width * 0.31, y: middle - 4))
                path.addLine(to: CGPoint(x: size.width * 0.37, y: middle + 4))
                path.addLine(to: CGPoint(x: size.width * 0.43, y: middle - 52))
                path.addLine(to: CGPoint(x: size.width * 0.49, y: middle + 64))
                path.addLine(to: CGPoint(x: size.width * 0.56, y: middle - 22))
                path.addLine(to: CGPoint(x: size.width * 0.63, y: middle))
                path.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.clear, VoltixTheme.blue, VoltixTheme.cyan, .clear]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .mask {
                Rectangle()
                    .frame(width: UIScreen.main.bounds.width * 1.5)
                    .offset(x: phase * UIScreen.main.bounds.width * 1.5)
            }
            .shadow(color: VoltixTheme.cyan.opacity(0.8), radius: 10)

            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(VoltixTheme.blue.opacity(0.14)).frame(width: 72, height: 72)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(VoltixTheme.cyan)
                }
                Text("VOLTIX")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(8)
                Text("PROFESSIONAL ELECTRICAL TOOLS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(VoltixTheme.secondaryText)

                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(VoltixTheme.cyan)
                        .frame(width: 176)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(VoltixTheme.secondaryText)
                }
                .padding(.top, 14)
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.92)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25)) { phase = 1 }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.8).delay(0.65)) { revealed = true }
        }
    }
}

struct WelcomeView: View {
    let continueAction: () -> Void
    @State private var animate = false

    var body: some View {
        ZStack {
            VoltixBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 42)
                CircuitHeroView(animate: animate)
                    .frame(height: 330)
                    .padding(.horizontal, 18)

                VStack(alignment: .leading, spacing: 16) {
                    Text("ENGINEERING, REFINED")
                        .font(.caption2.weight(.bold))
                        .tracking(2.1)
                        .foregroundStyle(VoltixTheme.cyan)
                    Text("Electrical calculations\nmade effortless.")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                    Text("Fast, accurate tools for the field — designed to work beautifully, even offline.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(VoltixTheme.secondaryText)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                Spacer()
                Button(action: continueAction) {
                    HStack {
                        Text("Enter Voltix").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 58)
                    .background(VoltixTheme.blue, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(24)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true } }
    }
}

private struct CircuitHeroView: View {
    let animate: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 36).stroke(.white.opacity(0.08)))
            Circle()
                .fill(VoltixTheme.blue.opacity(0.18))
                .frame(width: 190)
                .blur(radius: 35)
                .scaleEffect(animate ? 1.15 : 0.9)

            Canvas { context, size in
                let lines: [[CGPoint]] = [
                    [.init(x: 22, y: size.height * 0.25), .init(x: size.width * 0.33, y: size.height * 0.25), .init(x: size.width * 0.43, y: size.height * 0.45)],
                    [.init(x: size.width - 18, y: size.height * 0.24), .init(x: size.width * 0.72, y: size.height * 0.24), .init(x: size.width * 0.59, y: size.height * 0.46)],
                    [.init(x: 18, y: size.height * 0.72), .init(x: size.width * 0.28, y: size.height * 0.72), .init(x: size.width * 0.41, y: size.height * 0.57)],
                    [.init(x: size.width - 20, y: size.height * 0.76), .init(x: size.width * 0.7, y: size.height * 0.76), .init(x: size.width * 0.58, y: size.height * 0.58)]
                ]
                for points in lines {
                    var path = Path(); path.addLines(points)
                    context.stroke(path, with: .color(VoltixTheme.blue.opacity(0.65)), style: .init(lineWidth: 1.5, lineCap: .round))
                    for point in points.dropFirst().dropLast() {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(VoltixTheme.cyan))
                    }
                }
            }

            ZStack {
                Circle().stroke(VoltixTheme.blue.opacity(0.25), lineWidth: 18).frame(width: 152)
                Circle().trim(from: 0.08, to: 0.74)
                    .stroke(AngularGradient(colors: [VoltixTheme.blue, VoltixTheme.cyan], center: .center), style: .init(lineWidth: 5, lineCap: .round))
                    .frame(width: 152).rotationEffect(.degrees(-90))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: VoltixTheme.cyan, radius: animate ? 18 : 6)
            }
        }
    }
}
