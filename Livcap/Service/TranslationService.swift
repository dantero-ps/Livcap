//
//  TranslationService.swift
//  Livcap
//

import Foundation
import Translation
import os.log

final class TranslationService: ObservableObject, @unchecked Sendable {

    @Published var isEnabled: Bool = false
    @Published var sourceLanguage: Locale.Language? = nil  // nil = auto-detect
    @Published var targetLanguage: Locale.Language = Locale.Language(identifier: "tr")

    private(set) var session: TranslationSession?
    private let logger = Logger(subsystem: "com.livcap", category: "TranslationService")

    var configuration: TranslationSession.Configuration {
        TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }

    @MainActor
    func setSession(_ session: TranslationSession) {
        self.session = session
        logger.info("✅ TranslationSession attached")
    }

    func translate(_ text: String) async -> String? {
        guard isEnabled, let session else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            logger.error("❌ Translation error: \(error.localizedDescription)")
            return nil
        }
    }
}
