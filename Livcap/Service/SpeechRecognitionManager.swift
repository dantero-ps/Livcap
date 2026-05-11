//
//  SpeechRecognitionManager.swift
//  Livcap
//
//  Created by Rongwei Ji on 6/24/25.
//

import Foundation
import Speech
import AVFoundation
import Combine
import Translation
import os.log

// MARK: - Speech Events

enum SpeechEvent: Sendable {
    case transcriptionUpdate(String)
    case sentenceFinalized(String)
    case statusChanged(String)
    case error(Error)
}

// MARK: - SpeechRecognitionManager

final class SpeechRecognitionManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var isRecording = false
    @Published var currentTranscription: String = ""
    @Published var currentTranslation: String = ""
    @Published var captionHistory: [CaptionEntry] = []
    @Published var statusText: String = "Ready to record"
    
    // MARK: - Private Properties
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    // Text processing state
    private var processedTextLength: Int = 0
    private var fullTranscriptionText: String = ""
    
    // Frame-based silence detection
    private var consecutiveSilenceFrames: Int = 0
    private let silenceFrameThreshold: Int = 10  // ~2 seconds (20 frames × 100ms)
    private var currentSpeechState: Bool = false
    
    // AsyncStream for events
    private var speechEventsContinuation: AsyncStream<SpeechEvent>.Continuation?
    private var speechEventsStream: AsyncStream<SpeechEvent>?
    
    // Translation
    var translationService: TranslationService?
    private var liveTranslationTask: Task<Void, Never>?

    // Logging
    private var isLoggerOn: Bool = false // change to true for debugging
    private let logger = Logger(subsystem: "com.livcap.speech", category: "SpeechRecognitionManager")

    // Session rotation
    private var sessionStartTime: Date?
    private var sessionRotationTask: Task<Void, Never>?
    private let maxTaskDuration: TimeInterval = 300 // seconds (5 minutes)
    
    // MARK: - Initialization
    
    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        setupSpeechRecognition()
    }
    
    deinit {
        stopRecording()
        speechEventsContinuation?.finish()
    }
    
    // MARK: - AsyncStream Interface
    
    func speechEvents() -> AsyncStream<SpeechEvent> {
        if let stream = speechEventsStream {
            return stream
        }
        
        speechEventsStream = AsyncStream { continuation in
            self.speechEventsContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.logger.info("🛑 Speech events stream terminated")
            }
        }
        
        return speechEventsStream!
    }
    
    // MARK: - Setup
    
    private func setupSpeechRecognition() {
        // Request authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            
            Task { @MainActor in
                let status: String
                switch authStatus {
                case .authorized:
                    status = "Ready to record"
                case .denied:
                    status = "Speech recognition permission denied"
                case .restricted:
                    status = "Speech recognition restricted"
                case .notDetermined:
                    status = "Speech recognition not determined"
                @unknown default:
                    status = "Speech recognition authorization unknown"
                }
                
                self.statusText = status
                self.speechEventsContinuation?.yield(.statusChanged(status))
            }
        }
    }
    
    // MARK: - Public Interface
    
    func startRecording() async throws {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            let error = SpeechRecognitionError.recognizerNotAvailable
            await updateStatus("Speech recognizer not available")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let error = SpeechRecognitionError.notAuthorized
            await updateStatus("Speech recognition not authorized")
            speechEventsContinuation?.yield(.error(error))
            throw error
        }
        
        logger.info("🔴 STARTING SPEECH RECOGNITION ENGINE")
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Create initial recognition session
        try await MainActor.run {
            self.startNewSession()
        }
        
        await MainActor.run {
            self.isRecording = true
            self.currentTranscription = ""
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        currentSpeechState = false
        consecutiveSilenceFrames = 0
        
        // Start session rotation watchdog
        startRotationWatchdog()
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STARTED")
    }
    
    func stopRecording() {
        logger.info("⏹️ STOPPING SPEECH RECOGNITION ENGINE")
        
        guard isRecording else { return }
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // End recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Stop rotation timer
        sessionRotationTask?.cancel()
        sessionRotationTask = nil
        sessionStartTime = nil
        
        Task { @MainActor in
            self.isRecording = false
            self.liveTranslationTask?.cancel()
            self.currentTranslation = ""

            // Add final transcription to history if not empty
            if !self.currentTranscription.isEmpty {
                let sentence = self.currentTranscription
                self.currentTranscription = ""
                self.speechEventsContinuation?.yield(.sentenceFinalized(sentence))
                let translated = await self.translationService?.translate(sentence)
                self.addToHistory(sentence, translatedText: translated)
            }
        }
        
        // Reset state
        processedTextLength = 0
        fullTranscriptionText = ""
        consecutiveSilenceFrames = 0
        
        logger.info("✅ SPEECH RECOGNITION ENGINE STOPPED")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.append(buffer)
    }

    func appendAudioBufferWithVAD(_ audioFrame: AudioFrameWithVAD) {
        guard isRecording, let recognitionRequest = recognitionRequest else { return }

        // Log frame info before appending buffer
        if isLoggerOn {
            
            let sourceString = audioFrame.source.rawValue.uppercased()
            let vadValue = audioFrame.vadResult.rmsEnergy
            let isSpeechString = audioFrame.isSpeech ? "SPEECH" : "SILENCE"
            logger.info("(\(sourceString) Frame \(audioFrame.frameIndex) - VAD RMS: \(vadValue), State: \(isSpeechString)")
        }
        recognitionRequest.append(audioFrame.buffer)
        
        // Frame-based silence detection
        if audioFrame.isSpeech {
            consecutiveSilenceFrames = 0
            onSpeechStart()
        } else {
            consecutiveSilenceFrames += 1
            
            if consecutiveSilenceFrames == 1 {
                onSpeechEnd()
            } else if consecutiveSilenceFrames == silenceFrameThreshold {
                // 2 seconds of silence - create new line!
                logger.info("⏰ 2s SILENCE DETECTED - Creating new caption line")
                Task {
                    await finalizeSentence()
                }
                consecutiveSilenceFrames = 0  // Reset counter
            }
        }
    }
    
    func onSpeechStart() {
        currentSpeechState = true
    }
    
    func onSpeechEnd() {
        currentSpeechState = false
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func updateStatus(_ status: String) {
        statusText = status
        speechEventsContinuation?.yield(.statusChanged(status))
    }
    
    @MainActor
    private func processTranscriptionResult(_ transcription: String) {
        // Store the full transcription from SFSpeechRecognizer
        let previousFullLength = fullTranscriptionText.count
        fullTranscriptionText = transcription

        // Extract only the NEW part that hasn't been processed yet
        let newPart = extractNewTranscriptionPart(from: transcription)
        currentTranscription = newPart

        // Notify via AsyncStream
        speechEventsContinuation?.yield(.transcriptionUpdate(newPart))

        // Reset silence counter if new text was added during silence
        if transcription.count > previousFullLength && !currentSpeechState {
            consecutiveSilenceFrames = 0
        }

        // Live translation with 500ms debounce
        scheduleLiveTranslation(for: newPart)
    }

    @MainActor
    private func scheduleLiveTranslation(for text: String) {
        liveTranslationTask?.cancel()
        guard translationService?.isEnabled == true else {
            currentTranslation = ""
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentTranslation = ""
            return
        }
        liveTranslationTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            if let translated = await self.translationService?.translate(text) {
                await MainActor.run { self.currentTranslation = translated }
            }
        }
    }
    
    // MARK: - Session Management (Concise)
    
    @MainActor
    private func startNewSession() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("❌ Cannot start session: recognizer unavailable")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            Task {
                if let error = error {
                    let nsError = error as NSError
                    // 203 = "No speech detected" — expected during session rotation, ignore
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                        return
                    }
                    await self.updateStatus("Recognition error: \(error.localizedDescription)")
                    self.speechEventsContinuation?.yield(.error(error))
                    return
                }
                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    await self.processTranscriptionResult(transcription)
                }
            }
        }
        sessionStartTime = Date()
        logger.info("♻️ Session started")
    }
    
    @MainActor
    private func stopCurrentSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        sessionStartTime = nil
    }
    
    private func rotateSession(reason: String, finalizeCurrent: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            self.logger.info("♻️ Rotate session (reason=\(reason))")
            if finalizeCurrent { self.finalizeSentence() }
            self.stopCurrentSession()
            self.processedTextLength = 0
            self.fullTranscriptionText = ""
            self.currentTranscription = ""
            self.startNewSession()
        }
    }
    
    private func startRotationWatchdog() {
        sessionRotationTask?.cancel()
        sessionRotationTask = Task { [weak self] in
            let checkIntervalNs: UInt64 = 5_000_000_000
            while let self = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkIntervalNs)
                guard self.isRecording, let start = self.sessionStartTime else { continue }
                if Date().timeIntervalSince(start) >= self.maxTaskDuration {
                    self.rotateSession(reason: "max-duration", finalizeCurrent: false)
                }
            }
        }
    }

    private func extractNewTranscriptionPart(from fullText: String) -> String {
        // Extract only the part that hasn't been processed yet
        if fullText.count > processedTextLength {
            let startIndex = fullText.index(fullText.startIndex, offsetBy: processedTextLength)
            let newPart = String(fullText[startIndex...])
            return newPart.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
    
    @MainActor
    private func finalizeSentence() {
        if !currentTranscription.isEmpty {
            let sentence = currentTranscription
            logger.info("📝 FINALIZING SENTENCE: \(sentence)")

            // Update processed length and clear before async translation
            processedTextLength = fullTranscriptionText.count
            currentTranscription = ""
            liveTranslationTask?.cancel()
            currentTranslation = ""

            // Notify via AsyncStream
            speechEventsContinuation?.yield(.sentenceFinalized(sentence))

            // Add to history (with translation if enabled)
            Task { @MainActor in
                let translated = await self.translationService?.translate(sentence)
                self.addToHistory(sentence, translatedText: translated)
            }

            // Rotate session after a silence-based finalization to bound internal state
            rotateSession(reason: "silence-window", finalizeCurrent: false)
        }
    }
    
    @MainActor
    private func addToHistory(_ text: String, translatedText: String? = nil) {
        let entry = CaptionEntry(
            id: UUID(),
            text: text,
            confidence: 1.0,
            translatedText: translatedText
        )
        captionHistory.append(entry)
        
        // Keep only last 50 entries to prevent memory issues
        if captionHistory.count > 50 {
            captionHistory.removeFirst()
        }
        
        logger.info("📝 Added to history: \(text)")
    }
    
    // MARK: - Public Utility Methods

    func setRecognitionLocale(_ language: Locale.Language?) {
        let targetLocale: Locale
        if let language {
            let langCode = language.minimalIdentifier
            // Find a supported locale whose language code matches
            let matched = SFSpeechRecognizer.supportedLocales()
                .first { $0.language.minimalIdentifier == langCode }
            guard let matched else {
                logger.warning("⚠️ No supported SFSpeechRecognizer locale for '\(langCode)'")
                return
            }
            targetLocale = matched
        } else {
            targetLocale = Locale.current
        }

        let newRecognizer = SFSpeechRecognizer(locale: targetLocale)
        guard newRecognizer?.isAvailable == true else {
            logger.warning("⚠️ SFSpeechRecognizer not available for '\(targetLocale.identifier)'")
            return
        }
        speechRecognizer = newRecognizer
        logger.info("🌐 Recognition locale → \(targetLocale.identifier)")

        if isRecording {
            rotateSession(reason: "locale-change", finalizeCurrent: true)
        }
    }

    func clearCaptions() {
        Task { @MainActor in
            self.captionHistory.removeAll()
            self.currentTranscription = ""
            self.consecutiveSilenceFrames = 0
            self.logger.info("🗑️ CLEARED ALL CAPTIONS")
        }
    }
}

// MARK: - Error Types

enum SpeechRecognitionError: Error, LocalizedError {
    case recognizerNotAvailable
    case notAuthorized
    case requestCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .recognizerNotAvailable:
            return "Speech recognizer is not available"
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .requestCreationFailed:
            return "Failed to create speech recognition request"
        }
    }
}
