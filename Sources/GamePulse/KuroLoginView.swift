import SwiftUI

@MainActor
final class KuroLoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case sendingCode
        case codeSent
        case loggingIn
        case completed
        case failed(String)
    }

    @Published var phase: Phase = .idle

    func sendCode(phone: String) {
        guard let phone = Self.normalizedPhone(phone) else {
            phase = .failed("请输入 11 位中国大陆手机号")
            return
        }
        phase = .sendingCode
        Task {
            do {
                try await KuroLoginClient.shared.sendSMSCode(phone: phone)
                phase = .codeSent
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func login(phone: String, code: String, settings: SettingsStore, state: AppState) {
        guard let phone = Self.normalizedPhone(phone) else {
            phase = .failed("请输入 11 位中国大陆手机号")
            return
        }
        let cleanCode = code.filter(\.isNumber)
        guard cleanCode.count == 6 else {
            phase = .failed("请输入 6 位短信验证码")
            return
        }

        phase = .loggingIn
        Task {
            do {
                let token = try await KuroLoginClient.shared.login(phone: phone, code: cleanCode)
                settings.kuroToken = token
                phase = .completed
                await state.refresh()
                state.restart()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        phase = .idle
    }

    private static func normalizedPhone(_ value: String) -> String? {
        var digits = value.filter(\.isNumber)
        if digits.count == 13, digits.hasPrefix("86") {
            digits.removeFirst(2)
        }
        guard digits.count == 11, digits.first == "1" else { return nil }
        return digits
    }
}

struct KuroLoginView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = KuroLoginModel()
    @State private var phone = ""
    @State private var verificationCode = ""
    @State private var showingLoginForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("鸣潮 · 库街区").font(.headline)
                    Text("使用手机号和短信验证码登录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.settings.hasKuroLogin && !showingLoginForm {
                    Label("已登录", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if state.settings.hasKuroLogin && !showingLoginForm {
                HStack {
                    Button("重新登录") {
                        model.reset()
                        showingLoginForm = true
                    }
                    Button("退出登录", role: .destructive) {
                        state.settings.kuroToken = ""
                        state.restart()
                        Task { await state.refresh() }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("手机号", text: $phone)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 230)
                        Button("发送验证码") {
                            model.sendCode(phone: phone)
                        }
                        .disabled(model.isWorking)
                    }

                    HStack(spacing: 8) {
                        SecureField("短信验证码", text: $verificationCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 230)
                        Button("登录") {
                            model.login(
                                phone: phone,
                                code: verificationCode,
                                settings: state.settings,
                                state: state
                            )
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWorking || verificationCode.isEmpty)

                        if state.settings.hasKuroLogin {
                            Button("取消") {
                                showingLoginForm = false
                                model.reset()
                                phone = ""
                                verificationCode = ""
                            }
                        }
                    }

                    statusView

                    Text("手机号和验证码不会保存；仅登录 Token 保存在当前 Mac。新登录可能使手机上的库街区会话退出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .sendingCode:
            Label("正在发送验证码…", systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case .codeSent:
            Label("验证码已发送，请查收短信", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .loggingIn:
            Label("正在登录…", systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case .completed:
            Label("登录成功，正在刷新数据", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension KuroLoginModel {
    var isWorking: Bool {
        phase == .sendingCode || phase == .loggingIn
    }
}
