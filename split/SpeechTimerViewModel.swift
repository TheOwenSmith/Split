import Foundation
import Observation
import Speech
import AVFoundation
import AudioToolbox

private class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    // No longer responsible for restarting recognition — mic stays on continuously.
}

// Little-endian append helper for WAV generation
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}

@Observable
class SpeechTimerViewModel {

    enum AppState { case idle, running, resting, finished }

    struct SplitRecord: Identifiable {
        let id: Int
        let lapTime: TimeInterval
        let totalTime: TimeInterval
        let distanceLabel: String
        let goalSeconds: TimeInterval?
    }

    // MARK: - Published state
    var appState: AppState = .idle
    var displayTime: String = "0:00.00"
    var splits: [SplitRecord] = []
    var statusText: String = "Say \"start\" to begin"
    var isListening: Bool = false
    var isMuted: Bool = false
    var splitFlash: Bool = false
    var debugLog: [String] = []
    var showMutedWarning: Bool = false
    var needsBetterVoice: Bool = false
    var showDebug: Bool = false
    var headphonesConnected: Bool = false
    var headphonesIgnored: Bool = false
    var headphonesCheckDone: Bool = false
    var skipConfirmationEnabled: Bool = UserDefaults.standard.bool(forKey: "skipConfirmationEnabled") {
        didSet { UserDefaults.standard.set(skipConfirmationEnabled, forKey: "skipConfirmationEnabled") }
    }

    // Workout mode
    var activeWorkout: Workout? = nil
    var currentItemIndex: Int = 0
    var restTimeRemaining: TimeInterval = 0
    var restIsPaused: Bool = false

    // Expanded flat item list set when a workout starts (loops unrolled).
    private var workoutItems: [WorkoutItem] = []

    // MARK: - Private state
    private var startDate: Date?
    private var lastSplitDate: Date?
    private var restStartDate: Date?
    private var stoppedElapsed: TimeInterval = 0
    private var displayTimer: Timer?
    private var restTimer: Timer?
    private var restartTimer: Timer?
    private var hasStarted = false
    private var hasAudioSessionStarted = false
    private var recognitionGeneration = 0
    private var restGeneration = 0

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let synthDelegate = SpeechSynthesizerDelegate()

    @ObservationIgnored private var maleVoice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var goBeepPlayer: AVAudioPlayer?
    @ObservationIgnored private var countdownBeepPlayer: AVAudioPlayer?
    @ObservationIgnored private var voiceChangeToken: NSObjectProtocol?
    @ObservationIgnored private var routeChangeToken: NSObjectProtocol?
    @ObservationIgnored private var engineConfigToken: NSObjectProtocol?
    @ObservationIgnored private var interruptionToken: NSObjectProtocol?

    // Ordered by preference: premium Nolan, premium Aaron, then enhanced fallbacks.
    private static let voiceIdentifiers = [
        "com.apple.voice.premium.en-US.Nolan",
        "com.apple.voice.premium.en-US.Aaron",
        "com.apple.voice.enhanced.en-US.Nolan",
        "com.apple.voice.enhanced.en-US.Aaron",
        "com.apple.voice.premium.en-US.Rishi",
    ]

