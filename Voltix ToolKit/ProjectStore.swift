import Foundation

struct SavedCalculation: Identifiable, Codable, Hashable {
    let id: UUID
    let type: String
    let summary: String
    let result: String
    let createdAt: Date

    init(type: String, summary: String, result: String) {
        id = UUID()
        self.type = type
        self.summary = summary
        self.result = result
        createdAt = Date()
    }
}

struct VoltixProject: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var location: String
    var calculations: [SavedCalculation]
    let createdAt: Date

    init(name: String, location: String = "Field project", calculations: [SavedCalculation] = []) {
        id = UUID()
        self.name = name
        self.location = location
        self.calculations = calculations
        createdAt = Date()
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [VoltixProject] = []
    private let storageKey = "voltix.projects.v1"

    init() { load() }

    func create(name: String, location: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        projects.insert(VoltixProject(name: cleanName, location: location.isEmpty ? "Field project" : location), at: 0)
        persist()
    }

    func save(_ calculation: SavedCalculation, to projectID: UUID? = nil) {
        if let projectID, let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].calculations.insert(calculation, at: 0)
        } else if let index = projects.firstIndex(where: { $0.name == "Field Calculations" }) {
            projects[index].calculations.insert(calculation, at: 0)
        } else {
            projects.insert(VoltixProject(name: "Field Calculations", location: "Quick saves", calculations: [calculation]), at: 0)
        }
        persist()
    }

    func deleteProjects(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        persist()
    }

    func deleteCalculation(_ calculationID: UUID, from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].calculations.removeAll { $0.id == calculationID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([VoltixProject].self, from: data) else { return }
        projects = decoded
    }
}
