//
//  DiffViewerView.swift
//  kero
//

import AppKit
import Combine
import Foundation
import PierreDiffsSwift
import SwiftUI

/// Observable inputs for a diff tab's web view. Owned by `DiffTab` and also
/// retained by the tab's long-lived hosting view, so it must never reference
/// the `DiffTab` back (that would leak the tab through a retain cycle).
@MainActor
final class DiffWebModel: nonisolated ObservableObject {
    @Published var oldContent = ""
    @Published var newContent = ""
    @Published var fileName = ""
    @Published var diffStyle: DiffStyle = .unified
    @Published var overflowMode: OverflowMode = .scroll
    /// The WKWebView renders blank until its JS bundle has drawn the diff;
    /// a skeleton covers it until the bridge reports ready.
    @Published var isReady = false
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
final class DiffTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String?

    @Published private(set) var error: String?
    @Published private(set) var isLoading = true

    let web = DiffWebModel()

    /// The web view lives on the tab (not in the SwiftUI view) so switching
    /// tabs re-parents the same rendered view instead of booting a fresh
    /// WKWebView — same pattern as `TerminalSession.terminalView`.
    private(set) lazy var webHostView: NSView = NSHostingView(
        rootView: DiffWebRoot(model: web)
    )

    private nonisolated static let maxBytes = 5 << 20

    init(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?) {
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        web.fileName = name
        reload()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var title: String {
        staged ? name + " (Staged)" : name
    }

    func reload() {
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked

        Task.detached(priority: .userInitiated) { [weak self] in
            var failureVar: String?
            let old: String
            let new: String
            if staged {
                old = Self.gitShow("HEAD:\(oldPath)", in: root)
                new = Self.gitShow(":\(path)", in: root)
            } else {
                old = untracked ? "" : Self.gitShow(":\(oldPath)", in: root)
                new = Self.readWorktreeFile(root: root, path: path, error: &failureVar)
            }
            let failure = failureVar
            await MainActor.run {
                guard let self else { return }
                self.isLoading = false
                self.error = failure
                self.web.oldContent = old
                self.web.newContent = new
            }
        }
    }

    /// Content of `spec` (e.g. `HEAD:path` or `:path` for the index);
    /// empty when the object does not exist there, e.g. a newly added file.
    private nonisolated static func gitShow(_ spec: String, in root: String) -> String {
        let run = GitStatusModel.runGit(["show", spec], in: root)
        return run.status == 0 ? run.stdout : ""
    }

    private nonisolated static func readWorktreeFile(
        root: String, path: String, error: inout String?
    ) -> String {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        }
        guard data.count <= maxBytes else {
            error = "File is too large to diff"
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else {
            error = "Binary file"
            return ""
        }
        return text
    }
}

/// Root of the tab-owned hosting view: keeps the PierreDiffView (and its
/// WKWebView) alive for the tab's lifetime, re-rendering when the model's
/// inputs change.
private struct DiffWebRoot: View {
    @ObservedObject var model: DiffWebModel

    var body: some View {
        PierreDiffView(
            oldContent: model.oldContent,
            newContent: model.newContent,
            fileName: model.fileName,
            diffStyle: $model.diffStyle,
            overflowMode: $model.overflowMode,
            onReady: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isReady = true
                }
            }
        )
    }
}

/// Re-parents a tab's long-lived web host view into the current tab area;
/// AppKit detaches it from any previous container automatically.
private struct DiffWebHostView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Renders a diff tab with PierreDiffsSwift: syntax-highlighted unified or
/// split view with word-level change highlighting.
struct DiffViewerView: View {
    @ObservedObject var diff: DiffTab
    @ObservedObject private var web: DiffWebModel
    /// The view stays mounted while other tabs are selected (see
    /// ContentView); this flags when it is the frontmost tab so content
    /// refreshes on each re-visit, not just on first mount.
    let isSelected: Bool

    init(diff: DiffTab, isSelected: Bool = true) {
        _diff = ObservedObject(wrappedValue: diff)
        _web = ObservedObject(wrappedValue: diff.web)
        self.isSelected = isSelected
    }

    var body: some View {
        Group {
            if let error = diff.error {
                placeholder(icon: "exclamationmark.triangle", text: error)
            } else if web.oldContent == web.newContent {
                if diff.isLoading {
                    DiffSkeletonView()
                } else {
                    placeholder(icon: "checkmark.circle", text: "No changes")
                }
            } else {
                VStack(spacing: 0) {
                    controlBar
                    DiffWebHostView(view: diff.webHostView)
                        // Cover (never hide) the webview while it boots:
                        // making it invisible lets WebKit throttle rendering
                        // and the initial diff render can be dropped entirely.
                        .overlay {
                            if !web.isReady {
                                DiffSkeletonView()
                                    .background(Color(nsColor: Theme.background))
                                    .transition(.opacity)
                            }
                        }
                }
            }
        }
        .onAppear { diff.reload() }
        .onChange(of: isSelected) {
            if isSelected {
                diff.reload()
            }
        }
    }

    private var controlBar: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("", selection: $web.diffStyle) {
                ForEach(DiffStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Code-shaped gray bars shown while the diff web view boots, so opening
/// a diff never flashes an empty pane.
private struct DiffSkeletonView: View {
    /// (indent level, width fraction) per line, repeated to fill the pane.
    private static let pattern: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.42), (1, 0.62), (1, 0.30), (1, 0.55),
        (2, 0.38), (2, 0.50), (1, 0.24), (0, 0.16),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<24, id: \.self) { index in
                    let line = Self.pattern[index % Self.pattern.count]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: geo.size.width * line.width * 0.55, height: 9)
                        .padding(.leading, line.indent * 18)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