    init() {
        maleVoice = Self.pickBestVoice()

        // Build beep players from synthesized PCM audio (plays through AirPods via AVAudioSession).
        // Both start and rest-end use the same go-beep; countdown uses a softer tick.
        let goData = Self.makeToneData(hz: 880, seconds: 0.2, amp: 0.75)
        goBeepPlayer = try? AVAudioPlayer(data: goData)
        goBeepPlayer?.prepareToPlay()

        let tickData = Self.makeToneData(hz: 660, seconds: 0.07, amp: 0.5)
        countdownBeepPlayer = try? AVAudioPlayer(data: tickData)
        countdownBeepPlayer?.prepareToPlay()

        synthesizer.delegate = synthDelegate

        // Show voice alert if no enhanced/premium voice is installed.
        needsBetterVoice = maleVoice == nil || maleVoice?.quality == .default

        // Re-check whenever the user downloads a voice in Settings.
        voiceChangeToken = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.recheckVoice() }

        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.checkAudioRoute() }
        // Route is checked after audio session is configured (in requestAndStart),
        // because the BT route isn't visible until .allowBluetooth is applied.

        // When the hardware sample rate changes (e.g. AirPods connect/disconnect),
        // CoreAudio stops the engine and fires this notification. Restart mic with the new format.
        engineConfigToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.hasAudioSessionStarted, !self.isMuted else { return }
            self.log("Engine config changed — restarting mic with new format")
            self.beginRecognition()
        }

        // Handle audio session interruptions (phone calls, Siri, phone lock transitions).
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            switch type {
            case .began:
                self.log("Audio session interrupted")
                if self.audioEngine.isRunning { self.audioEngine.stop() }
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.isListening = false
            case .ended:
                self.log("Audio session interruption ended — resuming mic")
                try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                if !self.isMuted && self.hasAudioSessionStarted { self.beginRecognition() }
            @unknown default: break
            }
        }
    }

    deinit {
        if let token = voiceChangeToken   { NotificationCenter.default.removeObserver(token) }
        if let token = routeChangeToken   { NotificationCenter.default.removeObserver(token) }
        if let token = engineConfigToken  { NotificationCenter.default.removeObserver(token) }
        if let token = interruptionToken  { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - WAV tone generator

    private static func makeToneData(hz: Double, seconds: Double, amp: Float) -> Data {
        let rate = 44100
        let frames = Int(Double(rate) * seconds)
        let fade = max(1, Int(Double(rate) * 0.012))
        var wav = Data(capacity: 44 + frames * 2)

        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(frames * 2 + 36))
        wav.append(contentsOf: "WAVE".utf8)

        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))            // PCM
        wav.appendLE(UInt16(1))            // mono
        wav.appendLE(UInt32(rate))
        wav.appendLE(UInt32(rate * 2))     // byte rate
        wav.appendLE(UInt16(2))            // block align
        wav.appendLE(UInt16(16))           // bits per sample

        wav.append(contentsOf: "data".utf8)
        wav.appendLE(UInt32(frames * 2))

        for i in 0..<frames {
            var e: Double = 1.0
            if i < fade { e = Double(i) / Double(fade) }
            else if i > frames - fade { e = Double(frames - i) / Double(fade) }
            let s = sin(2 * .pi * hz * Double(i) / Double(rate)) * Double(amp) * e
            let clamped = max(-32767, min(32767, Int(s * 32767)))
            wav.appendLE(Int16(clamped))
        }
        return wav
    }

    // MARK: - Voice helpers

    private static func pickBestVoice() -> AVSpeechSynthesisVoice? {
        voiceIdentifiers.compactMap { AVSpeechSynthesisVoice(identifier: $0) }.first
            ?? AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en-US") && $0.gender == .male && $0.quality != .default }
                .max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en-US") && $0.gender == .male }
                .max(by: { $0.quality.rawValue < $1.quality.rawValue })
    }

    private func recheckVoice() {
        let updated = Self.pickBestVoice()
        maleVoice = updated
        needsBetterVoice = updated == nil || updated?.quality == .default
    }

    func dismissVoiceAlert() {
        needsBetterVoice = false
    }

    func ignoreHeadphonesWarning() {
        headphonesIgnored = true
    }

    private func checkAudioRoute() {
        #if targetEnvironment(simulator)
        headphonesConnected = true
        headphonesCheckDone = true
        return
        #endif
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let connectedTypes: [AVAudioSession.Port] = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones
        ]
        headphonesConnected = outputs.contains { connectedTypes.contains($0.portType) }
        headphonesCheckDone = true
    }

    // MARK: - Public API

    func setWorkout(_ workout: Workout?) {
        guard appState == .idle || appState == .finished else { return }
        activeWorkout = workout
        currentItemIndex = 0
        statusText = workout.map { "Workout: \($0.name) — say \"start\"" } ?? "Say \"start\" to begin"
    }

    /// Silently abort a workout in progress (no TTS summary). Used when switching workouts.
    func abortWorkout() {
        cancelRest()
        displayTimer?.invalidate()
        displayTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        appState = .idle
        splits = []
        startDate = nil
        lastSplitDate = nil
        stoppedElapsed = 0
        currentItemIndex = 0
        workoutItems = []
        displayTime = "0:00.00"
        statusText = activeWorkout.map { "Workout: \($0.name) — say \"start\"" } ?? "Say \"start\" to begin"
    }

    func debugTrigger(_ command: String) {
        log("Manual: \(command)")
        processWord(command)
    }

    func startListening() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await requestAndStart() }
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            stopAllAudio()
            log("Mic muted")
        } else if hasAudioSessionStarted {
            beginRecognition()
            log("Mic unmuted")
        }
    }

    func skipRest() {
        guard appState == .resting else { return }
        log("Skip rest")
        cancelRest()
        if skipConfirmationEnabled { speakNow("Skipping.") }
        restEnded()
    }

    func togglePauseRest() {
        guard appState == .resting else { return }
        if restIsPaused {
            restIsPaused = false
            restStartDate = Date()
            let remaining = restTimeRemaining
            log("Rest resumed — \(String(format: "%.1f", remaining))s remaining")
            playGoBeep()
            scheduleRestWarningsAndBeeps(remaining: remaining)
            restTimer?.invalidate()
            // Only include thresholds that haven't fired yet (strictly less than remaining).
            var beepThresholds = [3.0, 2.0, 1.0].filter { $0 < remaining }
            restTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.appState == .resting, !self.restIsPaused,
                      let start = self.restStartDate else { return }
                let rem = max(0, remaining - Date().timeIntervalSince(start))
                self.restTimeRemaining = rem
                self.displayTime = self.formatTime(rem)
                while let threshold = beepThresholds.first, rem <= threshold {
                    beepThresholds.removeFirst()
                    self.playCountdownBeep()
                }
                if rem <= 0 { self.restEnded() }
            }
        } else {
            restIsPaused = true
            restGeneration += 1
            restTimer?.invalidate()
            restTimer = nil
            log("Rest paused at \(String(format: "%.1f", restTimeRemaining))s")
            speakNow("Paused.")
        }
    }

    func cancelWorkoutFromUI() {
        cancelRest()
        guard let start = startDate else {
            appState = .idle
            currentItemIndex = 0
            statusText = activeWorkout.map { "Workout: \($0.name) — say \"start\"" } ?? "Say \"start\" to begin"
            return
        }
        stoppedElapsed = Date().timeIntervalSince(start)
        appState = .finished
        displayTimer?.invalidate()
        displayTimer = nil
        refreshDisplayTime()
        statusText = "Cancelled"

        guard !splits.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speakNow("Workout cancelled. Completed \(splits.count) of \(workoutItems.filter { $0.isInterval }.count) reps.")
        for split in splits {
            speakQueued("\(split.distanceLabel): \(timeToSpeech(split.lapTime))", delay: 0.35)
        }
    }

    var debugStateString: String {
        switch appState {
        case .idle:     return "idle"
        case .running:  return "running"
        case .resting:  return restIsPaused ? "paused" : "resting"
        case .finished: return "finished"
        }
    }

    // MARK: - Debug logging

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        let entry = "[\(formatter.string(from: Date()))] \(message)"
        debugLog.append(entry)
        if debugLog.count > 60 { debugLog.removeFirst() }
        print("[SPLIT] \(entry)")
    }

    // MARK: - Setup

    private func requestAndStart() async {
        log("Requesting speech permission...")
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            log("Permission denied")
            statusText = "Speech recognition denied — enable in Settings"
            return
        }
        log("Permission granted")

        do {
            let session = AVAudioSession.sharedInstance()
            #if targetEnvironment(simulator)
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            #else
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            #endif
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            hasAudioSessionStarted = true
            checkAudioRoute()
            log("Audio session ready")
        } catch {
            log("Audio session failed: \(error.localizedDescription)")
            statusText = "Audio setup failed: \(error.localizedDescription)"
            return
        }
        beginRecognition()
    }

    // MARK: - Recognition lifecycle

    private func beginRecognition() {
        guard !isMuted else { return }

        recognitionGeneration += 1
        restartTimer?.invalidate(); restartTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionRequest?.endAudio(); recognitionRequest = nil

        // Always stop the engine before removing the tap. If we leave it running and the
        // hardware sample rate has changed (e.g. AirPods just connected), outputFormat() will
        // still return the old rate and installTap will throw the sampleRate mismatch exception.
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false

        let gen = recognitionGeneration
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        recognitionRequest = req

        // Reactivate the session in case it was deactivated by a lock/interruption.
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        // prepare() forces CoreAudio to re-query hardware; outputFormat reflects the new sample rate.
        // If the session is still mid-transition, sampleRate can be 0 — installTap raises an
        // uncatchable NSException in that case. Guard against it and retry after a delay.
        audioEngine.prepare()
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            log("Mic format invalid (0 Hz) — retrying in 1s")
            recognitionRequest?.endAudio(); recognitionRequest = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.recognitionGeneration == gen, !self.isMuted else { return }
                self.beginRecognition()
            }
            return
        }
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [req] buf, _ in
            req.append(buf)
        }
        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            log("Mic start failed: \(error.localizedDescription) — retrying in 1s")
            recognitionRequest?.endAudio(); recognitionRequest = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.recognitionGeneration == gen, !self.isMuted else { return }
                self.beginRecognition()
            }
            return
        }
        isListening = true

        var seenWordCount = 0
        recognitionTask = speechRecognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == gen else { return }
                if let result {
                    let words = result.bestTranscription.formattedString.lowercased()
                        .split(separator: " ").map(String.init)
                    if words.count > seenWordCount {
                        let newWords = Array(words[seenWordCount...])
                        self.log("Heard: \"\(newWords.joined(separator: " "))\"")
                        for word in newWords { self.processWord(word) }
                        seenWordCount = words.count
                    }
                }
                if let error {
                    let isSilence = error.localizedDescription.contains("No speech detected")
                    if !isSilence { self.log("Mic error: \(error.localizedDescription)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.recognitionGeneration == gen else { return }
                        self.beginRecognition()
                    }
                }
            }
        }

        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == gen else { return }
                self.beginRecognition()
            }
        }
    }

    /// Full stop — only called when the user explicitly mutes.
    private func stopAllAudio() {
        recognitionGeneration += 1
        restartTimer?.invalidate(); restartTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionRequest?.endAudio(); recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)   // safe: engine is stopped above
        isListening = false
    }

    // MARK: - Command processing

    private func processWord(_ word: String) {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        switch w {
        case "start":
            if appState == .resting {
                log("Command: START (skip rest)")
                skipRest()
            } else if appState != .running {
                log("Command: START (accepted)")
                handleStart()
            }
        case "split", "spit":
            if appState == .running {
                if activeWorkout != nil {
                    log("Command: SPLIT (mid-rep check)")
                    handleMidRepCheck()
                } else {
                    log("Command: SPLIT (freestyle lap)")
                    handleFreestyleLap()
                }
            }
        case "stop":
            if appState == .running {
                if activeWorkout != nil {
                    log("Command: STOP (rep end)")
                    handleRepEnd()
                } else {
                    log("Command: STOP (freestyle end)")
                    handleEndTimer()
                }
            } else if appState == .resting {
                log("Command: STOP (pause/resume rest)")
                togglePauseRest()
            }
        case "skip":
            if appState == .resting { log("Command: SKIP"); skipRest() }
        case "pause", "resume", "unpause":
            if appState == .resting { log("Command: PAUSE/RESUME"); togglePauseRest() }
        default:
            break
        }
    }

    // MARK: - Timer commands

    private func handleStart() {
        let now = Date()
        startDate = now
        lastSplitDate = now
        splits = []
        stoppedElapsed = 0
        currentItemIndex = 0
        workoutItems = activeWorkout?.expandedItems ?? []
        appState = .running
        updateStatusForCurrentItem()

        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            self?.refreshDisplayTime()
        }
        playGoBeep()
    }

    private func handleRepEnd() {
        guard let start = startDate, let lastSplit = lastSplitDate else { return }
        let now = Date()
        let lapTime = now.timeIntervalSince(lastSplit)
        let totalTime = now.timeIntervalSince(start)
        lastSplitDate = now

        let currentItem = workoutItems[safe: currentItemIndex]
        let distanceLabel = currentItem?.distanceLabel ?? "Rep \(splits.count + 1)"
        let goalSeconds = currentItem?.goalSeconds

        splits.append(SplitRecord(id: splits.count + 1, lapTime: lapTime, totalTime: totalTime,
                                  distanceLabel: distanceLabel, goalSeconds: goalSeconds))
        statusText = "\(distanceLabel): \(formatTime(lapTime))"
        flashSplit()

        var announcement: String
        if let item = currentItem {
            announcement = "\(item.spokenDistance): \(timeToSpeech(lapTime))"
            if let goal = goalSeconds { announcement += ". \(paceComment(lap: lapTime, goal: goal))" }
        } else {
            announcement = timeToSpeech(lapTime)
        }

        currentItemIndex += 1

        if let next = workoutItems[safe: currentItemIndex], next.isRest {
            currentItemIndex += 1
            speakNow(announcement)
            beginRest(duration: next.restSeconds)
        } else if workoutItems[safe: currentItemIndex] != nil {
            speakNow(announcement)
            updateStatusForCurrentItem()
        } else {
            finishWorkout(afterAnnouncement: announcement)
        }
    }

    private func handleMidRepCheck() {
        guard let lastSplit = lastSplitDate else { return }
        let elapsed = Date().timeIntervalSince(lastSplit)
        let currentItem = workoutItems[safe: currentItemIndex]
        let announcement: String
        if let item = currentItem {
            announcement = "\(timeToSpeech(elapsed)) into your \(item.spokenDistance)"
        } else {
            announcement = timeToSpeech(elapsed)
        }
        statusText = "Check: \(formatTime(elapsed))"
        flashSplit()
        speakNow(announcement)
    }

    private func handleFreestyleLap() {
        guard let start = startDate, let lastSplit = lastSplitDate else { return }
        let now = Date()
        let lapTime = now.timeIntervalSince(lastSplit)
        let totalTime = now.timeIntervalSince(start)
        lastSplitDate = now
        let lap = splits.count + 1
        splits.append(SplitRecord(id: lap, lapTime: lapTime, totalTime: totalTime,
                                  distanceLabel: "Lap \(lap)", goalSeconds: nil))
        statusText = "Lap \(lap): \(formatTime(lapTime))"
        flashSplit()
        speakNow(timeToSpeech(lapTime))
    }

    private func handleEndTimer() {
        guard let start = startDate else { return }
        stoppedElapsed = Date().timeIntervalSince(start)
        appState = .finished
        displayTimer?.invalidate(); displayTimer = nil
        refreshDisplayTime()
        statusText = "Finished — say \"start\" to run again"
        synthesizer.stopSpeaking(at: .immediate)
        speakNow("Stopped at \(timeToSpeech(stoppedElapsed)).")
        for split in splits {
            speakQueued("\(split.distanceLabel): \(timeToSpeech(split.lapTime))", delay: 0.35)
        }
    }

    private func finishWorkout(afterAnnouncement announcement: String) {
        guard let start = startDate else { return }
        stoppedElapsed = Date().timeIntervalSince(start)
        appState = .finished
        displayTimer?.invalidate(); displayTimer = nil
        refreshDisplayTime()

        let name = activeWorkout?.name ?? "Workout"
        statusText = "\(name) complete!"
        synthesizer.stopSpeaking(at: .immediate)

        if !announcement.isEmpty { speakNow(announcement) }
        speakQueued("\(name) complete. Total time: \(timeToSpeech(stoppedElapsed)).", delay: 0.4)
        for split in splits {
            speakQueued("\(split.distanceLabel): \(timeToSpeech(split.lapTime))", delay: 0.35)
        }
    }

    // MARK: - Rest

    private func beginRest(duration: TimeInterval) {
        restGeneration += 1
        let gen = restGeneration
        appState = .resting
        restTimeRemaining = duration
        restIsPaused = false
        restStartDate = Date()

        let mins = Int(duration) / 60, secs = Int(duration) % 60
        let restMsg = mins > 0 && secs > 0 ? "\(mins) minute \(secs) second rest"
                    : mins > 0              ? "\(mins) minute rest"
                    : "\(secs) second rest"

        speakQueued(restMsg, delay: 0.3)

        scheduleRestWarningsAndBeeps(remaining: duration)

        restTimer?.invalidate()
        // Fire beeps when remaining crosses below each threshold. Threshold-crossing (not
        // integer-floor) guarantees the 1.0 beep fires even if a 0.1s tick happens to land at
        // remaining=0.95 and skips the 1.0 mark entirely.
        var beepThresholds = [3.0, 2.0, 1.0]
        restTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.appState == .resting, !self.restIsPaused,
                  let start = self.restStartDate, self.restGeneration == gen else { return }
            let remaining = max(0, duration - Date().timeIntervalSince(start))
            self.restTimeRemaining = remaining
            self.displayTime = self.formatTime(remaining)
            while let threshold = beepThresholds.first, remaining <= threshold {
                beepThresholds.removeFirst()
                self.playCountdownBeep()
            }
            if remaining <= 0 { self.restEnded() }
        }

        if let next = workoutItems[safe: currentItemIndex], next.isInterval {
            statusText = "Rest — next: \(next.distanceLabel) @ \(next.goalFormatted)"
        } else {
            statusText = "Rest — say \"skip\" to skip"
        }
    }

    private func scheduleRestWarningsAndBeeps(remaining: TimeInterval) {
        let gen = restGeneration

        func guard_(_ block: @escaping () -> Void) -> () -> Void {
            { [weak self] in
                guard let self, self.restGeneration == gen,
                      self.appState == .resting, !self.restIsPaused else { return }
                block()
            }
        }

        if remaining > 75 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (remaining - 60), execute: guard_({
                self.fireWarning("One minute remaining")
            }))
        }

        if remaining > 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (remaining - 15), execute: guard_({
                if self.isMuted {
                    self.showMutedWarning = true
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.showMutedWarning = false
                    }
                } else {
                    self.fireWarning("15 seconds")
                }
            }))
        }

        // Countdown beeps are driven by restTimer for consistent 4-3-2-1 cadence.
    }

    private func fireWarning(_ text: String) {
        log("Rest warning: \(text)")
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = maleVoice; u.rate = 0.53; u.volume = 1.0
        synthesizer.speak(u)
    }

    private func restEnded() {
        cancelRest()
        guard workoutItems[safe: currentItemIndex] != nil else {
            finishWorkout(afterAnnouncement: "")
            return
        }
        appState = .running
        displayTime = "0:00.00"
        lastSplitDate = Date()
        updateStatusForCurrentItem()
        playGoBeep()
    }

    private func cancelRest() {
        restGeneration += 1
        restTimer?.invalidate(); restTimer = nil
        restStartDate = nil
        restIsPaused = false
    }

    // MARK: - Status

    private func updateStatusForCurrentItem() {
        if let item = workoutItems[safe: currentItemIndex], item.isInterval {
            statusText = "\(item.distanceLabel) — goal \(item.goalFormatted)"
        } else if activeWorkout != nil {
            statusText = "Say \"stop\" to finish rep"
        } else {
            statusText = "Running — say \"split\" or \"stop\""
        }
    }

    // MARK: - TTS helpers

    /// Interrupt any queued TTS and speak immediately; mic stays running.
    private func speakNow(_ text: String) {
        log("Speaking: \"\(text)\"")
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = maleVoice; u.rate = 0.53; u.volume = 1.0
        synthesizer.speak(u)
    }

    /// Queue an additional utterance after speakNow (or another queued one).
    private func speakQueued(_ text: String, delay: TimeInterval = 0) {
        let u = AVSpeechUtterance(string: text)
        u.voice = maleVoice; u.rate = 0.53; u.volume = 1.0; u.preUtteranceDelay = delay
        synthesizer.speak(u)
    }

    // MARK: - Audio beeps

    private func playGoBeep() {
        goBeepPlayer?.currentTime = 0
        goBeepPlayer?.play()
    }

    private func playCountdownBeep() {
        countdownBeepPlayer?.currentTime = 0
        countdownBeepPlayer?.play()
    }

    // MARK: - Pace feedback

    private func paceComment(lap: TimeInterval, goal: TimeInterval) -> String {
        let diff = lap - goal
        let abs = Swift.abs(diff)
        if abs <= 0.5 { return "right on pace" }
        let ds = String(format: "%.1f", abs)
        if diff < 0 { return abs < 1.0 ? "just a hair hot" : "about \(ds) seconds hot" }
        return abs < 1.0 ? "just a tick slow" : "about \(ds) seconds slow"
    }

    // MARK: - Display

    private func flashSplit() {
        splitFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.splitFlash = false }
    }

    private func refreshDisplayTime() {
        guard appState == .running else { return }
        // Workout mode: show elapsed time for the current rep only (resets each rep).
        // Freestyle mode: show cumulative elapsed time from start.
        if activeWorkout != nil {
            guard let repStart = lastSplitDate else { return }
            displayTime = formatTime(Date().timeIntervalSince(repStart))
        } else {
            guard let start = startDate else { return }
            displayTime = formatTime(Date().timeIntervalSince(start))
        }
    }

    func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        let h = Int((t * 100).truncatingRemainder(dividingBy: 100))
        return String(format: "%d:%02d.%02d", m, s, h)
    }

    private func timeToSpeech(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        // Truncate to one decimal place (floor) so 56.27 → "56.2", never rounds up to 56.3.
        let s = floor(t.truncatingRemainder(dividingBy: 60) * 10.0) / 10.0
        if m > 0 { return "\(m) minute\(m == 1 ? "" : "s") \(String(format: "%.1f", s)) seconds" }
        return "\(String(format: "%.1f", s)) seconds"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
