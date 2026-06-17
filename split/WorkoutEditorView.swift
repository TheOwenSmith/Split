import SwiftUI

// MARK: - Editor sheet target

private enum EditorSheet: Identifiable {
    case addInterval
    case addRest
    case addLoop
    case editInterval(Int)
    case editRest(Int)
    case editLoop(Int)

    var id: String {
        switch self {
        case .addInterval:          return "add-interval"
        case .addRest:              return "add-rest"
        case .addLoop:              return "add-loop"
        case .editInterval(let i):  return "edit-interval-\(i)"
        case .editRest(let i):      return "edit-rest-\(i)"
        case .editLoop(let i):      return "edit-loop-\(i)"
        }
    }
}

// MARK: - Main editor

struct WorkoutEditorView: View {
    let existing: Workout?
    let onSave: (Workout) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var items: [WorkoutItem]
    @State private var editorSheet: EditorSheet? = nil
    @State private var editMode: EditMode = .inactive

    init(existing: Workout?, onSave: @escaping (Workout) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name  = State(initialValue: existing?.name ?? "")
        _items = State(initialValue: existing?.items ?? [])
    }

    private var canAddRest: Bool {
        !items.isEmpty && items.last?.isRest == false
    }

    private var totalExpandedIntervals: Int {
        items.flatMap { $0.expanded }.filter { $0.isInterval }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Form {
                    // Name
                    Section("Workout Name") {
                        TextField("e.g. Track Tuesday", text: $name)
                            .foregroundStyle(Color.white)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // Items list
                    Section {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if item.isLoop {
                                loopRow(item: item, at: index)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                    .listRowBackground(Color.cyan.opacity(0.04))
                            } else {
                                WorkoutItemRow(item: item)
                                    .draggable(item.id.uuidString)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            items.remove(at: index)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        Button {
                                            if item.isInterval { editorSheet = .editInterval(index) }
                                            else if item.isRest { editorSheet = .editRest(index) }
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                    .listRowBackground(Color(white: 0.12))
                            }
                        }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Intervals, Rests & Loops")
                    } footer: {
                        if !items.isEmpty {
                            let total = items.flatMap { $0.expanded }
                                .filter { $0.isInterval }
                                .reduce(0) { $0 + $1.distanceMeters }
                            Text("Total: \(total)m  •  Swipe left to edit or delete  •  Reorder with handles")
                        }
                    }

                    // Add buttons
                    Section {
                        Button { editorSheet = .addInterval } label: {
                            Label("Add Interval", systemImage: "plus.circle.fill")
                                .foregroundStyle(Color.green)
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button {
                            if canAddRest { editorSheet = .addRest }
                        } label: {
                            Label("Add Rest", systemImage: "timer")
                                .foregroundStyle(canAddRest ? Color.orange : Color.gray)
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button { editorSheet = .addLoop } label: {
                            Label("Add Loop", systemImage: "repeat")
                                .foregroundStyle(Color.cyan)
                        }
                        .listRowBackground(Color(white: 0.12))
                    }
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
            .navigationTitle(existing == nil ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.gray)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(Workout(name: name.isEmpty ? "Untitled" : name, items: items))
                        dismiss()
                    }
                    .foregroundStyle(Color.green)
                    .disabled(totalExpandedIntervals == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .foregroundStyle(editMode.isEditing ? Color.white : Color.gray)
                }
            }
            .sheet(item: $editorSheet) { target in
                switch target {
                case .addInterval:
                    IntervalEditorView(existing: nil) { items.append($0) }
                case .addRest:
                    RestEditorView(existing: nil) { items.append($0) }
                case .addLoop:
                    LoopEditorView(existing: nil) { items.append($0) }
                case .editInterval(let idx):
                    IntervalEditorView(existing: items[idx]) { items[idx] = $0 }
                case .editRest(let idx):
                    RestEditorView(existing: items[idx]) { items[idx] = $0 }
                case .editLoop(let idx):
                    LoopEditorView(existing: items[idx]) { items[idx] = $0 }
                }
            }
        }
    }

    // MARK: - Loop row (shown inline in the list as a visual container)

    @ViewBuilder
    private func loopRow(item: WorkoutItem, at index: Int) -> some View {
        LoopContainerRow(
            loop: item,
            onEdit:   { editorSheet = .editLoop(index) },
            onDelete: { items.remove(at: index) },
            onDrop: { droppedUUIDString in
                guard let droppedUUID = UUID(uuidString: droppedUUIDString),
                      let srcIdx = items.firstIndex(where: { $0.id == droppedUUID }),
                      items[srcIdx].isInterval || items[srcIdx].isRest else { return }
                let dropped = items[srcIdx]
                items.remove(at: srcIdx)
                // Re-find the loop (index may have shifted after removal)
                if let loopIdx = items.firstIndex(where: { $0.id == item.id }) {
                    items[loopIdx].loopItems.append(dropped)
                }
            },
            onEjectLoopItem: { loopItemID in
                guard let loopIdx = items.firstIndex(where: { $0.id == item.id }),
                      let liIdx = items[loopIdx].loopItems.firstIndex(where: { $0.id == loopItemID }) else { return }
                let ejected = items[loopIdx].loopItems[liIdx]
                items[loopIdx].loopItems.remove(at: liIdx)
                // Insert right after the loop in the top-level list
                items.insert(ejected, at: loopIdx + 1)
            }
        )
    }
}

// MARK: - Loop container row

struct LoopContainerRow: View {
    let loop: WorkoutItem
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDrop: (String) -> Void
    let onEjectLoopItem: (UUID) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.cyan)
                Text("\(loop.repeatCount)×")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cyan)
                Text("Loop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cyan.opacity(0.7))
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.cyan.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.cyan.opacity(0.12))

            // Loop items (with eject buttons)
            if loop.loopItems.isEmpty {
                Text("Empty — drag intervals or rests here")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.3))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                ForEach(loop.loopItems) { loopItem in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.cyan.opacity(0.25))
                            .frame(width: 2)
                            .padding(.vertical, 2)

                        WorkoutItemRow(item: loopItem)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)

                        Spacer()

                        Button {
                            onEjectLoopItem(loopItem.id)
                        } label: {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange.opacity(0.8))
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .background(Color.cyan.opacity(0.1))
                        .padding(.leading, 10)
                }
            }

            // Drop zone
            HStack(spacing: 6) {
                Image(systemName: isTargeted ? "plus.circle.fill" : "arrow.down.to.line")
                    .font(.system(size: 11))
                    .foregroundStyle(isTargeted ? Color.cyan : Color(white: 0.28))
                Text(isTargeted ? "Release to add to loop" : "Drag intervals or rests here")
                    .font(.caption2)
                    .foregroundStyle(isTargeted ? Color.cyan : Color(white: 0.28))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isTargeted ? Color.cyan.opacity(0.12) : Color(white: 0.06))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                onDrop(id)
                return true
            } isTargeted: { isTargeted = $0 }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTargeted ? Color.cyan.opacity(0.7) : Color.cyan.opacity(0.22), lineWidth: 1.5)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}

