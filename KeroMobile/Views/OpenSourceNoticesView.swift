import SwiftUI

struct OpenSourceNoticesView: View {
    var body: some View {
        List {
            Section {
                package(
                    "Ghostty",
                    detail: "Terminal emulation and rendering · MIT License",
                    url: "https://github.com/ghostty-org/ghostty"
                )
                package(
                    "libghostty-spm",
                    detail: "Swift and UIKit integration · MIT License",
                    url: "https://github.com/egoist-labs/libghostty-spm"
                )
                package(
                    "MSDisplayLink",
                    detail: "Display scheduling · MIT License",
                    url: "https://github.com/Lakr233/MSDisplayLink"
                )
                package(
                    "SwiftNIO SSH",
                    detail: "SSH protocol · Apache License 2.0",
                    url: "https://github.com/apple/swift-nio-ssh"
                )
                package(
                    "SwiftNIO",
                    detail: "Networking · Apache License 2.0",
                    url: "https://github.com/apple/swift-nio"
                )
                package(
                    "Swift Crypto",
                    detail: "Cryptography · Apache License 2.0",
                    url: "https://github.com/apple/swift-crypto"
                )
                package(
                    "Swift Atomics",
                    detail: "Atomic operations · Apache License 2.0",
                    url: "https://github.com/apple/swift-atomics"
                )
                package(
                    "Swift Collections",
                    detail: "Data structures · Apache License 2.0",
                    url: "https://github.com/apple/swift-collections"
                )
                package(
                    "Swift System",
                    detail: "System interfaces · Apache License 2.0",
                    url: "https://github.com/apple/swift-system"
                )
                package(
                    "JetBrains Mono",
                    detail: "Terminal font · SIL Open Font License 1.1",
                    url: "https://github.com/JetBrains/JetBrainsMono"
                )
            } footer: {
                Text(
                    "Kero is grateful to the authors and contributors of these "
                    + "open-source projects."
                )
            }

            Section {
                NavigationLink("Ghostty components · MIT License") {
                    BundledLicenseView(
                        title: "MIT License",
                        resource: "Ghostty-MIT"
                    )
                }
                NavigationLink("SwiftNIO · Apache License 2.0") {
                    BundledLicenseView(
                        title: "Apache License 2.0",
                        resource: "Apache-2.0"
                    )
                }
                NavigationLink("Third-Party Notices") {
                    BundledLicenseView(
                        title: "Third-Party Notices",
                        resource: "Third-Party-NOTICES"
                    )
                }
                NavigationLink("JetBrains Mono · SIL OFL 1.1") {
                    BundledLicenseView(
                        title: "SIL Open Font License 1.1",
                        resource: "OFL"
                    )
                }
            } header: {
                Text("License Texts")
            } footer: {
                Text(
                    "SwiftNIO SSH, SwiftNIO, Swift Crypto, Swift Atomics, "
                    + "Swift Collections, and Swift System are distributed "
                    + "under the same included Apache License, Version 2.0."
                )
            }
        }
        .navigationTitle("Open Source")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func package(
        _ name: String,
        detail: String,
        url: String
    ) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BundledLicenseView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(
            forResource: resource,
            withExtension: "txt"
        ),
        let value = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license text could not be loaded."
        }
        return value
    }
}
