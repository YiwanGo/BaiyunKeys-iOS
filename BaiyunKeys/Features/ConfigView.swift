import SwiftUI

private let webVersionURL = URL(string: "https://baiyunkeys-web.pages.dev/")!
private let projectRepoURL = URL(string: "https://github.com/YiwanGo/BaiyunKeys-iOS")!

struct ConfigView: View {
    @Environment(AppStore.self) private var store
    @Environment(UnlockService.self) private var unlocker
    @Environment(\.openURL) private var openURL

    @State private var editing: DoorConfig?
    @State private var phone = ""
    @State private var idCard = ""
    @State private var openIdInput = ""
    @State private var smPublicKeyInput = ""
    @State private var smPrivateKeyInput = ""
    @State private var fetching = false
    @State private var toast: Toast?
    @State private var confirmingClearAll = false
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    /// 单个门禁的二维码预览
    @State private var qrDoor: DoorConfig?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    doorListCard
                    // 默认隐藏，由 RootView 的连点入口切换
                    if store.showAutoFetch {
                        autoFetchCard
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    transferCard
                    preferenceCard
                    webVersionCard
                    aboutCard
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("参数配置")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(item: $editing) { config in
            DoorEditorView(config: config) { saved in
                store.save(saved)
                toast = Toast(text: "已保存 \(saved.displayName)", isError: false)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .animation(.snappy, value: toast)
        .alert("清空全部门禁？", isPresented: $confirmingClearAll) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAllDoors() }
        } message: {
            Text("将删除全部 \(store.doors.count) 套门禁参数，此操作不可撤销。")
        }
        .onAppear(perform: consumePendingEdit)
        .onChange(of: store.pendingEditDoorID) { _, _ in consumePendingEdit() }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet { text in
                let parsed = DoorTextParser.parse(text)
                if parsed.isEmpty {
                    toast = Toast(text: "未能从内容识别出门禁参数", isError: true)
                    Haptics.notify(.error)
                    return false
                }
                let added = store.merge(parsed)
                toast = Toast(text: "识别 \(parsed.count) 条，新增 \(added) 条", isError: false)
                Haptics.notify(.success)
                return true
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(text: store.doors.map(exportText).joined(separator: "\n\n"),
                        doorCount: store.doors.count)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $qrDoor) { door in
            DoorQRSheet(door: door, text: exportText(door))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 门禁列表

    private var doorListCard: some View {
        Card {
            CardHeader(title: "门禁列表", subtitle: "共 \(store.doors.count) 套参数", symbol: "list.bullet.rectangle", tint: Theme.info)

            if store.doors.isEmpty {
                EmptyStateView(symbol: "tray", title: "尚未添加门禁", message: "手动新增，或用下方「自动获取」一键导入。")
            } else {
                VStack(spacing: 10) {
                    ForEach(store.doors) { door in
                        doorRow(door)
                    }
                }
            }

            FilledButton(title: "新增门禁", symbol: "plus") {
                editing = DoorConfig()
            }
        }
    }

    private func doorRow(_ door: DoorConfig) -> some View {
        let isCurrent = door.id == store.current?.id
        return HStack(spacing: 12) {
            Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isCurrent ? Theme.brand : Theme.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text(door.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(door.maskedMac(hidden: store.hideSensitive))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)

            if !door.isUsable {
                Badge(text: "待补全", tint: Theme.warn)
            }

            Menu {
                Button { editing = door } label: { Label("编辑", systemImage: "square.and.pencil") }
                Button { copy(door) } label: { Label("复制参数", systemImage: "doc.on.doc") }
                Button {
                    copyDirectURL(door)
                } label: {
                    // 多 Text 模式：iOS 15+ Menu 会把第 1 段当标题、第 2 段当副标显示。
                    Text("复制直达链接")
                    Text("仅本机可用")
                    Image(systemName: "link")
                }
                Button { qrDoor = door } label: { Label("查看二维码", systemImage: "qrcode") }
                Button(role: .destructive) { store.delete(id: door.id) } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(12)
        .background(isCurrent ? Theme.brandSoft : Theme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(id: door.id)
            Haptics.tap(.light)
        }
    }

    // MARK: - 自动获取

    private var autoFetchCard: some View {
        @Bindable var store = store

        return Card {
            CardHeader(title: "自动获取配置", subtitle: "从官方拉取已授权门禁", symbol: "antenna.radiowaves.left.and.right", tint: Theme.info)

            PrefMenuRow(title: "方式",
                        subtitle: fetchMethodSubtitle,
                        current: store.fetchMethod.pickerLabel) {
                Picker("方式", selection: $store.fetchMethod) {
                    ForEach(AppStore.FetchMethod.allCases) { method in
                        Text(method.pickerLabel).tag(method)
                    }
                }
            }

            FlatField(title: "手机号", placeholder: "请输入绑定的手机号", text: $phone, keyboard: .numberPad)

            Group {
                switch store.fetchMethod {
                case .idcard:
                    FlatField(title: "身份证号", placeholder: "请输入身份证号码", text: $idCard, autocapitalization: .characters)
                    Text("手机号与身份证号会直接发给官方服务器换取门禁参数，不经过任何第三方，也不会保存下来。执行前请先在官方 App 退出登录，避免会话冲突。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)

                case .openid:
                    FlatField(title: "微信 OpenID", placeholder: "请输入本人的微信 OpenID", text: $openIdInput)
                    Text("手机号会用官方 RSA 公钥加密后，连同本人微信 OpenID 一起发去官方换取门禁参数。OpenID 是账号身份标识，需自行获取一次，本机会记住免得重填。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)

                case .openid_sm2:
                    FlatField(title: "微信 OpenID", placeholder: "请输入本人的微信 OpenID", text: $openIdInput)
                    FlatField(title: "SM2 公钥", placeholder: "04 开头，130 字符 hex", text: $smPublicKeyInput, monospaced: true)
                    FlatField(title: "SM2 私钥", placeholder: "64 字符 hex", text: $smPrivateKeyInput, monospaced: true)
                    Text("把本地生成的 SM2 公钥告诉服务器，之后服务器返回的每把门禁 key 都用这个公钥加密，本机用对应 SM2 私钥解回明文。公/私钥都存在本机，私钥等同实体钥匙，请妥善保管。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            FilledButton(
                title: fetching ? "获取中…" : "获取配置",
                symbol: fetching ? nil : "arrow.down.circle",
                tint: Theme.info,
                enabled: !fetching && canFetch
            ) {
                Task { await fetchConfigs() }
            }
        }
        .onAppear {
            // 首次进入时把本机记住的 OpenID / SM2 公/私钥回填到输入框
            if openIdInput.isEmpty { openIdInput = store.openId }
            if smPublicKeyInput.isEmpty { smPublicKeyInput = store.smPublicKey }
            if smPrivateKeyInput.isEmpty { smPrivateKeyInput = store.smPrivateKey }
        }
    }

    private var fetchMethodSubtitle: String {
        switch store.fetchMethod {
        case .idcard:     return "需要本人身份证号"
        case .openid:     return "免身份证，需本人 OpenID"
        case .openid_sm2: return "加密下发，需本人 OpenID + SM2 公/私钥"
        }
    }

    private var canFetch: Bool {
        switch store.fetchMethod {
        // 加密版不传 xx 字段服务器就不加密下发,等效 openid 方式,用不上,按钮置灰
        case .openid_sm2: return false
        case .idcard:     return phone.count >= 11 && idCard.count >= 15
        case .openid:     return phone.count >= 11 && openIdInput.trimmingCharacters(in: .whitespaces).count >= 8
        }
    }

    private func fetchConfigs() async {
        fetching = true
        defer { fetching = false }
        do {
            let entrances: [BaiyunAPI.Entrance]
            switch store.fetchMethod {
            case .idcard:
                let auth = try await BaiyunAPI.login(phone: phone, idCard: idCard)
                entrances = try await BaiyunAPI.entranceGuards(auth: auth)
                await BaiyunAPI.logout(auth: auth)

            case .openid:
                let normalized = openIdInput.trimmingCharacters(in: .whitespaces)
                entrances = try await BaiyunAPI.entranceGuards(byPhone: phone, openId: normalized)
                store.openId = normalized   // 成功一次后本机记住，下次免重填

            case .openid_sm2:
                let normalizedOpenId = openIdInput.trimmingCharacters(in: .whitespaces)
                let pub  = smPublicKeyInput.trimmingCharacters(in: .whitespaces)
                let priv = smPrivateKeyInput.trimmingCharacters(in: .whitespaces)
                entrances = try await Activation.fetchDecryptedGuards(
                    phone: phone, openId: normalizedOpenId,
                    smPublicKey: pub, smPrivateKey: priv
                )
                store.openId = normalizedOpenId
                store.smPublicKey = pub
                store.smPrivateKey = priv
            }

            guard !entrances.isEmpty else {
                toast = Toast(text: "接口未返回门禁数据，请核对信息", isError: true)
                return
            }
            let added = store.merge(entrances.map(\.asDoorConfig))
            let missingName = entrances.filter { $0.bluetoothName.isEmpty }.count
            var message = "成功导入 \(entrances.count) 条，新增 \(added) 条"
            if missingName > 0 { message += "；有 \(missingName) 条缺蓝牙名称，需手动补全" }
            toast = Toast(text: message, isError: missingName > 0)
            Haptics.notify(missingName > 0 ? .warning : .success)
        } catch {
            toast = Toast(text: error.localizedDescription, isError: true)
            Haptics.notify(.error)
        }
    }

    // MARK: - 导入 / 导出

    private var transferCard: some View {
        Card {
            CardHeader(title: "导入 / 导出", subtitle: "在设备之间搬运门禁参数", symbol: "arrow.left.arrow.right")

            Text("导出的内容包含门禁 Key，等同实体钥匙，请勿发到聊天群或公开位置。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                QuietButton(title: "导入", symbol: "square.and.arrow.down", tint: Theme.brand) {
                    showImportSheet = true
                }
                QuietButton(title: "导出", symbol: "square.and.arrow.up", tint: Theme.info) {
                    if store.doors.isEmpty {
                        toast = Toast(text: "还没有可导出的门禁", isError: true)
                    } else {
                        showExportSheet = true
                    }
                }
                Spacer()
            }
        }
    }

    private func copy(_ door: DoorConfig) {
        UIPasteboard.general.string = exportText(door)
        toast = Toast(text: "已复制 \(door.displayName)", isError: false)
    }

    /// 复制 `baiyunkeys://unlock?door=<id>` 到剪贴板。id 是本机生成，别的设备无法用。
    /// 用途：贴 NFC 标签、生成二维码、写入本机快捷指令 / 主屏书签。
    private func copyDirectURL(_ door: DoorConfig) {
        UIPasteboard.general.string = "baiyunkeys://unlock?door=\(door.id)"
        toast = Toast(text: "已复制直达链接", isError: false)
    }

    private func exportText(_ door: DoorConfig) -> String {
        """
        门禁名称：\(door.displayName)
        门禁 MAC：\(door.mac)
        门禁 Key：\(door.key)
        蓝牙名称：\(door.bluetoothName)
        """
    }


    // MARK: - 偏好

    private var preferenceCard: some View {
        @Bindable var store = store

        return Card {
            CardHeader(title: "偏好设置", subtitle: "开锁行为与显示", symbol: "gearshape.fill", tint: Theme.textSecondary)

            Group {
                FlatToggle(title: "掩码显示", subtitle: "列表与详情里隐藏 MAC 和 Key", isOn: $store.hideSensitive)
                Divider().overlay(Theme.separator)
                FlatToggle(title: "触感反馈", subtitle: "开关 / 步进 / 按钮 / 开锁完成时的震动", isOn: $store.haptics)
                Divider().overlay(Theme.separator)
                FlatToggle(title: "打开即开锁",
                           subtitle: store.autoUnlockOnForeground
                            ? "快速模式已接管，暂时无法调整"
                            : "进入首页后自动尝试一次（需已授权过设备）",
                           isOn: $store.quickUnlock)
                    .disabled(store.autoUnlockOnForeground)
                if store.quickUnlock {
                    FlatToggle(title: "切回也开锁",
                               subtitle: store.autoUnlockOnForeground
                                ? "快速模式已接管，暂时无法调整"
                                : "从后台切回前台时也自动尝试一次",
                               isOn: $store.unlockOnResume)
                        .disabled(store.autoUnlockOnForeground)
                }
                Divider().overlay(Theme.separator)
                FlatToggle(title: "失败自动重试", subtitle: "连接或握手超时后自动再试", isOn: $store.autoRetry)
            }

            Group {
                if store.autoRetry {
                    StepperRow(title: "最大重试次数", subtitle: "含首次尝试", unit: " 次",
                               value: $store.autoRetryCount, range: AppStore.autoRetryCountRange)
                }
                StepperRow(title: "单次连接超时", subtitle: "单次连接的等待上限", unit: " 秒",
                           value: $store.scanTimeout, range: AppStore.scanTimeoutRange)
                FlatToggle(title: "保存开锁记录", subtitle: "关掉后不再记录新的开锁结果；已有记录保留", isOn: $store.saveHistory)
            }

            Divider().overlay(Theme.separator)
            Group {
                FlatToggle(title: "启用生物识别", subtitle: "启动 App 时用 Face ID / Touch ID 验证", isOn: $store.requireBiometric)
                PrefMenuRow(title: "外观", subtitle: "深色模式跟随系统或强制指定", current: store.theme.label) {
                    Picker("外观", selection: $store.theme) {
                        ForEach(AppStore.Theme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 网页版

    private var webVersionCard: some View {
        Card {
            CardHeader(title: "网页版钥匙",
                       subtitle: "App 失效时的备用方案",
                       symbol: "globe",
                       tint: Theme.warn)

            Text("由于没有 Apple 开发者证书，本 App 无法上架 App Store；用 p12 / Apple ID 签名安装的版本又经常遇到掉签或过期打不开。这时可以用网页版继续开门——数据格式与本 App 互通，导出粘过去即可。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            FilledButton(title: "访问网页版", symbol: "safari") {
                openURL(webVersionURL)
            }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        Card {
            CardHeader(title: "关于", subtitle: "运行环境与说明", symbol: "info.circle", tint: Theme.textSecondary)
                .overlay(alignment: .trailing) {
                    Link(destination: projectRepoURL) {
                        Image("github")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

            VStack(spacing: 8) {
                aboutRow("App 版本", Self.appVersion)
                aboutRow("iOS 版本", UIDevice.current.systemVersion)
                aboutRow("蓝牙状态", unlocker.bluetoothStatus)
            }

            Text("本 App 只在本机复用你已获授权的门禁凭据，不含任何破解或绕过逻辑，也不会把门禁参数上传到任何服务器。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            if store.showAutoFetch {
                FilledButton(title: "访问项目仓库", tint: Theme.textSecondary) {
                    openURL(projectRepoURL)
                }
                FilledButton(title: "清空全部门禁", symbol: "trash", tint: Theme.danger) {
                    if store.doors.isEmpty {
                        toast = Toast(text: "没有可清空的门禁", isError: true)
                    } else {
                        confirmingClearAll = true
                    }
                }
            }
        }
    }

    private func aboutRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func clearAllDoors() {
        let count = store.doors.count
        for door in store.doors { store.delete(id: door.id) }
        toast = Toast(text: "已清空 \(count) 套门禁", isError: false)
        Haptics.notify(.success)
    }

    /// 消化首页「编辑」按钮传过来的意图：找到对应门禁就弹编辑框，
    /// 找不到（比如刚被删）就悄悄清空标记。
    private func consumePendingEdit() {
        guard let id = store.pendingEditDoorID else { return }
        if let door = store.doors.first(where: { $0.id == id }) {
            editing = door
        }
        store.pendingEditDoorID = nil
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

// MARK: - 文本解析

enum DoorTextParser {
    static func parse(_ text: String) -> [DoorConfig] {
        var results: [DoorConfig] = []
        var current = DoorConfig()
        var hasContent = false

        func flush() {
            if hasContent, !current.mac.isEmpty, !current.key.isEmpty {
                results.append(current)
            }
            current = DoorConfig()
            hasContent = false
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { flush(); continue }
            guard let value = value(of: line) else { continue }

            if line.contains("名称"), line.contains("蓝牙") {
                current.bluetoothName = value.uppercased()
            } else if line.contains("名称") {
                current.name = value
            } else if line.uppercased().contains("MAC") {
                current.mac = Hex.formatMac(value)
            } else if line.uppercased().contains("KEY") {
                current.key = Hex.sanitizeKey(value)
            } else {
                continue
            }
            hasContent = true
        }
        flush()
        return results
    }

    private static func value(of line: String) -> String? {
        for separator in ["：", ":", "=", " "] {
            if let range = line.range(of: separator) {
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

// MARK: - Toast

struct Toast: Equatable {
    let text: String
    let isError: Bool
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(toast.isError ? Theme.danger : Theme.brand, in: Capsule())
        .padding(.horizontal, Theme.pagePadding)
    }
}

// MARK: - 导入 / 导出 sheet

enum TransferMode: String, CaseIterable, Identifiable {
    case text, qr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "文本"
        case .qr:   return "二维码"
        }
    }
}

/// 导入弹窗：文本粘贴 or 二维码扫描。`onImport` 返回 true 时关闭。
struct ImportSheet: View {
    /// 处理导入内容。返回 true 表示成功，弹窗关闭；false 表示失败（比如没识别出参数），弹窗保留。
    let onImport: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var mode: TransferMode
    @State private var pasted = ""

    init(initialMode: TransferMode = .text, onImport: @escaping (String) -> Bool) {
        self.onImport = onImport
        self._mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("方式", selection: $mode) {
                    ForEach(TransferMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Group {
                    switch mode {
                    case .text:
                        textImport
                    case .qr:
                        qrImport
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("导入门禁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var textImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴从本 App 或网页版导出的门禁参数文本。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            TextEditor(text: $pasted)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 200)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                QuietButton(title: "从剪贴板粘贴", symbol: "doc.on.clipboard", tint: Theme.textSecondary) {
                    if let s = UIPasteboard.general.string, !s.isEmpty {
                        pasted = s
                    }
                }
                Spacer()
            }

            FilledButton(title: "导入", symbol: "square.and.arrow.down",
                         enabled: !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                if onImport(pasted) { dismiss() }
            }
        }
    }

    private var qrImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            if QRScannerView.isSupported {
                QRScannerView(onScan: { payload in
                    _ = onImport(payload)
                }, onDismiss: { dismiss() })
                .frame(maxWidth: .infinity, minHeight: 340)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("对准另一台设备的导出二维码即可自动识别。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("此设备不支持相机扫码（需要 iPhone XS / XR 及以后），请改用文本模式。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding()
            }
        }
    }
}

/// 导出弹窗：文本预览+复制 or 二维码显示。
struct ExportSheet: View {
    let text: String
    let doorCount: Int

    @Environment(\.dismiss) private var dismiss
    @State private var mode: TransferMode = .text

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("共 \(doorCount) 套门禁参数。含门禁 Key，等同实体钥匙，请勿发到聊天群或公开位置。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                Picker("方式", selection: $mode) {
                    ForEach(TransferMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Group {
                    switch mode {
                    case .text:
                        textExport
                    case .qr:
                        qrExport
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("导出门禁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var textExport: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 200, maxHeight: 320)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            FilledButton(title: "复制到剪贴板", symbol: "doc.on.doc", tint: Theme.info) {
                UIPasteboard.general.string = text
                Haptics.notify(.success)
                dismiss()
            }
        }
    }

    private var qrExport: some View {
        VStack(alignment: .center, spacing: 10) {
            if let image = QRCode.image(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("让另一台设备用「导入 → 二维码」对准即可。门禁多时二维码会很密，靠近扫。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Text("生成二维码失败——门禁数据可能超出二维码容量。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 单个门禁的二维码预览：另一台设备用「导入 → 二维码」扫这里就能拿到这一条参数。
struct DoorQRSheet: View {
    let door: DoorConfig
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .center, spacing: 12) {
                Text(door.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                if let image = QRCode.image(from: text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("另一台设备用「导入 → 二维码」对准即可拿到这套参数。含门禁 Key，等同实体钥匙。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                } else {
                    Text("生成二维码失败。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .navigationTitle("二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
