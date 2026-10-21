import Foundation
import WebKit
import Observation

/// The in-app browser the AI can drive. One shared WKWebView, shown in the Browser tab
/// and in the chat side panel.
@MainActor
@Observable
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var url: String = ""
    var title: String = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var lastAgentAction: String?
    var agentActive = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.contains("://") {
            if s.contains(".") && !s.contains(" ") || s.hasPrefix("localhost") { s = (s.hasPrefix("localhost") ? "http://" : "https://") + s }
            else { s = "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) }
        }
        guard let u = URL(string: s) else { return }
        webView.load(URLRequest(url: u))
        url = s
    }

    private func sync() {
        url = webView.url?.absoluteString ?? url
        title = webView.title ?? ""
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { Task { @MainActor in self.sync() } }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in self.sync() } }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { Task { @MainActor in self.sync() } }
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { Task { @MainActor in self.sync() } }

    // Open target=_blank links in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: Agent API

    func waitForLoad(timeout: Double = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 300_000_000)
        while webView.isLoading && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        sync()
    }

    func navigate(_ target: String) async -> String {
        agentActive = true
        lastAgentAction = "Opening page"
        load(target)
        await waitForLoad()
        return await readPage()
    }

    /// Returns page text plus a numbered list of interactive elements.
    func readPage() async -> String {
        let js = """
        (() => {
          const out = [];
          let n = 0;
          document.querySelectorAll('[data-synapse-id]').forEach(e => e.removeAttribute('data-synapse-id'));
          const els = document.querySelectorAll('a[href], button, input, textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [contenteditable=true], [onclick]');
          for (const el of els) {
            const r = el.getBoundingClientRect();
            const st = getComputedStyle(el);
            if (r.width < 2 || r.height < 2 || st.visibility === 'hidden' || st.display === 'none') continue;
            if (el.type === 'hidden') continue;
            n++;
            el.setAttribute('data-synapse-id', String(n));
            const tag = el.tagName.toLowerCase();
            let label = (el.innerText || el.value || el.getAttribute('aria-label') || el.placeholder || el.title || el.name || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
            let extra = '';
            if (tag === 'input') extra = ' type=' + (el.type || 'text');
            if (tag === 'a') extra = ' -> ' + (el.getAttribute('href') || '').slice(0, 80);
            out.push('[' + n + '] <' + tag + extra + '> ' + label);
            if (n >= 150) break;
          }
          const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 7000);
          return 'URL: ' + location.href + '\\nTitle: ' + document.title + '\\n\\n--- Page text ---\\n' + text + '\\n\\n--- Interactive elements (use their numbers) ---\\n' + out.join('\\n');
        })()
        """
        return (try? await webView.evaluateJavaScript(js) as? String) ?? "Couldn't read the page."
    }

    struct ElementInfo { let tag: String; let type: String; let isSubmit: Bool; let inPasswordForm: Bool; let label: String }

    func elementInfo(_ id: Int) async -> ElementInfo? {
        let js = """
        (() => {
          const el = document.querySelector('[data-synapse-id="\(id)"]');
          if (!el) return null;
          const form = el.form || el.closest('form');
          const isSubmit = (el.type === 'submit') || (el.tagName === 'BUTTON' && form && (!el.type || el.type === 'submit'));
          const pw = form ? !!form.querySelector('input[type=password]') : false;
          return [el.tagName.toLowerCase(), (el.type || ''), isSubmit ? '1' : '0', pw ? '1' : '0', (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 60)];
        })()
        """
        guard let arr = try? await webView.evaluateJavaScript(js) as? [String], arr.count == 5 else { return nil }
        return ElementInfo(tag: arr[0], type: arr[1].lowercased(), isSubmit: arr[2] == "1", inPasswordForm: arr[3] == "1", label: arr[4])
    }

    /// Moves a visible cursor to the element so you can follow what the model does.
    private func showCursor(on id: Int, ripple: Bool) async {
        let js = """
        (() => {
          const el = document.querySelector('[data-synapse-id="\(id)"]'); if (!el) return;
          el.scrollIntoView({block: 'center', behavior: 'instant'});
          const r = el.getBoundingClientRect();
          let c = document.getElementById('__synapse_cursor');
          if (!c) {
            c = document.createElement('div'); c.id = '__synapse_cursor';
            c.style.cssText = 'position:fixed;z-index:2147483647;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;background:#3d7bff;box-shadow:0 0 0 4px rgba(61,123,255,.25),0 2px 6px rgba(0,0,0,.3);pointer-events:none;transition:left .35s ease,top .35s ease;left:50vw;top:50vh';
            document.documentElement.appendChild(c);
          }
          requestAnimationFrame(() => { c.style.left = (r.left + r.width/2) + 'px'; c.style.top = (r.top + r.height/2) + 'px'; });
          if (\(ripple ? "true" : "false")) setTimeout(() => {
            const w = document.createElement('div');
            w.style.cssText = 'position:fixed;z-index:2147483646;width:10px;height:10px;margin:-5px 0 0 -5px;border-radius:50%;border:2px solid #3d7bff;pointer-events:none;transition:all .45s ease-out;opacity:1;left:' + (r.left + r.width/2) + 'px;top:' + (r.top + r.height/2) + 'px';
            document.documentElement.appendChild(w);
            requestAnimationFrame(() => { w.style.width = w.style.height = '44px'; w.style.margin = '-22px 0 0 -22px'; w.style.opacity = '0'; });
            setTimeout(() => w.remove(), 500);
          }, 380);
        })()
        """
        _ = try? await webView.evaluateJavaScript(js)
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    func click(_ id: Int) async -> String {
        agentActive = true
        lastAgentAction = "Clicking"
        await showCursor(on: id, ripple: true)
        let js = """
        (() => { const el = document.querySelector('[data-synapse-id="\(id)"]'); if (!el) return 'not found';
          el.scrollIntoView({block: 'center'}); el.focus(); el.click(); return 'ok'; })()
        """
        let r = (try? await webView.evaluateJavaScript(js) as? String) ?? "error"
        if r != "ok" { return "Element \(id) wasn't found. Call browser_read to refresh the element numbers." }
        await waitForLoad()
        return "Clicked. " + (await readPage())
    }

    func type(_ id: Int, text: String, submit: Bool) async -> String {
        agentActive = true
        lastAgentAction = "Typing"
        await showCursor(on: id, ripple: false)
        let payload = (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)) ?? "[\"\"]"
        let js = """
        (() => { const el = document.querySelector('[data-synapse-id="\(id)"]'); if (!el) return 'not found';
          const v = \(payload)[0]; el.scrollIntoView({block: 'center'}); el.focus();
          if (el.isContentEditable) { el.innerText = v; }
          else { const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                 const setter = Object.getOwnPropertyDescriptor(proto, 'value'); setter ? setter.set.call(el, v) : (el.value = v); }
          el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true}));
          if (\(submit ? "true" : "false")) {
            el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
            if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
          }
          return 'ok'; })()
        """
        let r = (try? await webView.evaluateJavaScript(js) as? String) ?? "error"
        if r != "ok" { return "Element \(id) wasn't found. Call browser_read to refresh the element numbers." }
        if submit { await waitForLoad() }
        return "Typed. " + (submit ? await readPage() : "")
    }

    func scroll(_ direction: String) async -> String {
        agentActive = true
        lastAgentAction = "Scrolling"
        let dy = direction == "up" ? "-window.innerHeight*0.8" : "window.innerHeight*0.8"
        _ = try? await webView.evaluateJavaScript("window.scrollBy(0, \(dy)); 'ok'")
        try? await Task.sleep(nanoseconds: 400_000_000)
        return await readPage()
    }

    func back() async -> String {
        webView.goBack()
        await waitForLoad()
        return await readPage()
    }

    func screenshot() async -> URL? {
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = Paths.images.appendingPathComponent("browser-\(Int(Date().timeIntervalSince1970)).png")
        try? png.write(to: url)
        return url
    }
}
