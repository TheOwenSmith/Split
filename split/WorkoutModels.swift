import Foundation

struct WorkoutItem: Codable, Identifiable {
    var id: UUID = UUID()
    var kind: Kind

    // Interval
    var distanceMeters: Int = 0
    var goalSeconds: TimeInterval = 0

    // Rest
    var restSeconds: TimeInterval = 0

    // Loop
    var repeatCount: Int = 1
    var loopItems: [WorkoutItem] = []

    enum Kind: String, Codable { case interval, rest, loop }

    static func interval(distanceMeters: Int, goalSeconds: TimeInterval) -> WorkoutItem {
        WorkoutItem(kind: .interval, distanceMeters: distanceMeters, goalSeconds: goalSeconds)
    }

    static func rest(seconds: TimeInterval) -> WorkoutItem {
        WorkoutItem(kind: .rest, restSeconds: seconds)
    }

    static func loop(items: [WorkoutItem], count: Int) -> WorkoutItem {
        WorkoutItem(kind: .loop, repeatCount: max(2, count), loopItems: items)
    }

    var isInterval: Bool { kind == .interval }
    var isRest:     Bool { kind == .rest }
    var isLoop:     Bool { kind == .loop }

    var distanceLabel: String { "\(distanceMeters)m" }

    var goalFormatted: String {
        let m = Int(goalSeconds) / 60
        let s = goalSeconds.truncatingRemainder(dividingBy: 60)
        if m > 0 { return String(format: "%d:%04.1f", m, s) }
        return String(format: "%.1f", s)
    }

    var restFormatted: String {
        let m = Int(restSeconds) / 60
        let s = Int(restSeconds) % 60
        if m > 0 && s > 0 { return "\(m)m \(s)s" }
        if m > 0 { return "\(m) min" }
        return "\(s)s"
    }

    var loopLabel: String {
        let parts = loopItems.map { item -> String in
            if item.isInterval { return item.distanceLabel }
            if item.isRest     { return "\(item.restFormatted) rest" }
            return "?"
        }.joined(separator: " + ")
        return "\(repeatCount)× (\(parts))"
    }

    var spokenDistance: String {
        if distanceMeters >= 1000 && distanceMeters % 1000 == 0 {
            let k = distanceMeters / 1000
            return "\(k) kilometer\(k == 1 ? "" : "s")"
        }
        return "\(distanceMeters) meter"
    }

    /// Expand this item into a flat list (loops repeat loopItems × repeatCount).
    var expanded: [WorkoutItem] {
        guard isLoop else { return [self] }
        return Array(repeating: loopItems, count: max(1, repeatCount)).flatMap { $0 }
    }
}

struct Workout: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var items: [WorkoutItem]

    /// Flat list with all loops expanded — used by the workout runner.
    var expandedItems: [WorkoutItem] {
        items.flatMap { $0.expanded }
    }

    /// All intervals (expanded), used for rep counts and totals.
    var expandedIntervals: [WorkoutItem] {
        expandedItems.filter { $0.isInterval }
    }

    /// Top-level intervals only — used for display in the workout list row.
    var intervals: [WorkoutItem] {
        items.compactMap { item -> WorkoutItem? in
            item.isInterval ? item : nil
        }
    }

    var totalDistanceMeters: Int {
        expandedIntervals.reduce(0) { $0 + $1.distanceMeters }
    }
}

// MARK: - Persistence

@Observable
class WorkoutStore {
    var workouts: [Workout] = []

    init() { load() }

    func save() {
        guard let data = try? JSONEncoder().encode(workouts) else { return }
        try? data.write(to: Self.storeURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([Workout].self, from: data) else { return }
        workouts = decoded
    }

    func add(_ workout: Workout) { workouts.append(workout); save() }

    func update(_ workout: Workout) {
        if let i = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[i] = workout; save()
        }
    }

    func delete(at offsets: IndexSet) {
        offsets.sorted().reversed().forEach { workouts.remove(at: $0) }
        save()
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workouts.json")
    }
}
