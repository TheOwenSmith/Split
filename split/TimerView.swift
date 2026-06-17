import SwiftUI

// MARK: - Shared debug console (used by both TimerView and WorkoutsView)

struct DebugConsoleView: View {
    var vm: SpeechTimerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DEBUG LOG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.yellow)
                    Text("state: \(vm.debugStateString)  •  mic: \(vm.isMuted ? "MUTED" : vm.isListening ? "ON" : "starting")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(vm.isMuted ? .red : vm.isListening ? Color.green : Color.gray)
                }
                Spacer()
                Button { vm.debugLog.removeAll() } label: {
                    Text("CLEAR")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.gray)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.yellow.opacity(0.08))

            Divider().background(Color.yellow.opacity(0.3))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.debugLog.enumerated()), id: \.offset) { i, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(entryColor(entry))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: vm.debugLog.count) {
                    if let last = vm.debugLog.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .frame(height: 200)
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func entryColor(_ entry: String) -> Color {
        if entry.contains("Mic error") || entry.contains("failed") || entry.contains("denied") { return .red }
        if entry.contains("Command:") && entry.contains("accepted") { return .green }
        if entry.contains("Command:") { return Color(white: 0.45) }
        if entry.contains("Heard:") { return .cyan }
        if entry.contains("Speaking:") { return .orange }
        if entry.contains("Manual:") { return .yellow }
        return Color(white: 0.5)
    }
}

// MARK: - Shared debug toggle button style

struct DebugToggleButton: View {
    var vm: SpeechTimerViewModel
    var body: some View {
        Button { vm.showDebug.toggle() } label: {
            Text(vm.showDebug ? "HIDE LOG" : "DEBUG")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(vm.showDebug ? Color.yellow : Color.gray)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Timer view

struct TimerView: View {
    var vm: SpeechTimerViewModel
    @State private var showCancelConfirm = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                timerDisplay
                restStateLabel
                feedbackLabel
                micToggleButton
                Spacer()
                if !vm.splits.isEmpty { splitsSection }
                commandHints.padding(.bottom, 12)
                if vm.showDebug { DebugConsoleView(vm: vm) }
            }

            if vm.showMutedWarning {
                mutedWarningBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: vm.showMutedWarning)
                    .padding(.top, 100)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        // Fixed-height HStack prevents the gear icon from shifting when
        // the taller CANCEL WORKOUT button appears/disappears.
        HStack(alignment: .center, spacing: 10) {
            DebugToggleButton(vm: vm)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.gray)
            }
            .sheet(isPresented: $showSettings) { settingsSheet }

            Spacer()

            if vm.activeWorkout != nil && (vm.appState == .running || vm.appState == .resting) {
                Button { showCancelConfirm = true } label: {
                    Text("CANCEL WORKOUT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                }
                .alert("Cancel Workout?", isPresented: $showCancelConfirm) {
                    Button("Cancel Workout", role: .destructive) { vm.cancelWorkoutFromUI() }
                    Button("Keep Going", role: .cancel) {}
                } message: {
                    Text("This will end your current workout and read your splits aloud.")
                }
            }
        }
        .frame(height: 44)   // locked height — nothing shifts when CANCEL appears
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section {
                        Toggle(isOn: Binding(
                            get: { vm.skipConfirmationEnabled },
                            set: { vm.skipConfirmationEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Verbal skip confirmation")
                                    .foregroundStyle(Color.white)
                                Text("Says \"Skipping.\" aloud when rest is skipped")
                                    .font(.caption)
                                    .foregroundStyle(Color.gray)
                            }
                        }
                        .tint(Color.green)
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Timer display

    private var timerDisplay: some View {
        Text(vm.displayTime)
            .font(.system(size: 76, weight: .thin, design: .monospaced))
            .foregroundStyle(timerColor)
            .minimumScaleFactor(0.45)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private var restStateLabel: some View {
        Group {
            if vm.appState == .resting {
                HStack(spacing: 6) {
                    Text(vm.restIsPaused ? "PAUSED" : "REST")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(vm.restIsPaused ? Color.yellow : Color.orange)
                }
                .padding(.top, 4)
            }
        }
    }

    private var feedbackLabel: some View {
        Text(vm.statusText)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(vm.splitFlash ? Color.yellow : Color.gray)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .animation(.easeInOut(duration: 0.25), value: vm.splitFlash)
    }

    // MARK: - Mic toggle

    private var micToggleButton: some View {
        Button(action: { vm.toggleMute() }) {
            HStack(spacing: 10) {
                Image(systemName: vm.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(vm.isMuted ? "MUTED — tap to unmute" : "MIC ON — tap to mute")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(vm.isMuted ? Color.red : Color.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(vm.isMuted ? Color.red.opacity(0.12) : Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(vm.isMuted ? Color.red.opacity(0.4) : Color.green.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - Splits list

    private var splitsSection: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.12))
                .padding(.horizontal, 20).padding(.top, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.splits.reversed()) { split in
                        HStack(spacing: 12) {
                            Text(split.distanceLabel)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(Color.gray)
                                .frame(width: 64, alignment: .leading)

                            Text(vm.formatTime(split.lapTime))
                                .font(.system(.title3, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let goal = split.goalSeconds {
                                let diff = split.lapTime - goal
                                Text(diffLabel(diff))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(diffColor(diff))
                            } else {
                                Text(vm.formatTime(split.totalTime))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(Color.gray)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 9)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 200)
        }
    }

    private func diffLabel(_ diff: TimeInterval) -> String {
        if abs(diff) <= 0.5 { return "on pace" }
        let a = String(format: "%.1f", abs(diff))
        return diff < 0 ? "\(a)s hot" : "+\(a)s"
    }

    private func diffColor(_ diff: TimeInterval) -> Color {
        abs(diff) <= 0.5 ? .green : (diff < 0 ? .cyan : .orange)
    }

    // MARK: - Command hints

    private var commandHints: some View {
        Group {
            if vm.appState == .resting {
                HStack(spacing: 12) {
                    hintButton("SKIP", color: .orange) { vm.skipRest() }
                    hintButton(vm.restIsPaused ? "RESUME" : "PAUSE", color: .yellow) { vm.togglePauseRest() }
                }
            } else {
                HStack(spacing: 12) {
                    hint("START", active: vm.appState == .idle || vm.appState == .finished)
                    if vm.activeWorkout != nil {
                        hint("SPLIT*", active: vm.appState == .running)
                        hint("STOP",   active: vm.appState == .running)
                    } else {
                        hint("SPLIT", active: vm.appState == .running)
                        hint("STOP",  active: vm.appState == .running)
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func hint(_ label: String, active: Bool) -> some View {
        Button {
            let cmd = label.replacingOccurrences(of: "*", with: "")
                .lowercased()
            vm.debugTrigger(cmd)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.18))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(active ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .animation(.easeInOut(duration: 0.2), value: active)
        }
        .disabled(!active)
    }

    private func hintButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: - Muted warning banner

    private var mutedWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(Color.white)
            Text("MIC MUTED — 15 sec until next rep")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .padding(.horizontal, 20)
    }

    private var timerColor: Color {
        switch vm.appState {
        case .idle:     return .gray
        case .running:  return .green
        case .resting:  return vm.restIsPaused ? .yellow : .orange
        case .finished: return .white
        }
    }
}

#Preview {
    TimerView(vm: SpeechTimerViewModel())
}
