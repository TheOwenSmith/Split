import SwiftUI

// Single sheet target — drives both "new" and "edit" with one .sheet modifier
private enum SheetTarget: Identifiable {
    case new
    case edit(Workout)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let w): return w.id.uuidString
        }
    }
}

struct WorkoutsView: View {
    var vm: SpeechTimerViewModel
    @Environment(WorkoutStore.self) var store
    @State private var sheetTarget: SheetTarget? = nil

    // Abort-and-switch confirmation
    @State private var pendingWorkout: Workout?? = nil   // outer nil = no pending; .some(nil) = freestyle
    @State private var pendingIsSet = false
    @State private var showAbortAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black.ignoresSafeArea()

                    if store.workouts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "figure.run.circle")
                                .font(.system(size: 52))
                                .foregroundStyle(Color.gray)
                            Text("No workouts yet")
                                .font(.headline)
                                .foregroundStyle(Color.gray)
                            Text("Tap + to design your first workout")
                                .font(.subheadline)
                                .foregroundStyle(Color(white: 0.4))
                        }
                    } else {
                        List {
                            Section {
                                Button { requestSwitch(to: nil) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Freestyle")
                                                .font(.headline)
                                                .foregroundStyle(Color.white)
                                            Text("No distance tracking")
                                                .font(.caption)
                                                .foregroundStyle(Color.gray)
                                        }
                                        Spacer()
                                        if vm.activeWorkout == nil {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.green)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color(white: 0.1))

                            Section("Saved Workouts") {
                                ForEach(store.workouts) { workout in
                                    Button { requestSwitch(to: workout) } label: {
                                        WorkoutRow(workout: workout, isActive: vm.activeWorkout?.id == workout.id)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            if let i = store.workouts.firstIndex(where: { $0.id == workout.id }) {
                                                store.delete(at: IndexSet(integer: i))
                                                if vm.activeWorkout?.id == workout.id { vm.setWorkout(nil) }
                                            }
                                        } label: { Label("Delete", systemImage: "trash") }

                                        Button {
                                            sheetTarget = .edit(workout)
                                        } label: { Label("Edit", systemImage: "pencil") }
                                            .tint(.blue)
                                    }
                                }
                            }
                            .listRowBackground(Color(white: 0.1))
                        }
                        .scrollContentBackground(.hidden)
                    }
                }  // ZStack

                if vm.showDebug { DebugConsoleView(vm: vm) }
            }  // VStack
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DebugToggleButton(vm: vm)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheetTarget = .new } label: {
                        Image(systemName: "plus").foregroundStyle(Color.green)
                    }
                }
            }
            .sheet(item: $sheetTarget) { target in
                switch target {
                case .new:
                    WorkoutEditorView(existing: nil) { saved in
                        store.add(saved)
                    }
                case .edit(let workout):
                    WorkoutEditorView(existing: workout) { saved in
                        var updated = saved
                        updated.id = workout.id
                        store.update(updated)
                        if vm.activeWorkout?.id == workout.id { vm.setWorkout(updated) }
                    }
                }
            }
            .alert("Switch Workouts?", isPresented: $showAbortAlert) {
                Button("Abort & Switch", role: .destructive) {
                    guard pendingIsSet else { return }
                    vm.abortWorkout()
                    vm.setWorkout(pendingWorkout ?? nil)
                    pendingIsSet = false
                    pendingWorkout = nil
                }
                Button("Keep Going", role: .cancel) {
                    pendingIsSet = false
                    pendingWorkout = nil
                }
            } message: {
                Text("To switch workouts, you must abort your current workout. Your splits will not be saved.")
            }
        }
    }

    private func requestSwitch(to workout: Workout?) {
        if vm.appState == .running || vm.appState == .resting {
            pendingWorkout = Optional(workout)
            pendingIsSet = true
            showAbortAlert = true
        } else {
            vm.setWorkout(workout)
        }
    }
}

struct WorkoutRow: View {
    let workout: Workout
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.name)
                    .font(.headline)
                    .foregroundStyle(Color.white)

                Text(distanceSummary)
                    .font(.caption)
                    .foregroundStyle(Color.gray)

                Text(paceSummary)
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.45))
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var distanceSummary: String {
        let parts = workout.items.compactMap { item -> String? in
            if item.isInterval { return item.distanceLabel }
            if item.isLoop     { return item.loopLabel }
            return nil
        }.joined(separator: " / ")
        return parts + "  (\(workout.totalDistanceMeters)m total)"
    }

    private var paceSummary: String {
        let allIntervals = workout.expandedIntervals
        let allRests = workout.expandedItems.filter { $0.isRest }
        let paces = allIntervals.map { $0.goalFormatted }
        let rests = allRests.map { $0.restFormatted }
        var parts = ["Goals: " + paces.joined(separator: " / ")]
        if !rests.isEmpty { parts.append("Rest: " + rests.prefix(3).joined(separator: " / ")) }
        return parts.joined(separator: "  •  ")
    }
}

#Preview {
    WorkoutsView(vm: SpeechTimerViewModel())
        .environment(WorkoutStore())
}
