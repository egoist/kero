//
//  SettingsView.swift
//  mitty
//

import AppKit
import SwiftUI

/// The app settings window (Cmd+,). Currently a single pane: terminal font.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    Text("\(TerminalFont.bundledFamily) (Bundled)").tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section("Preview") {
                // Exercises regular/bold plus Nerd Font icon fallback.
                VStack(alignment: .leading, spacing: 6) {
                    Text("mitty ❯ echo \"the quick brown fox\" 0O 1lI")
                    Text("\u{E0A0} main \u{E0B0} ~/dev/mitty \u{E711} \u{F024B} \u{F0A7D}")
                    Text("bold — permission denied (os error 13)")
                        .bold()
                }
                .font(Font(previewFont))
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetFont()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    }
}

#Preview {
    SettingsView()
}
