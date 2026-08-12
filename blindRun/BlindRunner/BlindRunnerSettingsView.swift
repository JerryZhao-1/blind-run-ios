import Combine
import SwiftUI

// MARK: - Blind Runner Settings View

struct BlindRunnerSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var deletionViewModel = AccountDeletionViewModel()
    @State private var showLogoutConfirm = false
    @State private var showDeletionInitialConfirmation = false

    var body: some View {
        List {
            Section {
                settingsRow("昵称", value: appState.blindProfile?.name ?? "未填写")
                settingsRow("当前角色", value: "视障跑者")
            }

            Section {
                // 入口放设置而不是首页：首页刚按 `blind-ui-visual-benchmark-20260808.md`
                // 做过减法（主按钮吃掉内容区七成），再塞一个列表入口会把那次结论推翻。
                NavigationLink("我的跑步记录") {
                    BlindRunHistoryView()
                }
                .accessibilityLabel("我的跑步记录")
                .accessibilityHint("查看已完成陪跑的路线、里程和用时")

                NavigationLink("个人资料") {
                    BlindRunnerProfileView()
                }
                .accessibilityLabel("个人资料")
                .accessibilityHint("编辑盲人跑者资料和紧急联系人")

                // 实名是下单硬门槛（后端 403 IDENTITY_NOT_VERIFIED），引导流里「稍后再说」跳过后
                // 必须还有一条随时能走回实名页的路，否则未实名用户会被永久挡在预约之外。
                NavigationLink("实名认证") {
                    BlindIdentityVerificationView()
                }
                .accessibilityLabel("实名认证，当前状态\(appState.blindIdentityStatus.displayName)")
                .accessibilityHint("提交姓名和身份证号完成实名认证，完成后才能预约跑步")

                #if DEBUG
                if AppBuildChannel.current.allowsEnvironmentSwitcher {
                    Picker("API 环境", selection: $appState.currentEnvironment) {
                        ForEach(AppState.debugTestEnvironments, id: \.self) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    .accessibilityLabel("API 环境，\(appState.currentEnvironment.displayName)")
                }
                #endif

                NavigationLink("关于") {
                    AboutAidRunView()
                }
            }

            Section {
                Button("退出登录", role: .destructive) {
                    showLogoutConfirm = true
                }
                .accessibilityLabel("退出登录")
                .accessibilityHint("退出后需要重新登录，需要二次确认")

                Button("删除账户", role: .destructive) {
                    showDeletionInitialConfirmation = true
                }
                .disabled(appState.accountDeletionState == .inProgress)
                .accessibilityLabel("删除账户")
                .accessibilityHint("永久停用当前账户，需要再次确认")
            }

            if let message = deletionViewModel.preflightMessage {
                Section { Text(message).foregroundColor(AppColors.destructive).accessibilityLabel(message) }
            }
        }
        .navigationTitle("设置")
        .alert("确认退出", isPresented: $showLogoutConfirm) {
            Button("确认退出", role: .destructive) {
                Task { await appState.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认后将清除当前登录状态，返回登录页。")
        }
        .alert("确认删除账户", isPresented: $showDeletionInitialConfirmation) {
            Button("继续删除账户", role: .destructive) {
                Task {
                    await deletionViewModel.preflight(
                        appState: appState,
                        speechService: speechService
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("系统将先检查是否存在进行中的服务。检查通过后仍需再次确认，才会提交账户删除请求。")
        }
        .alert("最终确认删除账户", isPresented: $deletionViewModel.showFinalConfirmation) {
            Button("永久删除账户", role: .destructive) {
                Task { await appState.deleteCurrentAccount() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账户将被软删除，所有登录令牌会失效。删除成功后手机号可以重新注册。此操作不可撤销。")
        }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        BlindRunnerSettingsView()
            .environmentObject(AppState())
            .environmentObject(SpeechService())
    }
}
#endif
