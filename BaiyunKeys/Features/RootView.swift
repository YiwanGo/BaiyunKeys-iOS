import LocalAuthentication
import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case home, config
    }

    @Environment(AppStore.self) private var store
    @Environment(UnlockService.self) private var unlocker
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .home
    @State private var didAutoUnlock = false

    // 连点「配置」tab 唤出的隐藏入口
    @State private var configTapCount = 0
    @State private var lastConfigTapAt = Date.distantPast
    @State private var askingForCode = false
    @State private var codeInput = ""

    // 生物识别锁：只在 App 冷启动时挡一次。回到前台不触发，也不会拦每次开锁。
    @State private var isAppLocked = false
    @State private var authInFlight = false
    @State private var authFailureMessage: String?
    @State private var didLaunchAuthCheck = false

    // 长辈模式拦截切到配置页时的自动消失 toast
    @State private var rootToast: Toast?
    @State private var rootToastDismissTask: Task<Void, Never>?

    /// 上一次是否真的进过 .background。iOS 回前台的转换序列是
    /// .background → .inactive → .active，`onChange` 的 `oldPhase` 只能拿到
    /// .inactive，所以用一个 flag 记录。控制中心 / 通知中心那种只到 .inactive 不算。
    @State private var wasBackgrounded = false

    /// 「切回也开锁」的节流：短时间内反复切前后台不重复触发。
    @State private var lastResumeUnlockAt: Date = .distantPast

    private static let secretCode = "123456789"
    /// 从隐藏切换到显示所需的点击次数（需再输访问码）。
    private static let tapsToShow = 10
    /// 从显示切换到隐藏所需的点击次数（无需访问码，隐藏是快操作）。
    private static let tapsToHide = 5
    /// 两次点击的最大间隔，超过则重新计数
    private static let tapWindow: TimeInterval = 1.5

    /// 把 `AppStore.Theme` 翻成 SwiftUI 的 `ColorScheme?`（nil = 跟随系统）。
    private var colorSchemeOverride: ColorScheme? {
        switch store.theme {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }

    /// TabView 每次点击都会写入 selection —— 即使值没变化。
    /// 借这一点捕获对同一个 tab 的重复点击（onChange 做不到，值没变不会触发）。
    private var selection: Binding<Tab> {
        Binding(
            get: { tab },
            set: { newValue in
                // 长辈模式下直接吞掉切到「配置」的写入，避免 TabView 切换
                // 污染 HomeView 那颗 NavigationStack 的滚动与大标题状态。
                if newValue == .config, store.elderMode {
                    flashRootToast("请先关闭长辈模式", isError: true)
                    return
                }
                if newValue == .config {
                    // 进入配置页时先做一次过期检查，24h 前开启的显示状态在此处翻回隐藏
                    store.checkAutoFetchExpiry()
                    registerConfigTap()
                } else {
                    configTapCount = 0
                }
                tab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            HomeView(selectedTab: $tab)
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(Tab.home)

            // 长辈模式下从 TabView 里移除「配置」tab，比运行时拦截更彻底。
            if !store.elderMode {
                ConfigView()
                    .tabItem { Label("配置", systemImage: "slider.horizontal.3") }
                    .tag(Tab.config)
            }
        }
        .tint(Theme.brand)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(colorSchemeOverride)
        .alert("访问码", isPresented: $askingForCode) {
            TextField("请输入访问码", text: $codeInput)
                .keyboardType(.numberPad)
            Button("取消", role: .cancel) { codeInput = "" }
            Button("确定") { submitCode() }
        } message: {
            Text("输入正确的访问码，显示「自动获取配置」。隐藏时在此页连点 5 次即可，无需访问码。")
        }
        .overlay(alignment: .top) {
            if let rootToast {
                ToastView(toast: rootToast)
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: rootToast)
        .onAppear(perform: handleLaunch)
        .onChange(of: store.elderMode) { _, on in
            // 开启长辈模式后配置 tab 已被移除；若此刻仍停在 config
            // （例如通过 URL scheme 打开），把 tab 拉回 home 保持一致。
            if on, tab == .config { tab = .home }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active:
                handlePendingIntent()
                if wasBackgrounded {
                    triggerResumeUnlockIfNeeded()
                }
                wasBackgrounded = false
            default:
                break
            }
        }
        .overlay {
            if isAppLocked {
                lockOverlay
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: isAppLocked)
    }

    // MARK: - 顶部 toast

    /// 弹一次自动消失的 toast。已经在显示时不重启计时、也不再震动，
    /// 避免快速连点不断重置计时。
    private func flashRootToast(_ text: String, isError: Bool = false) {
        guard rootToast == nil else { return }
        Haptics.notify(isError ? .warning : .success)
        rootToast = Toast(text: text, isError: isError)
        rootToastDismissTask?.cancel()
        rootToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { rootToast = nil }
            rootToastDismissTask = nil
        }
    }

    // MARK: - 生物识别

    /// 锁屏遮罩：铺满全屏，覆盖主 UI；仅在 `isAppLocked == true` 时显示。
    private var lockOverlay: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.brand)
                Text("白云钥匙已锁定")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let authFailureMessage {
                    Text(authFailureMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                FilledButton(title: authInFlight ? "验证中…" : "解锁", symbol: authInFlight ? nil : "lock.open", enabled: !authInFlight) {
                    lockAndAuthenticate()
                }
                .frame(maxWidth: 260)
            }
        }
    }

    private func lockAndAuthenticate() {
        isAppLocked = true
        guard !authInFlight else { return }
        authInFlight = true
        authFailureMessage = nil

        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 设备既未启用生物识别也未设置密码：放行，避免用户被永久锁在门外。
            authInFlight = false
            isAppLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "进入白云钥匙前确认是本人") { ok, err in
            DispatchQueue.main.async {
                authInFlight = false
                if ok {
                    authFailureMessage = nil
                    isAppLocked = false
                    handlePendingIntent()
                } else {
                    authFailureMessage = friendly(err)
                }
            }
        }
    }

    private func friendly(_ error: Error?) -> String {
        guard let laError = error as? LAError else {
            return error?.localizedDescription ?? "验证失败，请再试一次"
        }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel: return "已取消，请点「解锁」再试"
        case .biometryLockout:                        return "生物识别已锁定，请用密码解锁设备后再试"
        case .biometryNotEnrolled:                    return "尚未录入 Face ID / Touch ID"
        case .biometryNotAvailable:                   return "设备不支持生物识别"
        case .passcodeNotSet:                         return "设备未设置密码"
        default:                                       return "验证失败：\(laError.localizedDescription)"
        }
    }

    // MARK: - 隐藏入口
    //
    // 注：如果你 fork 本项目并计划开源，请不要在 README 里直接说明
    // 这里的开启流程（连点次数、访问码等）。默认隐藏的本意就是不把
    // 钥匙摆在门口。对想了解的人，源码本身已经说明了一切。

    private func registerConfigTap() {
        let now = Date()
        configTapCount = now.timeIntervalSince(lastConfigTapAt) < Self.tapWindow ? configTapCount + 1 : 1
        lastConfigTapAt = now

        // 非对称：显示中连点 5 次直接隐藏（快），隐藏中连点 10 次再验访问码（慢）
        if store.showAutoFetch {
            guard configTapCount >= Self.tapsToHide else { return }
            configTapCount = 0
            withAnimation(.snappy(duration: 0.28)) {
                store.setAutoFetchVisible(false)
            }
            Haptics.notify(.success)
            return
        }

        guard configTapCount >= Self.tapsToShow else { return }
        configTapCount = 0
        codeInput = ""
        askingForCode = true
        Haptics.tap(.rigid)
    }

    private func submitCode() {
        let matched = codeInput == Self.secretCode
        codeInput = ""
        guard matched else {
            Haptics.notify(.error)
            return
        }
        withAnimation(.snappy(duration: 0.28)) {
            store.setAutoFetchVisible(true)
        }
        Haptics.notify(.success)
        tab = .config
    }

    // MARK: - 启动与快捷指令

    private func handleLaunch() {
        // 启动时先做一次「自动获取」显示状态的过期检查
        store.checkAutoFetchExpiry()

        // 开着生物识别且是本进程首次启动 → 先锁定，通过后再走 pending / quickUnlock。
        // 只挡冷启动那一次；回到前台不再验证。
        if store.requireBiometric, !didLaunchAuthCheck {
            didLaunchAuthCheck = true
            lockAndAuthenticate()
            return
        }
        handlePendingIntent()
        triggerQuickUnlockIfNeeded()
    }

    /// 处理由快捷指令 / URL scheme 写入的开锁请求。生物识别通过之后调，或没开时直接调。
    private func handlePendingIntent() {
        // 每次都尝试一下 quick unlock，等 pending 处理完再决定要不要开
        defer { triggerQuickUnlockIfNeeded() }

        guard let pending = store.pendingUnlockDoorID else { return }
        store.pendingUnlockDoorID = nil

        let door = store.doors.first { $0.id == pending } ?? store.current
        guard let door, door.isUsable else { return }
        tab = .home
        store.select(id: door.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            unlocker.unlock(door, store: store)
        }
    }

    /// 冷启动那次自动开锁：快速模式在则扫描池里任一门锁；否则退回打开即开锁的当前门锁。
    /// `didAutoUnlock` 保证本进程只触发一次，避免 handleLaunch 被多次调用时重复开。
    private func triggerQuickUnlockIfNeeded() {
        guard !didAutoUnlock, !unlocker.phase.isBusy else { return }
        if store.autoUnlockOnForeground, !store.doors.filter(\.isUsable).isEmpty {
            didAutoUnlock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                unlocker.unlockAny(store: store)
            }
        } else if store.quickUnlock, let door = store.current, door.isUsable {
            didAutoUnlock = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                unlocker.unlock(door, store: store)
            }
        }
    }

    /// 从后台回前台的自动开锁：优先走快速模式；否则若「打开即开锁 + 切回也开锁」
    /// 都开着，用静默开锁跑一次当前门锁的缓存直连（没缓存就悄悄跳过）。3 秒节流。
    private func triggerResumeUnlockIfNeeded() {
        guard !unlocker.phase.isBusy else { return }

        if store.autoUnlockOnForeground, !store.doors.filter(\.isUsable).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                unlocker.unlockAny(store: store)
            }
            return
        }
        guard store.quickUnlock, store.unlockOnResume,
              let door = store.current, door.isUsable else { return }
        let now = Date()
        guard now.timeIntervalSince(lastResumeUnlockAt) > 3 else { return }
        lastResumeUnlockAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            unlocker.unlockIfCached(door, store: store)
        }
    }
}
