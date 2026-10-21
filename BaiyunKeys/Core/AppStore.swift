import Foundation
import Observation

/// 全局状态：门禁列表 + 偏好设置。
@Observable
final class AppStore {

    private enum Keys {
        static let doors = "doorState"
        static let hideSensitive = "hideSensitive"
        static let quickUnlock = "quickUnlock"
        static let autoRetry = "autoRetryEnabled"
        static let autoRetryCount = "autoRetryCount"
        static let scanTimeout = "scanTimeout"
        static let showAutoFetch = "showAutoFetch"
        static let showAutoFetchAt = "showAutoFetchAt"
        static let fetchMethod = "fetchMethod"
        static let openId = "openId"
        static let smPublicKey = "smPublicKey"
        static let smPrivateKey = "smPrivateKey"
        static let theme = "theme"
        static let history = "unlockHistory"
        static let saveHistory = "saveHistory"
        static let haptics = "haptics"
        static let unlockOnResume = "unlockOnResume"
        static let requireBiometric = "requireBiometric"
        static let elderMode = "elderMode"
        static let elderLocksDoorSelector = "elderLocksDoorSelector"
        static let autoUnlockOnForeground = "autoUnlockOnForeground"
        static let elderHidesLogs = "elderHidesLogs"
        static let elderHidesHistory = "elderHidesHistory"
        static let showLogsExpanded = "showLogsExpanded"
        static let showHistoryExpanded = "showHistoryExpanded"
        static let pendingUnlockDoor = "pendingUnlockDoor"
    }

    static let historyLimit = 50

    /// 一条开锁记录（时间 + 门禁 + 成功/失败 + 失败原因）。
    struct UnlockRecord: Codable, Identifiable, Hashable {
        var id: String = UUID().uuidString
        let at: Date
        let doorId: String
        let doorName: String
        let ok: Bool
        let message: String
    }

