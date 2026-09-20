import SwiftUI
import WebKit

struct WebLoginView: UIViewRepresentable {
    var onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.web = web
        if let url = URL(string: "https://discord.com/login") {
            web.load(URLRequest(url: url))
        }
        context.coordinator.startPolling()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject {
        let onToken: (String) -> Void
        weak var web: WKWebView?
        var timer: Timer?
        var done = false

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        deinit { timer?.invalidate() }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.check()
            }
        }

        private func check() {
            guard !done, let web else { return }
            let js = """
            (function(){
              try {
                var t = '';
                window.webpackChunkdiscord_app.push([[Math.random()], {}, function(r){
                  if (!r || !r.c) return;
                  for (var k in r.c) {
                    try {
                      var m = r.c[k].exports;
                      if (m && m.default && typeof m.default.getToken === 'function') { var v = m.default.getToken(); if (v) t = v; }
                      else if (m && typeof m.getToken === 'function') { var w = m.getToken(); if (w) t = w; }
                    } catch (e) {}
                  }
                }]);
                if (t) return t;
              } catch (e) {}
              try {
                var f = document.createElement('iframe');
                document.body.appendChild(f);
                var s = f.contentWindow.localStorage.getItem('token');
                f.remove();
                if (s) return JSON.parse(s);
              } catch (e) {}
              return '';
            })()
            """
            web.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.done,
                      let t = result as? String, t.count > 20 else { return }
                self.done = true
                self.timer?.invalidate()
                self.onToken(t)
            }
        }
    }
}
