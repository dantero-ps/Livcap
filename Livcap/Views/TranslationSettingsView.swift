//
//  TranslationSettingsView.swift
//  Livcap
//

import SwiftUI
import Translation

struct TranslationSettingsView: View {
    @ObservedObject var translationService: TranslationService

    // Common target languages
    private let targetLanguages: [(name: String, identifier: String)] = [
        ("Turkish", "tr"),
        ("English", "en"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Russian", "ru"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Chinese (Simplified)", "zh-Hans"),
        ("Chinese (Traditional)", "zh-Hant"),
        ("Arabic", "ar"),
        ("Dutch", "nl"),
        ("Polish", "pl"),
        ("Ukrainian", "uk"),
    ]

    // Common source languages (+ auto-detect)
    private let sourceLanguages: [(name: String, identifier: String?)] = [
        ("Auto-detect", nil),
        ("English", "en"),
        ("Turkish", "tr"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Russian", "ru"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Chinese (Simplified)", "zh-Hans"),
        ("Arabic", "ar"),
    ]

    private var selectedTargetIdentifier: String {
        translationService.targetLanguage.minimalIdentifier
    }

    private var selectedSourceIdentifier: String? {
        translationService.sourceLanguage?.minimalIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Translation", isOn: $translationService.isEnabled)
                .font(.system(size: 13, weight: .medium))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Source Language")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { selectedSourceIdentifier },
                        set: { id in
                            if let id {
                                translationService.sourceLanguage = Locale.Language(identifier: id)
                            } else {
                                translationService.sourceLanguage = nil
                            }
                        }
                    )) {
                        ForEach(sourceLanguages, id: \.identifier) { lang in
                            Text(lang.name).tag(lang.identifier)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Language")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { selectedTargetIdentifier },
                        set: { id in
                            translationService.targetLanguage = Locale.Language(identifier: id)
                        }
                    )) {
                        ForEach(targetLanguages, id: \.identifier) { lang in
                            Text(lang.name).tag(lang.identifier)
                        }
                    }
                    .labelsHidden()
                }
            }
            .disabled(!translationService.isEnabled)
            .opacity(translationService.isEnabled ? 1.0 : 0.4)
        }
        .padding(14)
        .frame(minWidth: 220)
    }
}

struct TranslationButton: View {
    @ObservedObject var translationService: TranslationService
    @Binding var isPopoverOpen: Bool

    var body: some View {
        CircularControlButton(
            image: .system("translate"),
            helpText: "Translation Settings",
            isActive: translationService.isEnabled,
            action: { isPopoverOpen.toggle() }
        )
        .popover(isPresented: $isPopoverOpen, arrowEdge: .bottom) {
            TranslationSettingsView(translationService: translationService)
        }
    }
}