// MARK: - Item row

struct WorkoutItemRow: View {
    let item: WorkoutItem

    var body: some View {
        if item.isInterval {
            HStack(spacing: 10) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(item.distanceLabel)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
                Text("Goal: \(item.goalFormatted)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.green)
            }
        } else if item.isRest {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.caption).foregroundStyle(Color.orange).frame(width: 14)
                Text("\(item.restFormatted) rest")
                    .font(.subheadline).foregroundStyle(Color.orange)
                Spacer()
            }
            .padding(.leading, 8)
        } else if item.isLoop {
            HStack(spacing: 10) {
                Image(systemName: "repeat").font(.caption).foregroundStyle(Color.cyan).frame(width: 14)
                Text(item.loopLabel).font(.subheadline).foregroundStyle(Color.cyan)
                Spacer()
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - Interval editor (add + edit)

struct IntervalEditorView: View {
    let existing: WorkoutItem?
    let onSave: (WorkoutItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var distanceText: String
    @State private var goalMinutes: Int
    @State private var goalSeconds: Int
    @State private var goalTenths: Int

    let commonDistances = [100, 200, 300, 400, 600, 800, 1000, 1200, 1600]

    init(existing: WorkoutItem?, onSave: @escaping (WorkoutItem) -> Void) {
        self.existing = existing
        self.onSave   = onSave
        let dist = existing?.distanceMeters ?? 200
        let goal = existing?.goalSeconds ?? 30.0
        _distanceText = State(initialValue: "\(dist)")
        _goalMinutes  = State(initialValue: Int(goal) / 60)
        _goalSeconds  = State(initialValue: Int(goal) % 60)
        _goalTenths   = State(initialValue: Int((goal * 10).truncatingRemainder(dividingBy: 10)))
    }

    private var goalTotal: TimeInterval {
        TimeInterval(goalMinutes * 60 + goalSeconds) + TimeInterval(goalTenths) / 10
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("Distance (meters)") {
                        TextField("e.g. 400", text: $distanceText)
                            .keyboardType(.numberPad).foregroundStyle(Color.white)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(commonDistances, id: \.self) { d in
                                    let sel = distanceText == "\(d)"
                                    Button("\(d)m") { distanceText = "\(d)" }
                                        .font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(sel ? Color.green.opacity(0.3) : Color.white.opacity(0.08))
                                        .foregroundStyle(sel ? Color.green : Color.white)
                                        .clipShape(Capsule())
                                }
                            }.padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section("Goal Time") { goalTimePicker }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(existing == nil ? "Add Interval" : "Edit Interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.gray)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(existing == nil ? "Add" : "Save") {
                        let dist = Int(distanceText) ?? 200
                        onSave(.interval(distanceMeters: dist, goalSeconds: goalTotal))
                        dismiss()
                    }.foregroundStyle(Color.green)
                }
            }
        }
    }

    private var goalTimePicker: some View {
        HStack(spacing: 0) {
            Picker("", selection: $goalMinutes) {
                ForEach(0..<10, id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.wheel).frame(width: 56, height: 120).clipped()
            Text("min").font(.subheadline).foregroundStyle(Color(white: 0.55)).frame(width: 36)
            Picker("", selection: $goalSeconds) {
                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(width: 56, height: 120).clipped()
            Text(".").font(.subheadline).foregroundStyle(Color(white: 0.55)).frame(width: 14)
            Picker("", selection: $goalTenths) {
                ForEach(0..<10, id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.wheel).frame(width: 40, height: 120).clipped()
            Text("s").font(.subheadline).foregroundStyle(Color(white: 0.55)).frame(width: 20)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Rest editor (add + edit)

struct RestEditorView: View {
    let existing: WorkoutItem?
    let onSave: (WorkoutItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var restMinutes: Int
    @State private var restSeconds: Int

    init(existing: WorkoutItem?, onSave: @escaping (WorkoutItem) -> Void) {
        self.existing = existing
        self.onSave   = onSave
        let secs = existing?.restSeconds ?? 120
        _restMinutes = State(initialValue: Int(secs) / 60)
        _restSeconds = State(initialValue: Int(secs) % 60)
    }

    private var restTotal: TimeInterval { TimeInterval(restMinutes * 60 + restSeconds) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("Rest Duration") { restTimePicker }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(existing == nil ? "Add Rest" : "Edit Rest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.gray)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(existing == nil ? "Add" : "Save") {
                        onSave(.rest(seconds: restTotal))
                        dismiss()
                    }
                    .foregroundStyle(Color.orange)
                    .disabled(restTotal == 0)
                }
            }
        }
    }

    private var restTimePicker: some View {
        HStack(spacing: 0) {
            Picker("", selection: $restMinutes) {
                ForEach(0..<15, id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.wheel).frame(width: 56, height: 120).clipped()
            Text("min").font(.subheadline).foregroundStyle(Color(white: 0.55)).frame(width: 36)
            Picker("", selection: $restSeconds) {
                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(width: 56, height: 120).clipped()
            Text("s").font(.subheadline).foregroundStyle(Color(white: 0.55)).frame(width: 20)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Loop editor (add + edit)

struct LoopEditorView: View {
    let existing: WorkoutItem?
    let onSave: (WorkoutItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var repeatCount: Int
    @State private var loopItems: [WorkoutItem]
    @State private var innerSheet: InnerSheet? = nil
    @State private var innerEditMode: EditMode = .inactive

    private enum InnerSheet: Identifiable {
        case addInterval, addRest, editInterval(Int), editRest(Int)
        var id: String {
            switch self {
            case .addInterval:          return "add-i"
            case .addRest:              return "add-r"
            case .editInterval(let i):  return "edit-i-\(i)"
            case .editRest(let i):      return "edit-r-\(i)"
            }
        }
    }

    init(existing: WorkoutItem?, onSave: @escaping (WorkoutItem) -> Void) {
        self.existing    = existing
        self.onSave      = onSave
        _repeatCount     = State(initialValue: existing?.repeatCount ?? 4)
        _loopItems       = State(initialValue: existing?.loopItems ?? [])
    }

    private var canAddRest: Bool {
        !loopItems.isEmpty && loopItems.last?.isRest == false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("Repeat Count") {
                        HStack {
                            Text("Repeat").foregroundStyle(Color.white)
                            Spacer()
                            Picker("", selection: $repeatCount) {
                                ForEach(2...30, id: \.self) { Text("\($0)×").tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(Color.cyan)
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section {
                        ForEach(Array(loopItems.enumerated()), id: \.element.id) { index, item in
                            WorkoutItemRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        loopItems.remove(at: index)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        if item.isInterval { innerSheet = .editInterval(index) }
                                        else if item.isRest { innerSheet = .editRest(index) }
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .listRowBackground(Color(white: 0.12))
                        }
                        .onMove { loopItems.move(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Loop Contents")
                    } footer: {
                        if !loopItems.isEmpty {
                            let perRep = loopItems.filter { $0.isInterval }.reduce(0) { $0 + $1.distanceMeters }
                            Text("Per rep: \(perRep)m  •  Total: \(perRep * repeatCount)m")
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section {
                        Button { innerSheet = .addInterval } label: {
                            Label("Add Interval", systemImage: "plus.circle.fill")
                                .foregroundStyle(Color.green)
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button {
                            if canAddRest { innerSheet = .addRest }
                        } label: {
                            Label("Add Rest", systemImage: "timer")
                                .foregroundStyle(canAddRest ? Color.orange : Color.gray)
                        }
                        .listRowBackground(Color(white: 0.12))
                    }
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $innerEditMode)
            }
            .navigationTitle(existing == nil ? "Add Loop" : "Edit Loop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.gray)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(existing == nil ? "Add" : "Save") {
                        onSave(.loop(items: loopItems, count: repeatCount))
                        dismiss()
                    }
                    .foregroundStyle(Color.cyan)
                    .disabled(loopItems.filter { $0.isInterval }.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(innerEditMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { innerEditMode = innerEditMode.isEditing ? .inactive : .active }
                    }
                    .foregroundStyle(innerEditMode.isEditing ? Color.white : Color.gray)
                }
            }
            .sheet(item: $innerSheet) { target in
                switch target {
                case .addInterval:
                    IntervalEditorView(existing: nil) { loopItems.append($0) }
                case .addRest:
                    RestEditorView(existing: nil) { loopItems.append($0) }
                case .editInterval(let idx):
                    IntervalEditorView(existing: loopItems[idx]) { loopItems[idx] = $0 }
                case .editRest(let idx):
                    RestEditorView(existing: loopItems[idx]) { loopItems[idx] = $0 }
                }
            }
        }
    }
}

#Preview {
    WorkoutEditorView(existing: nil) { _ in }
}
