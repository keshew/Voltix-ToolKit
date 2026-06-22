import Foundation

enum ElectricalCalculation {
    static let standardBreakers = [6, 10, 16, 20, 25, 32, 40, 50, 63, 80, 100, 125, 160, 200, 250]
    static let metricCableSizes = [1.5, 2.5, 4, 6, 10, 16, 25, 35, 50, 70, 95, 120]

    static func finite(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }

    static func current(power: Double, voltage: Double, powerFactor: Double, threePhase: Bool) -> Double {
        guard power >= 0, voltage > 0, powerFactor > 0 else { return 0 }
        return finite(power / (voltage * powerFactor * (threePhase ? sqrt(3) : 1)))
    }

    static func power(voltage: Double, current: Double, powerFactor: Double, threePhase: Bool = false) -> Double {
        guard voltage >= 0, current >= 0, powerFactor >= 0 else { return 0 }
        return finite(voltage * current * powerFactor * (threePhase ? sqrt(3) : 1))
    }

    static func voltageDrop(distance: Double, current: Double, resistivity: Double, area: Double, threePhase: Bool = false) -> Double {
        guard distance >= 0, current >= 0, resistivity > 0, area > 0 else { return 0 }
        let conductorFactor = threePhase ? sqrt(3) : 2
        return finite(conductorFactor * distance * current * resistivity / area)
    }

    static func breaker(for load: Double, continuous: Bool) -> Int {
        let designLoad = max(0, load) * (continuous ? 1.25 : 1)
        return standardBreakers.first(where: { Double($0) >= designLoad }) ?? standardBreakers.last!
    }

    static func cableSize(current: Double, length: Double, resistivity: Double, ampacityFactor: Double, voltage: Double = 230, maximumDrop: Double = 0.03) -> Double {
        guard current > 0, voltage > 0, maximumDrop > 0, ampacityFactor > 0 else { return metricCableSizes[0] }
        let ampacityArea = current / ampacityFactor
        let dropArea = 2 * max(0, length) * current * resistivity / (voltage * maximumDrop)
        let needed = max(ampacityArea, dropArea)
        return metricCableSizes.first(where: { $0 >= needed }) ?? metricCableSizes.last!
    }

    static func batteryRuntime(ampHours: Double, voltage: Double, load: Double, efficiency: Double, usableDepth: Double = 0.8) -> Double {
        guard ampHours > 0, voltage > 0, load > 0, efficiency > 0, usableDepth > 0 else { return 0 }
        return finite(ampHours * voltage * min(efficiency, 1) * min(usableDepth, 1) / load)
    }

    static func transformerSecondaryCurrent(voltAmps: Double, secondaryVoltage: Double, threePhase: Bool) -> Double {
        guard voltAmps > 0, secondaryVoltage > 0 else { return 0 }
        return finite(voltAmps / (secondaryVoltage * (threePhase ? sqrt(3) : 1)))
    }

    static func turnsRatio(primaryVoltage: Double, secondaryVoltage: Double) -> Double {
        guard primaryVoltage > 0, secondaryVoltage > 0 else { return 0 }
        return finite(primaryVoltage / secondaryVoltage)
    }

    static func monthlyEnergyCost(watts: Double, hoursPerDay: Double, days: Double = 30, rate: Double) -> Double {
        guard watts >= 0, hoursPerDay >= 0, days >= 0, rate >= 0 else { return 0 }
        return finite(watts / 1000 * hoursPerDay * days * rate)
    }

    static func lightingFixtureCount(length: Double, width: Double, targetLux: Double, fixtureLumens: Double, utilization: Double = 0.72) -> Int {
        guard length > 0, width > 0, targetLux > 0, fixtureLumens > 0, utilization > 0 else { return 0 }
        return max(1, Int(ceil(length * width * targetLux / (fixtureLumens * utilization))))
    }
}

struct CableComparison {
    let size: Double
    let dropVolts: Double
    let dropPercent: Double
    let safetyMargin: Double

    init(size: Double, current: Double, length: Double, voltage: Double, resistivity: Double) {
        self.size = size
        dropVolts = ElectricalCalculation.voltageDrop(distance: length, current: current, resistivity: resistivity, area: size)
        dropPercent = voltage > 0 ? dropVolts / voltage * 100 : 0
        safetyMargin = max(0, size * 7 - current)
    }
}
