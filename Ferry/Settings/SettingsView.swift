import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransferSettingsView()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(SettingsKey.theme) private var theme: AppTheme = .system
    @AppStorage(SettingsKey.language) private var languageCode = AppLanguage.initialSelection.rawValue

    var body: some View {
        Form {
            LabeledContent("Appearance") {
                AppearancePicker(selection: $theme)
            }
            Picker("Language", selection: $languageCode) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language.rawValue)
                }
            }
            .onChange(of: languageCode) { _, code in
                AppLanguage.persistForBundleLookup(AppLanguage(rawValue: code) ?? .english)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TransferSettingsView: View {
    @AppStorage(SettingsKey.transferConcurrency) private var concurrency = 3
    @AppStorage(SettingsKey.transferRetries) private var retries = 3
    @AppStorage(SettingsKey.bandwidthLimitEnabled) private var limitsBandwidth = false
    @AppStorage(SettingsKey.bandwidthLimitKilobytes) private var bandwidthLimit = 1024

    var body: some View {
        Form {
            Stepper(value: $concurrency, in: 1...16) {
                LabeledContent("Simultaneous Transfers", value: concurrency.formatted())
            }
            Stepper(value: $retries, in: 0...10) {
                LabeledContent("Automatic Retries", value: retries.formatted())
            }
            Toggle("Limit Bandwidth", isOn: $limitsBandwidth)
            if limitsBandwidth {
                LabeledContent("Maximum Speed") {
                    HStack(spacing: 4) {
                        TextField("Maximum Speed", value: $bandwidthLimit, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(verbatim: "KB/s")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// System, Light, and Dark choices, each previewed with a miniature of the browser window.
struct AppearancePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppTheme.allCases) { option in
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 6) {
                        AppearancePreview(theme: option)
                            .frame(width: 72, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selection == option ? Color.accentColor : .secondary.opacity(0.3),
                                                  lineWidth: selection == option ? 2 : 1)
                            }
                        Text(option.title)
                            .font(.caption)
                            .foregroundStyle(selection == option ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }
}

/// A miniature of Ferry's window: sidebar, path bar, and file rows.
struct AppearancePreview: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .light:
            MiniatureWindow(isDark: false)
        case .dark:
            MiniatureWindow(isDark: true)
        case .system:
            HStack(spacing: 0) {
                MiniatureWindow(isDark: false)
                    .frame(width: 36, alignment: .leading)
                    .clipped()
                MiniatureWindow(isDark: true)
                    .frame(width: 36, alignment: .trailing)
                    .clipped()
            }
        }
    }
}

private struct MiniatureWindow: View {
    let isDark: Bool

    var body: some View {
        let background = isDark ? Color(white: 0.16) : Color(white: 0.98)
        let sidebar = isDark ? Color(white: 0.22) : Color(white: 0.9)
        let line = isDark ? Color(white: 0.4) : Color(white: 0.75)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == 1 ? Color.accentColor : line)
                        .frame(width: 14, height: 3)
                }
                Spacer()
            }
            .padding(5)
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(line.opacity(0.6)).frame(width: 26, height: 3)
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < 2 ? Color.accentColor.opacity(0.8) : line)
                            .frame(width: 5, height: 4)
                        Capsule().fill(line).frame(width: index.isMultiple(of: 2) ? 24 : 18, height: 3)
                    }
                }
                Spacer()
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(background)
        }
    }
}

#Preview {
    SettingsView()
}
