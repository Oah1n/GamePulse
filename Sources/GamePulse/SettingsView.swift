import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var token = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("游戏账号") {
                MihoyoLoginView()
                    .environmentObject(state)
            }

            Section("数据源") {
                TextField(
                    "数据桥地址，留空使用内置官方社区数据源",
                    text: Binding(
                        get: { state.settings.bridgeURL },
                        set: { state.settings.bridgeURL = $0 }
                    )
                )
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer Token（保存到钥匙串）", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("可选的高级数据桥会覆盖应用内置数据源。两个米游社账号的扫码凭据分开保存在当前 Mac 用户中，不会交给 GPT。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("其他官方社区") {
                SklandLoginView()
                    .environmentObject(state)
                Divider()
                KuroLoginView()
                    .environmentObject(state)
            }

            Section("刷新") {
                Picker(
                    "自动刷新",
                    selection: Binding(
                        get: { state.settings.refreshMinutes },
                        set: { state.settings.refreshMinutes = $0 }
                    )
                ) {
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
            }

            Section {
                HStack {
                    Button("保存并刷新") {
                        state.settings.bridgeToken = token
                        state.restart()
                        saved = true
                        Task { await state.refresh() }
                    }
                    if saved {
                        Label("已保存", systemImage: "checkmark").foregroundStyle(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: modelHeight)
        .onAppear {
            token = state.settings.bridgeToken
        }
    }

    private var modelHeight: CGFloat { 720 }
}
