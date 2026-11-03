import SwiftUI
@preconcurrency import WebKit

@MainActor
final class MihoyoVerificationModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(String)
        case submitting
        case completed
        case failed(String)
    }

    @Published var phase: Phase = .idle
    private var originalChallenge = ""
    private var targetGame: GameID = .genshin

    func start(cookie: String, game: GameID) {
        guard phase == .idle else { return }
        targetGame = game
        phase = .loading
        Task {
            do {
                let challenge = try await MihoyoClient.shared.createVerification(cookie: cookie, game: game)
                originalChallenge = challenge.challenge
                phase = .ready(Self.html(for: challenge))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func submit(_ values: [String: String], state: AppState) {
        guard !originalChallenge.isEmpty,
              let challenge = values["geetest_challenge"],
              let validate = values["geetest_validate"],
              let seccode = values["geetest_seccode"] else {
            phase = .failed("验证服务未返回完整结果")
            return
        }
        phase = .submitting
        Task {
            DiagnosticLog.write(
                "geetest solved: challenge=\(challenge.count), validate=\(validate.count), " +
                "seccode=\(seccode.count), jordan=\(seccode.hasSuffix("|jordan")), " +
                "original match=\(challenge == originalChallenge)"
            )
            await MihoyoClient.shared.setVerificationSolution(
                // The game-record API expects the challenge returned by
                // Geetest's getValidate(), not the seed challenge used to
                // initialise the widget. They are normally different.
                MihoyoGeetestSolution(game: targetGame, challenge: challenge, validate: validate, seccode: seccode)
            )
            await state.refresh()
            if state.requiresMihoyoVerification {
                phase = .failed("验证已提交，但米游社仍要求重试")
            } else if let error = state.lastError {
                phase = .failed(error)
            } else {
                phase = .completed
            }
        }
    }

    func retry(cookie: String, game: GameID) {
        phase = .idle
        start(cookie: cookie, game: game)
    }

    private static func html(for challenge: MihoyoGeetestChallenge) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="referrer" content="no-referrer">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { height: 100%; margin: 0; background: transparent; font-family: -apple-system; }
            #status { color: #6b7280; text-align: center; padding-top: 110px; font-size: 14px; }
          </style>
        </head>
        <body><div id="status">正在加载米游社官方验证…</div></body>
        <script src="https://static.geetest.com/static/js/gt.0.5.0.js"></script>
        <script>
          initGeetest({
            gt: "\(challenge.gt)",
            challenge: "\(challenge.challenge)",
            new_captcha: \(challenge.newCaptcha),
            api_server: "api.geetest.com",
            https: true,
            product: "bind",
            lang: "zh-cn"
          }, function(captcha) {
            captcha.onReady(function() {
              document.getElementById('status').style.display = 'none';
              captcha.verify();
            });
            captcha.onSuccess(function() {
              window.webkit.messageHandlers.gamePulseGeetest.postMessage(captcha.getValidate());
              document.body.innerHTML = '<div id="status">验证成功，正在刷新数据…</div>';
            });
            captcha.onError(function() {
              document.getElementById('status').innerText = '验证加载失败，请重试';
            });
          });
        </script>
        </html>
        """
    }
}

struct MihoyoVerificationView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = MihoyoVerificationModel()

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("米游社人机验证").font(.title3.bold())
                Text("请由你亲自完成官方滑块或点选验证")
                    .font(.caption).foregroundStyle(.secondary)
            }

            content
                .frame(width: 480, height: 440)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(20)
        .frame(width: 520, height: 550)
        .onAppear {
            model.start(cookie: state.settings.mihoyoCookie, game: verificationTarget)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("正在创建官方验证…")
        case .ready(let html):
            GeetestWebView(html: html) { values in
                model.submit(values, state: state)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        case .submitting:
            ProgressView("验证成功，正在重新读取游戏数据…")
        case .completed:
            ContentUnavailableView(
                "数据已恢复",
                systemImage: "checkmark.circle.fill",
                description: Text("可以关闭此窗口并查看菜单栏面板。")
            )
        case .failed(let message):
            VStack(spacing: 12) {
                ContentUnavailableView("验证失败", systemImage: "exclamationmark.triangle", description: Text(message))
                Button("重试") {
                    model.retry(cookie: state.settings.mihoyoCookie, game: verificationTarget)
                }
            }
        }
    }

    private var verificationTarget: GameID {
        state.games.first(where: { ($0.message ?? "").contains("人机验证") })?.id ?? .genshin
    }
}

private struct GeetestWebView: NSViewRepresentable {
    let html: String
    let onResult: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "gamePulseGeetest")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(html, baseURL: URL(string: "https://webstatic.mihoyo.com/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) { }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "gamePulseGeetest")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onResult: ([String: String]) -> Void

        init(onResult: @escaping ([String: String]) -> Void) {
            self.onResult = onResult
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let values = message.body as? [String: String] else { return }
            DispatchQueue.main.async { self.onResult(values) }
        }
    }
}