    /// 外观：跟随系统（默认）/ 强制浅色 / 强制深色。
    enum Theme: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:  return "跟随系统"
            case .light: return "浅色"
            case .dark:  return "深色"
            }
        }
    }

    /// 「自动获取配置」显示状态的最长保留时间，超过则自动翻回隐藏。
    static let autoFetchTTL: TimeInterval = 24 * 60 * 60

    /// 「自动获取配置」的三种通道。
    enum FetchMethod: String, CaseIterable, Identifiable {
        /// 老接口：手机号 + 身份证号。目前官方端已停用。
        case idcard
        /// 手机号 + 微信 OpenID（免身份证，走 xcx.pinganbaiyun.cn）。
        case openid
        /// 手机号 + OpenID + 本地 SM2 密钥对（服务器加密下发，本机用私钥解）。
        case openid_sm2

        var id: String { rawValue }
        var pickerLabel: String {
            switch self {
            case .idcard:     return "手机号 + 身份证（接口失效）"
            case .openid:     return "手机号 + OpenID（免身份证）"
            case .openid_sm2: return "手机号 + OpenID + SM2（加密版）"
            }
        }
    }

    // MARK: - 门禁

    private(set) var state = DoorState()

    var doors: [DoorConfig] { state.items }

    var current: DoorConfig? { state.current }

    /// 从首页「编辑」按钮跳转到配置页时，携带要打开编辑弹窗的门禁 ID。
    /// 只在内存里存一次性的意图，不落盘；配置页读到后立刻清空。
    var pendingEditDoorID: String?

    // MARK: - 偏好
    //
    // 这些属性直接读写 UserDefaults。@Observable 的宏会给存储属性生成 getter，
    // 与 didSet 观察器冲突，所以这里手写 access / withMutation 保持可观察。

    /// 列表中掩码显示 MAC 与 Key。
    var hideSensitive: Bool {
        get { access(keyPath: \.hideSensitive); return bool(Keys.hideSensitive, default: true) }
        set { withMutation(keyPath: \.hideSensitive) { defaults.set(newValue, forKey: Keys.hideSensitive) } }
    }

    /// 打开 App 后自动开锁一次。
    var quickUnlock: Bool {
        get { access(keyPath: \.quickUnlock); return bool(Keys.quickUnlock, default: false) }
        set { withMutation(keyPath: \.quickUnlock) { defaults.set(newValue, forKey: Keys.quickUnlock) } }
    }

    /// 「打开即开锁」的子开关：从后台切回前台也静默尝试一次（只用缓存设备直连，
    /// 没有缓存就跳过）。默认关。仅当 `quickUnlock` 开启时才生效。
    var unlockOnResume: Bool {
        get { access(keyPath: \.unlockOnResume); return bool(Keys.unlockOnResume, default: false) }
        set { withMutation(keyPath: \.unlockOnResume) { defaults.set(newValue, forKey: Keys.unlockOnResume) } }
    }

    /// 扫描或连接超时后自动重试。
    var autoRetry: Bool {
        get { access(keyPath: \.autoRetry); return bool(Keys.autoRetry, default: true) }
        set { withMutation(keyPath: \.autoRetry) { defaults.set(newValue, forKey: Keys.autoRetry) } }
    }

    var autoRetryCount: Int {
        get { access(keyPath: \.autoRetryCount); return clamped(Keys.autoRetryCount, default: 5, in: Self.autoRetryCountRange) }
        set { withMutation(keyPath: \.autoRetryCount) { defaults.set(newValue, forKey: Keys.autoRetryCount) } }
    }

    var scanTimeout: Int {
        get { access(keyPath: \.scanTimeout); return clamped(Keys.scanTimeout, default: 10, in: Self.scanTimeoutRange) }
        set { withMutation(keyPath: \.scanTimeout) { defaults.set(newValue, forKey: Keys.scanTimeout) } }
    }

    /// 「自动获取配置」是否可见。默认隐藏，需在配置 tab 上连点 10 次并输入访问码才能显示；
    /// 显示状态最长保留 24 小时，之后由 `checkAutoFetchExpiry()` 翻回隐藏。
    /// 建议直接改用 `setAutoFetchVisible(_:)`，会一并写入时间戳。
    var showAutoFetch: Bool {
        get { access(keyPath: \.showAutoFetch); return bool(Keys.showAutoFetch, default: false) }
        set { withMutation(keyPath: \.showAutoFetch) { defaults.set(newValue, forKey: Keys.showAutoFetch) } }
    }

    /// 显示开启时刻（Unix 秒）；隐藏时为 0。
    var showAutoFetchAt: TimeInterval {
        get {
            access(keyPath: \.showAutoFetchAt)
            let raw = defaults.double(forKey: Keys.showAutoFetchAt)
            return raw > 0 ? raw : 0
        }
        set {
            withMutation(keyPath: \.showAutoFetchAt) {
                defaults.set(max(0, newValue), forKey: Keys.showAutoFetchAt)
            }
        }
    }

    /// 切换「自动获取配置」显示状态，并写入时间戳（开时=现在，关时=0）。
    func setAutoFetchVisible(_ visible: Bool) {
        showAutoFetch = visible
        showAutoFetchAt = visible ? Date().timeIntervalSince1970 : 0
    }

    /// 若「自动获取配置」已显示且距开启时间超过 24 小时，则自动翻回隐藏。
    /// 返回是否发生了翻转，方便调用侧决定是否刷新 UI。
    @discardableResult
    func checkAutoFetchExpiry(now: Date = Date()) -> Bool {
        guard showAutoFetch, showAutoFetchAt > 0 else { return false }
        guard now.timeIntervalSince1970 - showAutoFetchAt > Self.autoFetchTTL else { return false }
        setAutoFetchVisible(false)
        return true
    }

    /// 自动获取配置的方式；默认 OpenID（身份证通道已停用）。
    var fetchMethod: FetchMethod {
        get {
            access(keyPath: \.fetchMethod)
            let raw = defaults.string(forKey: Keys.fetchMethod) ?? FetchMethod.openid.rawValue
            return FetchMethod(rawValue: raw) ?? .openid
        }
        set { withMutation(keyPath: \.fetchMethod) { defaults.set(newValue.rawValue, forKey: Keys.fetchMethod) } }
    }

    /// 用于 OpenID 通道；本地记住，避免每次重填。空串代表未设置。
    var openId: String {
        get { access(keyPath: \.openId); return defaults.string(forKey: Keys.openId) ?? "" }
        set {
            withMutation(keyPath: \.openId) {
                defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.openId)
            }
        }
    }

    /// 加密版通道用的本地 SM2 公钥（hex，130 字符，04 开头）；本地记住。
    var smPublicKey: String {
        get { access(keyPath: \.smPublicKey); return defaults.string(forKey: Keys.smPublicKey) ?? "" }
        set {
            withMutation(keyPath: \.smPublicKey) {
                defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.smPublicKey)
            }
        }
    }

    /// 加密版通道用的本地 SM2 私钥（hex，64 字符）；本地记住，等同实体钥匙。
    var smPrivateKey: String {
        get { access(keyPath: \.smPrivateKey); return defaults.string(forKey: Keys.smPrivateKey) ?? "" }
        set {
            withMutation(keyPath: \.smPrivateKey) {
                defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.smPrivateKey)
            }
        }
    }

    /// 是否把新的开锁结果写进「开锁记录」。默认开；关掉后新结果不再入库，
    /// 已有记录保留不动，由用户自行清空 / 删除。
    var saveHistory: Bool {
        get { access(keyPath: \.saveHistory); return bool(Keys.saveHistory, default: true) }
        set { withMutation(keyPath: \.saveHistory) { defaults.set(newValue, forKey: Keys.saveHistory) } }
    }

    /// 触感反馈总开关。默认开；关掉后所有按钮 / 开关 / 步进 / 菜单选择 / 开锁完成的震动都停。
    /// `Haptics` 静态读同一个 UserDefaults key，`Components` 里的 `.sensoryFeedback` 也在触发闭包里查它。
    var haptics: Bool {
        get { access(keyPath: \.haptics); return bool(Keys.haptics, default: true) }
        set { withMutation(keyPath: \.haptics) { defaults.set(newValue, forKey: Keys.haptics) } }
    }

    /// 长辈模式：隐藏门禁选择器 / 编辑按钮 / 破坏性动作，拦截切到「配置」页。默认关。
    /// 设计目的：把手机给不熟悉的人用（老人、小孩、朋友）时防止误操作或误改。
    var elderMode: Bool {
        get { access(keyPath: \.elderMode); return bool(Keys.elderMode, default: false) }
        set { withMutation(keyPath: \.elderMode) { defaults.set(newValue, forKey: Keys.elderMode) } }
    }

    /// App 从后台回到前台时自动开锁一次。默认关。跟 `quickUnlock`（冷启动那次）互不干扰。
    var autoUnlockOnForeground: Bool {
        get { access(keyPath: \.autoUnlockOnForeground); return bool(Keys.autoUnlockOnForeground, default: false) }
        set { withMutation(keyPath: \.autoUnlockOnForeground) { defaults.set(newValue, forKey: Keys.autoUnlockOnForeground) } }
    }

    /// 长辈模式下是否禁用首页顶部的门禁下拉选择器。开启长辈模式时由弹窗勾选，持久化。
    /// "禁用"而不是"隐藏"：门禁名仍显示，只是不能点开菜单换门禁。
    var elderLocksDoorSelector: Bool {
        get { access(keyPath: \.elderLocksDoorSelector); return bool(Keys.elderLocksDoorSelector, default: false) }
        set { withMutation(keyPath: \.elderLocksDoorSelector) { defaults.set(newValue, forKey: Keys.elderLocksDoorSelector) } }
    }

    /// 长辈模式下是否连「运行日志」卡片也隐藏。开启长辈模式时由弹窗勾选，持久化。
    var elderHidesLogs: Bool {
        get { access(keyPath: \.elderHidesLogs); return bool(Keys.elderHidesLogs, default: false) }
        set { withMutation(keyPath: \.elderHidesLogs) { defaults.set(newValue, forKey: Keys.elderHidesLogs) } }
    }

    /// 长辈模式下是否连「开锁记录」卡片也隐藏。开启长辈模式时由弹窗勾选，持久化。
    var elderHidesHistory: Bool {
        get { access(keyPath: \.elderHidesHistory); return bool(Keys.elderHidesHistory, default: false) }
        set { withMutation(keyPath: \.elderHidesHistory) { defaults.set(newValue, forKey: Keys.elderHidesHistory) } }
    }

    /// 首页「运行日志」卡片是否展开。默认展开；持久化，重开 App 保持上次状态。
    var showLogsExpanded: Bool {
        get { access(keyPath: \.showLogsExpanded); return bool(Keys.showLogsExpanded, default: true) }
        set { withMutation(keyPath: \.showLogsExpanded) { defaults.set(newValue, forKey: Keys.showLogsExpanded) } }
    }

    /// 首页「开锁记录」卡片是否展开。默认展开；持久化，重开 App 保持上次状态。
    var showHistoryExpanded: Bool {
        get { access(keyPath: \.showHistoryExpanded); return bool(Keys.showHistoryExpanded, default: true) }
        set { withMutation(keyPath: \.showHistoryExpanded) { defaults.set(newValue, forKey: Keys.showHistoryExpanded) } }
    }

    /// 启动 App 时是否需要 Face ID / Touch ID 验证。默认关。
    var requireBiometric: Bool {
        get { access(keyPath: \.requireBiometric); return bool(Keys.requireBiometric, default: false) }
        set { withMutation(keyPath: \.requireBiometric) { defaults.set(newValue, forKey: Keys.requireBiometric) } }
    }

    /// 外观偏好；默认跟随系统。
    var theme: Theme {
        get {
            access(keyPath: \.theme)
            let raw = defaults.string(forKey: Keys.theme) ?? Theme.auto.rawValue
            return Theme(rawValue: raw) ?? .auto
        }
        set { withMutation(keyPath: \.theme) { defaults.set(newValue.rawValue, forKey: Keys.theme) } }
    }

    /// 开锁历史，最新在前。启动时从 UserDefaults 读一次。
    private(set) var history: [UnlockRecord] = []

    /// 记一条开锁结果。若「保存开锁记录」关掉则直接跳过，已有记录保留不动。
    func addUnlock(doorId: String, doorName: String, ok: Bool, message: String) {
        guard saveHistory else { return }
        let entry = UnlockRecord(at: Date(), doorId: doorId, doorName: doorName, ok: ok, message: message)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        persistHistory()
    }

    /// 删单条开锁记录。找不到就静默返回。
    func deleteUnlock(id: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history.remove(at: index)
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Keys.history)
    }

    private static func loadHistory() -> [UnlockRecord] {
        guard let data = UserDefaults.standard.data(forKey: Keys.history),
              let decoded = try? JSONDecoder().decode([UnlockRecord].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(historyLimit))
    }

    static let autoRetryCountRange = 1...20
    static let scanTimeoutRange = 3...60

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        state = Self.loadState()
        history = Self.loadHistory()
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func clamped(_ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - 增删改

    @discardableResult
    func save(_ config: DoorConfig) -> DoorConfig {
        var normalized = config
        normalized.mac = Hex.formatMac(config.mac)
        normalized.key = Hex.sanitizeKey(config.key)
        normalized.bluetoothName = config.bluetoothName.trimmingCharacters(in: .whitespaces).uppercased()
        normalized.name = config.name.trimmingCharacters(in: .whitespaces)

        if let index = state.items.firstIndex(where: { $0.id == normalized.id }) {
            // 保留已缓存的外设 UUID，除非关键参数变了
            if state.items[index].mac == normalized.mac, state.items[index].bluetoothName == normalized.bluetoothName {
                normalized.cachedPeripheralID = state.items[index].cachedPeripheralID
            }
            state.items[index] = normalized
        } else {
            state.items.append(normalized)
        }
        state.currentID = normalized.id
        persist()
        return normalized
    }

    func delete(id: String) {
        state.items.removeAll { $0.id == id }
        if state.currentID == id { state.currentID = state.items.first?.id }
        persist()
    }

    func select(id: String) {
        guard state.items.contains(where: { $0.id == id }) else { return }
        state.currentID = id
        persist()
    }

    func cachePeripheral(_ uuid: String, for id: String) {
        guard let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].cachedPeripheralID != uuid else { return }
        state.items[index].cachedPeripheralID = uuid
        persist()
    }

    func clearPeripheralCache(for id: String) {
        guard let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].cachedPeripheralID != nil else { return }
        state.items[index].cachedPeripheralID = nil
        persist()
    }

    /// 从「自动获取」或文本导入的门禁批量入库，按 MAC + Key 去重。
    @discardableResult
    func merge(_ incoming: [DoorConfig]) -> Int {
        var added = 0
        for var item in incoming {
            item.mac = Hex.formatMac(item.mac)
            item.key = Hex.sanitizeKey(item.key)
            guard Hex.isValidMac(item.mac), Hex.isValidKey(item.key) else { continue }
            if let index = state.items.firstIndex(where: { $0.mac == item.mac && $0.key == item.key }) {
                // 已存在：只补齐缺失的蓝牙名 / 名称
                if state.items[index].bluetoothName.isEmpty { state.items[index].bluetoothName = item.bluetoothName }
                if state.items[index].name.isEmpty { state.items[index].name = item.name }
            } else {
                state.items.append(item)
                added += 1
            }
        }
        if state.currentID == nil { state.currentID = state.items.first?.id }
        persist()
        return added
    }

    // MARK: - 快捷开锁待办（由 App Intent 写入）

    var pendingUnlockDoorID: String? {
        get { defaults.string(forKey: Keys.pendingUnlockDoor) }
        set { defaults.set(newValue, forKey: Keys.pendingUnlockDoor) }
    }

    // MARK: - 持久化

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        Keychain.save(data, account: Keys.doors)
    }

    private static func loadState() -> DoorState {
        guard let data = Keychain.load(account: Keys.doors),
              let decoded = try? JSONDecoder().decode(DoorState.self, from: data) else {
            return DoorState()
        }
        return decoded
    }
}
