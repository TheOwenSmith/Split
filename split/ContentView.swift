import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var vm = SpeechTimerViewModel()
    @Environment(WorkoutStore.self) var store

    // Derived: show headphones cover when check is done and no headphones found.
    private var showHeadphonesCover: Bool {
        vm.headphonesCheckDone && !vm.headphonesConnected && !vm.headphonesIgnored
    }

    // Only show the voice alert AFTER the headphones situation is resolved,
    // so both presentations never try to appear simultaneously.
    private var showVoiceAlert: Bool {
        vm.needsBetterVoice && vm.headphonesCheckDone && (vm.headphonesConnected || vm.headphonesIgnored)
    }

    var body: some View {
        TabView {
            TimerView(vm: vm)
                .tabItem { Label("Timer", systemImage: "stopwatch") }

            WorkoutsView(vm: vm)
                .tabItem { Label("Workouts", systemImage: "list.bullet.clipboard") }
        }
        .preferredColorScheme(.dark)
        .onAppear { vm.startListening() }
        // fullScreenCover is applied first so it takes presentation priority over the alert.
        .fullScreenCover(isPresented: Binding(
            get: { showHeadphonesCover },
            set: { _ in }
        )) {
            HeadphonesWarningView(vm: vm)
        }
        .alert("Download a Better Voice", isPresented: Binding(
            get: { showVoiceAlert },
            set: { if !$0 { vm.dismissVoiceAlert() } }
        )) {
            Button("Open Settings") {
                let url = URL(string: "App-prefs:ACCESSIBILITY") ?? URL(string: UIApplication.openSettingsURLString)
                if let url { UIApplication.shared.open(url) }
                vm.dismissVoiceAlert()
            }
            Button("Dismiss", role: .cancel) { vm.dismissVoiceAlert() }
        } message: {
            Text("Split times will sound robotic with the default voice.\n\nTo fix: Settings → Accessibility → Spoken Content → Voices → English (United States) → tap Aaron or Nolan, then ⬇ to download.\n\nReopen the app once the download completes.")
        }
    }
}

struct HeadphonesWarningView: View {
    var vm: SpeechTimerViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "airpodspro")
                    .font(.system(size: 80))
                    .foregroundStyle(Color(white: 0.35))

                VStack(spacing: 10) {
                    Text("No AirPods Detected")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text("This app is designed to be used with AirPods or headphones so you can hear split times hands-free while running.")
                        .font(.subheadline)
                        .foregroundStyle(Color.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Text("Connect your AirPods now and this screen will disappear automatically.")
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                Spacer()

                Button {
                    vm.ignoreHeadphonesWarning()
                } label: {
                    Text("Continue Without AirPods")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color(white: 0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(WorkoutStore())
}
