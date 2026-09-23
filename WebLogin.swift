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
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        let web = WKWebView(frame: .zero, configuration: cfg)
        // Более свежий User-Agent: со старым UA Discord иногда показывает
        // «обновите браузер» и не догружает свой JS.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
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

        func startPolling() {
            // Странице и её скриптам нужно время на загрузку — первая проверка чуть позже.
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.check()
            }
        }

        /// Похоже ли значение на настоящий токен Discord (не пустая строка и не случайный мусор).
        private func looksLikeToken(_ s: String) -> Bool {
            guard s.count > 20, s.count < 220 else { return false }
            return s.range(of: #"^[\w-]{15,}\.[\w-]{5,}\.[\w-]{15,}$"#, options: .regularExpression) != nil
                || s.range(of: #"^mfa\.[\w-]{80,}$"#, options: .regularExpression) != nil
        }

        private func check() {
            guard !done, let web else { return }
            attempts += 1
            let js = """
            (function(){
              try {
                var found = '';
                var chunkName = null;
                for (var k in window) {
                  if (k.indexOf('webpackChunk') === 0) { chunkName = k; break; }
                }
                if (chunkName && window[chunkName] && window[chunkName].push) {
                  window[chunkName].push([[Symbol()], {}, function(req){
                    if (!req || !req.c) return;
                    for (var key in req.c) {
                      try {
                        var exp = req.c[key].exports;
                        if (!exp || exp === window) continue;
                        if (typeof exp.getToken === 'function') {
                          var v = exp.getToken();
                          if (v) { found = v; return; }
                        }
                        if (exp.default && typeof exp.default.getToken === 'function') {
                          var v2 = exp.default.getToken();
                          if (v2) { found = v2; return; }
                        }
                        for (var sub in exp) {
                          try {
                            var candidate = exp[sub];
                            if (candidate && typeof candidate.getToken === 'function' &&
                                candidate[Symbol.toStringTag] !== 'IntlMessagesProxy') {
                              var v3 = candidate.getToken();
                              if (v3) { found = v3; return; }
                            }
                          } catch (inner) {}
                        }
                      } catch (e) {}
                    }
                  }]);
                }
                if (found) return found;
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
                guard let self, !self.done else { return }
                if let t = result as? String, self.looksLikeToken(t) {
                    self.done = true
                    self.timer?.invalidate()
                    self.onToken(t)
                    return
                }
                // Долго ничего не находится — сайт мог не догрузить скрипты, или Discord
                // снова поменял внутреннее устройство страницы. Сообщаем интерфейсу один раз.
                if self.attempts >= 20 && !self.stuckReported {
                    self.stuckReported = true
                    self.onStuck()
                }
            }
        }
    }
}
