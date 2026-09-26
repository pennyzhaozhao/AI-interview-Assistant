import SwiftUI

struct LanguagePickerOverlay: View {
    let onSelect: (String) -> Void

    private let languages = [
        "Python", "Java", "C++", "JavaScript", "TypeScript",
        "Go", "Rust", "Swift", "Kotlin", "C"
    ]

    @State private var customLanguage = ""
    @FocusState private var isCustomFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Choose code language"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appText)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(languages, id: \.self) { language in
                    Button(language) {
                        onSelect(language)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.appBorder))
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField(L.t("Other language..."), text: $customLanguage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.appBG.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.appBorder))
                    .focused($isCustomFocused)
                    .onSubmit { submitCustomLanguage() }

                Button(L.t("Confirm")) {
                    submitCustomLanguage()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(customLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.appMuted.opacity(0.35) : Color.appYellow)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .buttonStyle(.plain)
                .disabled(customLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appBorder))
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
    }

    private func submitCustomLanguage() {
        let value = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSelect(value)
    }
}
