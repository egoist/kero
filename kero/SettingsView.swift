//
//  SettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared

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
                    Text("kero ❯ echo \"the quick brown fox\" 0O 1lI")
                    Text("\u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}")
                    Text("bold — permission denied (os error 13)")
                        .bold()
                }
                .font(Font(previewFont))
                .padding(.vertical, 4)
            }

            Section("Terminal") {
                Toggle("Use GPU rendering", isOn: $settings.gpuRenderingEnabled)

                Toggle(
                    "Restore session history on relaunch",
                    isOn: $settings.restoreTerminalHistory
                )
                Text("Reopened terminals show their previous scrollback above a fresh shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text Editing") {
                Toggle("Wrap lines to editor width", isOn: $settings.wrapLines)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $updater.automaticallyChecksForUpdates
                )

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize
                        && settings.gpuRenderingEnabled
                        && !settings.wrapLines
                        && !settings.restoreTerminalHistory)
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
