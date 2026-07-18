//
//  DiffViewerView.swift
//  mitty
//

import Combine
import Foundation
import PierreDiffsSwift
import SwiftUI

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

    @Published private(set) var oldContent = ""
    @Published private(set) var newContent = ""
    @Published private(set) var error: String?
    @Published private(set) var isLoading = true

    private nonisolated static let maxBytes = 5 << 20

    init(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?) {
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
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
                self.oldContent = old
                self.newContent = new
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

/// Renders a diff tab with PierreDiffsSwift: syntax-highlighted unified or
/// split view with word-level change highlighting.
struct DiffViewerView: View {
    @ObservedObject var diff: DiffTab

    @State private var diffStyle: DiffStyle = .unified
    @State private var overflowMode: OverflowMode = .scroll
    /// The WKWebView renders blank until its JS bundle has drawn the diff;
    /// a skeleton covers it until the bridge reports ready.
    @State private var isWebViewReady = false

    var body: some View {
        Group {
            if let error = diff.error {
                placeholder(icon: "exclamationmark.triangle", text: error)
            } else if diff.oldContent == diff.newContent {
                if diff.isLoading {
                    DiffSkeletonView()
                } else {
                    placeholder(icon: "checkmark.circle", text: "No changes")
                }
            } else {
                VStack(spacing: 0) {
                    controlBar
                    PierreDiffView(
                        oldContent: diff.oldContent,
                        newContent: diff.newContent,
                        fileName: diff.name,
                        diffStyle: $diffStyle,
                        overflowMode: $overflowMode,
                        onReady: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isWebViewReady = true
                            }
                        }
                    )
                    // Cover (never hide) the webview while it boots: making
                    // it invisible lets WebKit throttle rendering and the
                    // initial diff render can be dropped entirely.
                    .overlay {
                        if !isWebViewReady {
                            DiffSkeletonView()
                                .background(Color(nsColor: Theme.background))
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .onAppear { diff.reload() }
    }

    private var controlBar: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("", selection: $diffStyle) {
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
