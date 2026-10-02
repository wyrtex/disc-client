import SwiftUI
import WebKit

struct WebLoginView: UIViewRepresentable {
    var onToken: (String) -> Void
    /// Вызывается, когда автоматическое извлечение токена долго не получается —
    /// чтобы интерфейс мог показать подсказку и предложить запасной вариант.
    var onStuck: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken, onStuck: onStuck) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // ПОСТОЯННОЕ хранилище: куки-сессия Discord переживает перезапуск. Благодаря этому при
        // смерти токена повторный веб-вход уже залогинен и свежий токен ловится молча, без пароля.
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop

        // Самый надёжный способ достать токен: перехватываем заголовок Authorization у всех
        // запросов, которые Discord шлёт к своему API после входа — там и лежит токен.
        // Ставим ДО загрузки страницы (atDocumentStart), чтобы обернуть fetch/XHR раньше Discord.
        let hookJS = """
        (function(){
          if (window.__tokenHookInstalled) return;
          window.__tokenHookInstalled = true;
          window.__discordToken = '';
          function grab(v){ try { if (v && typeof v === 'string' && v.length > 20) window.__discordToken = v; } catch(e){} }
          try {
            var origSet = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.setRequestHeader = function(h, v){
              try { if (h && String(h).toLowerCase() === 'authorization') grab(v); } catch(e){}
              return origSet.apply(this, arguments);
            };
          } catch(e){}
          try {
            var origFetch = window.fetch;
            window.fetch = function(input, init){
              try {
                var hh = init && init.headers;
                if (hh) {
                  if (typeof hh.get === 'function') { grab(hh.get('Authorization') || hh.get('authorization')); }
                  else if (Array.isArray(hh)) { hh.forEach(function(p){ if (p && String(p[0]).toLowerCase()==='authorization') grab(p[1]); }); }
                  else { for (var k in hh){ if (String(k).toLowerCase()==='authorization') grab(hh[k]); } }
                }
              } catch(e){}
              return origFetch.apply(this, arguments);
            };
          } catch(e){}
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let web = WKWebView(frame: .zero, configuration: cfg)
        // Более свежий User-Agent: со старым UA Discord иногда показывает
        // «обновите браузер» и не догружает свой JS.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = URL(string: "https://discord.com/login") {
            web.load(URLRequest(url: url))
        }
        context.coordinator.startPolling()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        let onStuck: () -> Void
        weak var web: WKWebView?
        var timer: Timer?
        var done = false
        var attempts = 0
        var stuckReported = false

        init(onToken: @escaping (String) -> Void, onStuck: @escaping () -> Void) {
            self.onToken = onToken
            self.onStuck = onStuck
        }

        deinit { timer?.invalidate() }

        /// Не даём странице уйти на discord:// (иначе откроется обычное приложение Discord).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.check()
            }
        }

        private func looksLikeToken(_ s: String) -> Bool {
            let t = s.hasPrefix("Bearer ") ? String(s.dropFirst(7)) : s
            guard t.count > 20, t.count < 220 else { return false }
            return t.range(of: #"^[\w-]{15,}\.[\w-]{5,}\.[\w-]{15,}$"#, options: .regularExpression) != nil
                || t.range(of: #"^mfa\.[\w-]{80,}$"#, options: .regularExpression) != nil
        }

        private func check() {
            guard !done, let web else { return }
            attempts += 1
            // Сначала — перехваченный заголовок Authorization; если его нет, старые способы.
            let js = """
            (function(){
              try { if (window.__discordToken) return window.__discordToken; } catch(e){}
              try {
                var chunkName = null;
                for (var k in window) { if (k.indexOf('webpackChunk') === 0) { chunkName = k; break; } }
                if (chunkName && window[chunkName] && window[chunkName].push) {
                  var found = '';
                  window[chunkName].push([[Symbol()], {}, function(req){
                    if (!req || !req.c) return;
                    for (var key in req.c) {
                      try {
                        var exp = req.c[key].exports;
                        if (!exp || exp === window) continue;
                        if (typeof exp.getToken === 'function') { var v = exp.getToken(); if (v) { found = v; return; } }
                        if (exp.default && typeof exp.default.getToken === 'function') { var v2 = exp.default.getToken(); if (v2) { found = v2; return; } }
                        for (var sub in exp) {
                          try {
                            var c = exp[sub];
                            if (c && typeof c.getToken === 'function' && c[Symbol.toStringTag] !== 'IntlMessagesProxy') {
                              var v3 = c.getToken(); if (v3) { found = v3; return; }
                            }
                          } catch (inner) {}
                        }
                      } catch (e) {}
                    }
                  }]);
                  if (found) return found;
                }
              } catch (e) {}
              return '';
            })()
            """
            web.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.done else { return }
                if let raw = result as? String {
                    let t = raw.hasPrefix("Bearer ") ? String(raw.dropFirst(7)) : raw
                    if self.looksLikeToken(t) {
                        self.done = true
                        self.timer?.invalidate()
                        self.onToken(t)
                        return
                    }
                }
                if self.attempts >= 25 && !self.stuckReported {
                    self.stuckReported = true
                    self.onStuck()
                }
            }
        }
    }
}
