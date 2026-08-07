//
//  MarkdownImageLoader.swift
//  kero
//

import AppKit

/// Loads the images a rendered markdown document references, and caches them
/// for the life of the preview.
///
/// Rendering is synchronous, so the renderer can only draw what is already in
/// hand: an image that has to be fetched renders as its alt text, and `onLoad`
/// asks the view to render again once the bytes arrive.
///
/// Remote sources are fetched over the network — README badges are the usual
/// case. That means opening a preview can tell the image's host that this file
/// was viewed.
@MainActor
final class MarkdownImageLoader {
    /// Called after an image finishes loading, so the preview can re-render.
    /// May fire several times while a document's images arrive.
    var onLoad: (() -> Void)?

    private var cache: [URL: NSImage] = [:]
    private var inFlight: Set<URL> = []
    /// Sources that failed or were rejected. Kept so a broken link is asked for
    /// once per document rather than on every re-render.
    private var failed: Set<URL> = []

    /// A decoded image, or nil while it loads (or after it failed). Starts the
    /// load on the first miss.
    func image(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard !inFlight.contains(url), !failed.contains(url) else { return nil }

        if url.isFileURL {
            load(url) { await Self.readFile(url) }
        } else if url.scheme == "http" || url.scheme == "https" {
            load(url) { await Self.fetch(url) }
        } else {
            // data:, mailto:, anything else — nothing to draw.
            failed.insert(url)
        }
        return nil
    }

    /// Drops everything so a re-opened or re-pointed document re-reads from
    /// disk instead of showing the previous file's images.
    func reset() {
        cache.removeAll()
        failed.removeAll()
        // In-flight loads are left alone; their results are simply discarded
        // when they land, because the cache they would populate is gone.
        inFlight.removeAll()
    }

    private func load(_ url: URL, using work: @escaping () async -> NSImage?) {
        inFlight.insert(url)
        Task { [weak self] in
            let image = await work()
            guard let self else { return }
            self.inFlight.remove(url)
            guard let image else {
                self.failed.insert(url)
                return
            }
            self.cache[url] = image
            self.onLoad?()
        }
    }

    /// Ceiling on a single image, so a preview can't be made to buffer an
    /// arbitrarily large download or read.
    private nonisolated static let maxBytes = 20 << 20

    private nonisolated static func readFile(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= maxBytes
            else { return nil }
            return NSImage(data: data)
        }.value
    }

    private nonisolated static func fetch(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= maxBytes
        else { return nil }
        return NSImage(data: data)
    }
}
