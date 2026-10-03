#if !os(tvOS)
import SwiftUI
import WebKit
import GenPlayerCore

public struct Pan115WebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let onCookieCaptured: (String) -> Void

    public init(onCookieCaptured: @escaping (String) -> Void) {
        self.onCookieCaptured = onCookieCaptured
    }

    private let loginURL = URL(string: "https://115.com/")!

    public var body: some View {
        #if os(iOS)
        NavigationView {
            Pan115WebViewWrapper(
                url: loginURL,
                onCookieCaptured: { cookie in
                    onCookieCaptured(cookie)
                    dismiss()
                }
            )
            .navigationTitle(NSLocalizedString("115 Web Login", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        #else
        VStack(spacing: 0) {
            HStack {
                Text(platformShellString("115 Web Login"))
                    .font(.headline)
                Spacer()
                Button(platformShellString("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Pan115WebViewWrapper(
                url: loginURL,
                onCookieCaptured: { cookie in
                    onCookieCaptured(cookie)
                    dismiss()
                }
            )
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 620, idealHeight: 640)
        #endif
    }
}

#if os(iOS)
public struct Pan115WebViewWrapper: UIViewRepresentable {
    let url: URL
    let onCookieCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(url: URL, onCookieCaptured: @escaping (String) -> Void) {
        self.url = url
        self.onCookieCaptured = onCookieCaptured
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCookieCaptured: onCookieCaptured, dismiss: dismiss)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        context.coordinator.cookieStore?.add(context.coordinator)
        var req = URLRequest(url: url)
        req.setValue(Pan115Manager.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        webView.customUserAgent = Pan115Manager.defaultUserAgent
        webView.load(req)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onCookieCaptured: (String) -> Void
        let dismiss: DismissAction
        weak var cookieStore: WKHTTPCookieStore?
        private var hasExtracted = false

        init(onCookieCaptured: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onCookieCaptured = onCookieCaptured
            self.dismiss = dismiss
        }

        deinit {
            cookieStore?.remove(self)
        }

        public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkCookies(in: cookieStore)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let store = cookieStore {
                checkCookies(in: store)
            }
        }

        private func checkCookies(in cookieStore: WKHTTPCookieStore) {
            guard !hasExtracted else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.hasExtracted else { return }
                var uid = ""
                var cid = ""
                var seid = ""
                var kid = ""
                for cookie in cookies {
                    let d = cookie.domain.lowercased()
                    if d.contains("115.com") || d.contains("anxia.com") {
                        if cookie.name == "UID" { uid = cookie.value }
                        if cookie.name == "CID" { cid = cookie.value }
                        if cookie.name == "SEID" { seid = cookie.value }
                        if cookie.name == "KID" { kid = cookie.value }
                    }
                }
                if !uid.isEmpty && !cid.isEmpty && !seid.isEmpty {
                    self.hasExtracted = true
                    var cookieString = "UID=\(uid); CID=\(cid); SEID=\(seid)"
                    if !kid.isEmpty {
                        cookieString += "; KID=\(kid)"
                    }
                    DispatchQueue.main.async {
                        self.onCookieCaptured(cookieString)
                    }
                }
            }
        }
    }
}
#elseif os(macOS)
public struct Pan115WebViewWrapper: NSViewRepresentable {
    let url: URL
    let onCookieCaptured: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(url: URL, onCookieCaptured: @escaping (String) -> Void) {
        self.url = url
        self.onCookieCaptured = onCookieCaptured
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCookieCaptured: onCookieCaptured, dismiss: dismiss)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        context.coordinator.cookieStore?.add(context.coordinator)
        var req = URLRequest(url: url)
        req.setValue(Pan115Manager.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        webView.customUserAgent = Pan115Manager.defaultUserAgent
        webView.load(req)
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onCookieCaptured: (String) -> Void
        let dismiss: DismissAction
        weak var cookieStore: WKHTTPCookieStore?
        private var hasExtracted = false

        init(onCookieCaptured: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onCookieCaptured = onCookieCaptured
            self.dismiss = dismiss
        }

        deinit {
            cookieStore?.remove(self)
        }

        public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkCookies(in: cookieStore)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let store = cookieStore {
                checkCookies(in: store)
            }
        }

        private func checkCookies(in cookieStore: WKHTTPCookieStore) {
            guard !hasExtracted else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.hasExtracted else { return }
                var uid = ""
                var cid = ""
                var seid = ""
                var kid = ""
                for cookie in cookies {
                    let d = cookie.domain.lowercased()
                    if d.contains("115.com") || d.contains("anxia.com") {
                        if cookie.name == "UID" { uid = cookie.value }
                        if cookie.name == "CID" { cid = cookie.value }
                        if cookie.name == "SEID" { seid = cookie.value }
                        if cookie.name == "KID" { kid = cookie.value }
                    }
                }
                if !uid.isEmpty && !cid.isEmpty && !seid.isEmpty {
                    self.hasExtracted = true
                    var cookieString = "UID=\(uid); CID=\(cid); SEID=\(seid)"
                    if !kid.isEmpty {
                        cookieString += "; KID=\(kid)"
                    }
                    DispatchQueue.main.async {
                        self.onCookieCaptured(cookieString)
                    }
                }
            }
        }
    }
}
#endif
#endif
