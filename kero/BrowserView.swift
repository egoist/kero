//
//  BrowserView.swift
//  kero
//

import AppKit
import Combine
import ImageIO
import SwiftUI
import WebKit

private enum BrowserContextMenuSupport {
    static let messageName = "keroContextMenuLink"
    static let script = #"""
    (() => {
      window.addEventListener("contextmenu", event => {
        let element = event.target;
        if (element?.nodeType === Node.TEXT_NODE) {
          element = element.parentElement;
        }
        const link = element?.closest?.("a[href], area[href]");
        window.webkit.messageHandlers.keroContextMenuLink.postMessage(
          link?.href || ""
        );
      }, true);
    })()
    """#
}

private final class BrowserContextMenuBridge: NSObject, WKScriptMessageHandler {
    weak var webView: BrowserWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        webView?.contextMenuLink = message.body as? String
    }
}

/// WKWebView subclass that reports page interaction back to the pane layout.
/// WebKit's actual first responder is a private descendant view, so observing
/// the outer SwiftUI host is not enough to keep pane focus in sync.
final class BrowserWebView: WKWebView {
    var onFocused: (() -> Void)?
    var onNewBrowserTab: ((String?) -> Void)?
    var onNewBrowserPane: ((String?) -> Void)?
    fileprivate var contextMenuLink: String? {
        didSet {
            guard let contextMenuLink,
                  let url = URL(string: contextMenuLink),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme)
            else {
                contextMenuLinkURL = nil
                return
            }
            contextMenuLinkURL = url
        }
    }

    private var contextMenuLinkURL: URL?
    private static let openLinkInNewTabIdentifier =
        NSUserInterfaceItemIdentifier("kero.browser.openLinkInNewTab")
    private static let openLinkInNewPaneIdentifier =
        NSUserInterfaceItemIdentifier("kero.browser.openLinkInNewPane")

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextMenuLink = nil
        onFocused?()
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let linkURL = contextMenuLinkURL else { return }

        removeDefaultOpenInNewWindow(from: menu)
        guard menu.items.contains(where: {
            $0.identifier == Self.openLinkInNewTabIdentifier
        }) == false else { return }

        let tabItem = linkMenuItem(
            String(localized: "Open Link in New Tab"),
            identifier: Self.openLinkInNewTabIdentifier,
            action: #selector(openLinkInNewTab(_:)),
            linkURL: linkURL
        )
        let paneItem = linkMenuItem(
            String(localized: "Open Link in New Pane"),
            identifier: Self.openLinkInNewPaneIdentifier,
            action: #selector(openLinkInNewPane(_:)),
            linkURL: linkURL
        )

        let insertionIndex = min(1, menu.items.count)
        menu.insertItem(tabItem, at: insertionIndex)
        menu.insertItem(paneItem, at: insertionIndex + 1)
        let separatorIndex = insertionIndex + 2
        if separatorIndex < menu.items.count,
           !menu.items[separatorIndex].isSeparatorItem {
            menu.insertItem(.separator(), at: separatorIndex)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextMenuLink = nil
    }

    private func removeDefaultOpenInNewWindow(from menu: NSMenu) {
        let localizedTitle = String(localized: "Open Link in New Window")
        if let item = menu.items.first(where: {
            $0.title == localizedTitle || ($0.tag == 1 && $0.action != nil)
        }) {
            menu.removeItem(item)
        }
    }

    private func linkMenuItem(
        _ title: String,
        identifier: NSUserInterfaceItemIdentifier,
        action: Selector,
        linkURL: URL
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.identifier = identifier
        item.target = self
        item.representedObject = linkURL.absoluteString
        return item
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        onNewBrowserTab?(sender.representedObject as? String)
    }

    @objc private func openLinkInNewPane(_ sender: NSMenuItem) {
        onNewBrowserPane?(sender.representedObject as? String)
    }
}

/// The long-lived state of one browser pane. The WKWebView belongs to the
/// model, rather than the transient SwiftUI representable, so switching tabs
/// preserves page state, history, forms, and scroll position.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    enum InitialFocus {
        case addressBar
        case webContent
        case none
    }

    nonisolated let id = UUID()

    @Published private(set) var title = String(localized: "New Tab")
    @Published private(set) var urlString = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var favicon: NSImage?
    /// Incremented by the app-level Focus Address Bar command. A sequence is
    /// used instead of a Bool so repeated ⌘L presses are never coalesced.
    @Published private(set) var focusAddressRequest: UInt = 0

    let webView: BrowserWebView

    private var pageTitle: String?
    private var observations: Set<AnyCancellable> = []
    private var initialFocus: InitialFocus?
    private let contextMenuBridge: BrowserContextMenuBridge
    private var faviconTask: Task<Void, Never>?
    private var faviconRevision: UInt = 0

    private static let maximumFaviconBytes = 2 * 1_024 * 1_024
    /// WKWebView's default macOS user agent has no browser/version token, so
    /// some sites mistake the current WebKit engine for an obsolete browser.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"
    private static let faviconCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private static let faviconCandidatesScript = #"""
    (() => {
      const score = link => {
        const sizes = Array.from(link.sizes || []);
        if (link.type === "image/svg+xml" || sizes.includes("any")) return 10000;
        return sizes.reduce((best, size) => {
          const match = size.match(/^(\d+)x(\d+)$/);
          return match
            ? Math.max(best, Math.min(Number(match[1]), Number(match[2])))
            : best;
        }, 0);
      };
      return Array.from(document.querySelectorAll("link[rel][href]"))
        .filter(link => {
          const rel = link.rel.toLowerCase();
          return rel.split(/\s+/).includes("icon")
            || rel.includes("apple-touch-icon");
        })
        .sort((a, b) => score(b) - score(a))
        .map(link => link.href);
    })()
    """#

    init(
        initialURL: String? = nil,
        initialFocus: InitialFocus = .addressBar
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        let contextMenuBridge = BrowserContextMenuBridge()
        let contextWorld = WKContentWorld.defaultClient
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserContextMenuSupport.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: contextWorld
        ))
        configuration.userContentController.add(
            contextMenuBridge,
            contentWorld: contextWorld,
            name: BrowserContextMenuSupport.messageName
        )

        self.contextMenuBridge = contextMenuBridge
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        self.initialFocus = initialFocus
        super.init()

        webView.customUserAgent = Self.userAgent
        contextMenuBridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observeWebView()

        if let initialURL, !initialURL.isEmpty {
            navigate(to: initialURL)
        }
    }

    deinit {
        faviconTask?.cancel()
    }

    var snapshotURL: String? {
        urlString.isEmpty ? nil : urlString
    }

    var shareURL: URL? {
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var isBlank: Bool {
        urlString.isEmpty
    }

    func consumeInitialFocus() -> InitialFocus? {
        defer { initialFocus = nil }
        return initialFocus
    }

    func requestAddressFocus() {
        focusAddressRequest &+= 1
    }

    func navigate(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.destination(for: trimmed) else { return }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else if !isBlank {
            errorMessage = nil
            webView.reload()
        }
    }

    func reload() {
        guard !isBlank else { return }
        errorMessage = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func openInDefaultBrowser() {
        guard let shareURL else { return }
        NSWorkspace.shared.open(shareURL)
    }

    private func observeWebView() {
        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] title in
                self?.pageTitle = title
                self?.refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self] url in
                guard let self else { return }
                self.urlString = Self.displayAddress(for: url)
                self.refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self] in self?.canGoBack = $0 }
            .store(in: &observations)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self] in self?.canGoForward = $0 }
            .store(in: &observations)

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] isLoading in
                guard let self else { return }
                let startedLoading = isLoading && !self.isLoading
                self.isLoading = isLoading
                if startedLoading {
                    self.prepareForFaviconNavigation()
                } else if !isLoading, self.webView.url != nil {
                    self.loadFavicon()
                }
            }
            .store(in: &observations)

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .sink { [weak self] in self?.estimatedProgress = $0 }
            .store(in: &observations)
    }

    private func refreshTitle() {
        if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageTitle.isEmpty {
            title = pageTitle
        } else if let host = webView.url?.host, !host.isEmpty {
            title = host
        } else {
            title = String(localized: "New Tab")
        }
    }

    private static func displayAddress(for url: URL?) -> String {
        guard let url,
              url.absoluteString != "about:blank",
              url.scheme != nil
        else { return "" }
        return url.absoluteString
    }

    /// Turns the Safari-style combined address/search field into a request.
    /// Explicit URLs are preserved, likely hostnames gain a scheme, and
    /// everything else becomes a web search.
    private static func destination(for input: String) -> URL? {
        let lowercased = input.lowercased()
        let explicitPrefixes = [
            "http://", "https://", "file://", "about:", "data:",
        ]
        if explicitPrefixes.contains(where: lowercased.hasPrefix) {
            return urlAllowingSpaces(input)
        }

        if !input.contains(where: \.isWhitespace), looksLikeHost(input) {
            let host = host(in: input).lowercased()
            let useHTTP = host == "localhost"
                || host.hasSuffix(".local")
                || isIPv4(host)
                || host.hasPrefix("[::")
                || hasExplicitPort(input)
            return urlAllowingSpaces("\(useHTTP ? "http" : "https")://\(input)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: input)]
        return components?.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        let host = host(in: input)
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if host.hasPrefix("[") && host.contains("]") { return true }
        if host.contains(".") { return true }
        return hasExplicitPort(input)
    }

    private static func host(in input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            return String(authority[...bracket])
        }
        return authority.split(separator: ":", maxSplits: 1).first.map(String.init)
            ?? authority
    }

    private static func isIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4
            && components.allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
    }

    private static func hasExplicitPort(_ input: String) -> Bool {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            let remainder = authority[authority.index(after: bracket)...]
            return remainder.first == ":" && Int(remainder.dropFirst()) != nil
        }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        return Int(authority[authority.index(after: colon)...]) != nil
    }

    private static func urlAllowingSpaces(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        return string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    // MARK: - WKNavigationDelegate

    private func prepareForFaviconNavigation() {
        errorMessage = nil
        faviconRevision &+= 1
        faviconTask?.cancel()
        faviconTask = nil
        favicon = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = String(localized: "The webpage stopped responding.")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased()
        else {
            decisionHandler(.allow)
            return
        }
        let handledSchemes = ["http", "https", "file", "about", "data", "blob"]
        if handledSchemes.contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private func showNavigationError(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    private func loadFavicon() {
        faviconTask?.cancel()
        let revision = faviconRevision
        faviconTask = Task { @MainActor [weak self] in
            guard let webView = self?.webView,
                  let pageURL = webView.url
            else { return }

            let result = try? await webView.evaluateJavaScript(
                Self.faviconCandidatesScript
            )
            let declared = result as? [String] ?? []
            var candidates = declared.compactMap {
                URL(string: $0, relativeTo: pageURL)?.absoluteURL
            }
            if let conventional = URL(
                string: "/favicon.ico",
                relativeTo: pageURL
            )?.absoluteURL {
                candidates.append(conventional)
            }

            var seen = Set<String>()
            for candidate in candidates where seen.insert(candidate.absoluteString).inserted {
                guard !Task.isCancelled else { return }

                if candidate.scheme?.lowercased() != "data",
                   let cached = Self.faviconCache.object(
                       forKey: candidate as NSURL
                   ) {
                    guard let self, self.faviconRevision == revision else { return }
                    self.favicon = cached
                    return
                }

                guard let data = await Self.faviconData(from: candidate),
                      !Task.isCancelled,
                      let image = Self.faviconImage(from: data)
                else { continue }

                if candidate.scheme?.lowercased() != "data" {
                    Self.faviconCache.setObject(
                        image,
                        forKey: candidate as NSURL,
                        cost: data.count
                    )
                }
                guard let self, self.faviconRevision == revision else { return }
                self.favicon = image
                return
            }
        }
    }

    private static func faviconData(from url: URL) async -> Data? {
        switch url.scheme?.lowercased() {
        case "data":
            return faviconData(fromDataURL: url)
        case "http", "https":
            var request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 10
            )
            request.setValue(
                "image/avif,image/webp,image/svg+xml,image/*,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            guard let (data, response) = try? await URLSession.shared.data(
                for: request
            ),
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            data.count <= maximumFaviconBytes
            else { return nil }
            return data
        default:
            return nil
        }
    }

    private static func faviconData(fromDataURL url: URL) -> Data? {
        let value = url.absoluteString
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let metadata = value[..<comma].lowercased()
        let payload = String(value[value.index(after: comma)...])
        let data: Data?
        if metadata.hasSuffix(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, data.count <= maximumFaviconBytes else { return nil }
        return data
    }

    /// Decode remote artwork into one bounded bitmap before publishing it.
    /// A page-controlled SVG or unusually large raster should never make a
    /// tiny tab icon allocate at its source dimensions.
    private static func faviconImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        let favicon = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        favicon.isTemplate = false
        return favicon
    }

    // MARK: - WKUIDelegate

    /// Keep target=_blank links inside this browser tab. Kero has an explicit
    /// tab command, so webpages should not create detached, chrome-less
    /// WKWebView windows.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? String(localized: "Webpage")
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func present(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// A browser identity icon that observes favicon arrival independently of the
/// pane/tab container rendering it.
struct BrowserFaviconView: View {
    @ObservedObject var browser: BrowserTab
    let size: CGFloat
    var fallbackSystemImage = "globe"

    @ViewBuilder
    var body: some View {
        if let favicon = browser.favicon {
            Image(nsImage: favicon)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(
                    cornerRadius: max(1.5, size * 0.18),
                    style: .continuous
                ))
        } else {
            Image(systemName: fallbackSystemImage)
                .frame(width: size, height: size)
        }
    }
}

/// Browser content and native navigation chrome. The toolbar stays in SwiftUI
/// so it follows Kero's appearance while the page remains a real WKWebView.
struct BrowserView: View {
    @ObservedObject var browser: BrowserTab
    let isFocused: Bool
    let onFocused: () -> Void
    let onNewBrowserTab: (String?) -> Void
    let onNewBrowserPane: (String?) -> Void

    @ObservedObject private var themeChanges = Theme.changes
    @State private var address = ""
    @State private var addressFocused = false
    @State private var addressFocusRequest: UInt = 0
    @State private var webContentFocusRequest: UInt = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                BrowserWebViewRepresentable(
                    browser: browser,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab,
                    onNewBrowserPane: onNewBrowserPane,
                    focusRequest: webContentFocusRequest
                )

                if browser.isBlank {
                    Color(nsColor: Theme.background)
                        .overlay {
                            Image(systemName: "globe")
                                .font(.system(size: 34, weight: .ultraLight))
                                .foregroundStyle(.tertiary)
                        }
                        .allowsHitTesting(false)
                }

                if let errorMessage = browser.errorMessage {
                    errorState(errorMessage)
                }
            }
            .overlay(alignment: .top) {
                progress
            }
        }
        .background(Color(nsColor: Theme.background))
        .onAppear {
            address = browser.urlString
        }
        .task(id: browser.id) {
            // A split can transiently mount this view while the grid settles.
            // SwiftUI cancels this task if that mount is discarded, preserving
            // the one-shot request for the stable browser view.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let initialFocus = browser.consumeInitialFocus()
            guard isFocused else { return }
            applyFocus(initialFocus ?? currentFocusStrategy)
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else { return }
            applyFocus(currentFocusStrategy)
        }
        .onChange(of: browser.urlString) { _, value in
            if !addressFocused {
                address = value
            }
        }
        .onChange(of: browser.focusAddressRequest) {
            focusAddressField()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                toolbarButton(
                    "chevron.left",
                    help: String(localized: "Back"),
                    disabled: !browser.canGoBack,
                    action: browser.goBack
                )
                toolbarButton(
                    "chevron.right",
                    help: String(localized: "Forward"),
                    disabled: !browser.canGoForward,
                    action: browser.goForward
                )
                toolbarButton(
                    browser.isLoading ? "xmark" : "arrow.clockwise",
                    help: browser.isLoading
                        ? String(localized: "Stop")
                        : String(localized: "Reload Page (⌘R)"),
                    disabled: browser.isBlank && !browser.isLoading,
                    action: browser.reloadOrStop
                )
            }
            .frame(width: 94, alignment: .leading)

            Spacer(minLength: 0)
            addressField
                .frame(maxWidth: 720)
            Spacer(minLength: 0)

            HStack(spacing: 2) {
                if let url = browser.shareURL {
                    ShareLink(item: url) {
                        toolbarIcon("square.and.arrow.up", opticalYOffset: -1)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded(onFocused))
                    .help(String(localized: "Share"))
                    .accessibilityLabel(String(localized: "Share"))
                } else {
                    toolbarIcon("square.and.arrow.up", opticalYOffset: -1)
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }

                toolbarButton(
                    "arrow.up.right.square",
                    help: String(localized: "Open in Default Browser"),
                    disabled: browser.shareURL == nil,
                    action: browser.openInDefaultBrowser
                )
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: addressIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)

            BrowserAddressField(
                text: $address,
                focusRequest: addressFocusRequest,
                onFocus: {
                    addressFocused = true
                    onFocused()
                },
                onBlur: {
                    addressFocused = false
                },
                onSubmit: {
                    browser.navigate(to: address)
                },
                onCancel: {
                    address = browser.urlString
                }
            )
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(addressFocused ? 0.09 : 0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    addressFocused
                        ? Color(nsColor: Theme.accent).opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: addressFocused ? 1.5 : 1
                )
        )
    }

    private var addressIcon: String {
        if browser.isBlank { return "magnifyingglass" }
        guard let url = browser.webView.url else { return "magnifyingglass" }
        switch url.scheme?.lowercased() {
        case "https": return "lock.fill"
        case "http": return "globe"
        default: return "doc"
        }
    }

    @ViewBuilder
    private var progress: some View {
        if browser.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color(nsColor: Theme.accent))
                    .frame(
                        width: geometry.size.width
                            * max(0.04, min(1, browser.estimatedProgress))
                    )
            }
            .frame(height: 2)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func toolbarButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onFocused()
            action()
        } label: {
            toolbarIcon(systemImage)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toolbarIcon(
        _ systemImage: String,
        opticalYOffset: CGFloat = 0
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .offset(y: opticalYOffset)
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("This webpage couldn’t be loaded.")
                .font(.headline)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Try Again") {
                browser.reload()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }

    private func focusAddressField() {
        addressFocusRequest &+= 1
    }

    private var currentFocusStrategy: BrowserTab.InitialFocus {
        browser.isBlank ? .addressBar : .webContent
    }

    private func applyFocus(_ strategy: BrowserTab.InitialFocus) {
        switch strategy {
        case .addressBar:
            focusAddressField()
        case .webContent:
            webContentFocusRequest &+= 1
        case .none:
            break
        }
    }
}

/// NSTextField owns a private field editor while it is active. Selecting from a
/// SwiftUI focus callback happens during mouse-down, then that editor collapses
/// the selection again on mouse-up. Consume the inactive field's first click
/// and select through the native editor; subsequent clicks can place the caret.
private final class BrowserAddressTextField: NSTextField {
    var isActivelyEditing = false

    override func mouseDown(with event: NSEvent) {
        guard isActivelyEditing else {
            selectText(nil)
            return
        }
        super.mouseDown(with: event)
    }

    @discardableResult
    func focusAndSelectAll() -> Bool {
        guard let window, window.makeFirstResponder(self) else {
            return false
        }
        selectText(nil)
        return true
    }
}

private struct BrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusRequest: focusRequest,
            onFocus: onFocus,
            onBlur: onBlur,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> BrowserAddressTextField {
        let field = BrowserAddressTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = .labelColor
        field.placeholderString = String(localized: "Search or enter website name")
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(String(localized: "Search or enter website name"))
        return field
    }

    func updateNSView(_ field: BrowserAddressTextField, context: Context) {
        context.coordinator.update(from: self)
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var handledFocusRequest: UInt?
        private var onFocus: () -> Void
        private var onBlur: () -> Void
        private var onSubmit: () -> Void
        private var onCancel: () -> Void

        init(
            text: Binding<String>,
            focusRequest: UInt,
            onFocus: @escaping () -> Void,
            onBlur: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            // onAppear may issue the initial request before SwiftUI creates
            // this coordinator. A nonzero value is pending in that case.
            handledFocusRequest = focusRequest == 0 ? 0 : nil
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(from field: BrowserAddressField) {
            text = field.$text
            onFocus = field.onFocus
            onBlur = field.onBlur
            onSubmit = field.onSubmit
            onCancel = field.onCancel
        }

        func focus(_ field: BrowserAddressTextField) {
            // A newly inserted split can update before AppKit has attached its
            // field to the window. Keep the one-shot request alive briefly.
            focus(field, attemptsRemaining: 6)
        }

        private func focus(
            _ field: BrowserAddressTextField,
            attemptsRemaining: Int
        ) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if field.focusAndSelectAll() { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(
                        field,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?.isActivelyEditing = true
            onFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?.isActivelyEditing = false
            onBlur()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                text.wrappedValue = textView.string
                onSubmit()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

private struct BrowserWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var browser: BrowserTab
    let onFocused: () -> Void
    let onNewBrowserTab: (String?) -> Void
    let onNewBrowserPane: (String?) -> Void
    let focusRequest: UInt

    func makeCoordinator() -> Coordinator {
        Coordinator(handledFocusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> BrowserWebView {
        browser.webView.onFocused = onFocused
        browser.webView.onNewBrowserTab = onNewBrowserTab
        browser.webView.onNewBrowserPane = onNewBrowserPane
        return browser.webView
    }

    func updateNSView(_ webView: BrowserWebView, context: Context) {
        webView.onFocused = onFocused
        webView.onNewBrowserTab = onNewBrowserTab
        webView.onNewBrowserPane = onNewBrowserPane
        guard focusRequest != context.coordinator.handledFocusRequest else {
            return
        }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(webView)
    }

    static func dismantleNSView(
        _ webView: BrowserWebView,
        coordinator: Coordinator
    ) {
        webView.onFocused = nil
        webView.onNewBrowserTab = nil
        webView.onNewBrowserPane = nil
    }

    final class Coordinator {
        var handledFocusRequest: UInt?

        init(handledFocusRequest: UInt) {
            // Preserve a request issued before the representable was mounted.
            self.handledFocusRequest = handledFocusRequest == 0
                ? 0
                : nil
        }

        func focus(_ webView: BrowserWebView) {
            // Split insertion can race the AppKit attachment just like the
            // address field; retry only until WebKit accepts first responder.
            focus(webView, attemptsRemaining: 6)
        }

        private func focus(
            _ webView: BrowserWebView,
            attemptsRemaining: Int
        ) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                if let window = webView.window,
                   window.makeFirstResponder(webView) {
                    return
                }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(
                        webView,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }
    }
}
