import SwiftUI

@main
struct BaiyunKeysApp: App {
    @State private var store = AppStore()
    @State private var unlocker = UnlockService()

    init() {
        // iOS 15+ 起 UITabBar 有 standard / scrollEdge 两套 appearance，
        // scrollEdge 默认透明——ScrollView 滚到边缘时会切成它，看起来就是
        // tab bar 变透明。把两套统一成不透明的默认样式，避免边缘触发透明。
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        // 「自动获取 · 加密版」用到的 SM2 解密。调用的 SM2 实现在 Core/SM2.swift,
        // 这里把它包装成 Activation 约定的签名,支持 C1C3C2 + 带或不带 04 前缀两种格式。
        Sm2DecryptHook.decrypt = { cipherHex, privateKeyHex in
            let trimmed = cipherHex.trimmingCharacters(in: .whitespaces)
            let variants = trimmed.lowercased().hasPrefix("04")
                ? [trimmed, String(trimmed.dropFirst(2))]
                : [trimmed, "04" + trimmed]
            for variant in variants {
                let out = SM2.doDecrypt(variant, privateKey: privateKeyHex,
                                         cipherMode: 1, output: "array")
                if let bytes = out as? [UInt8], !bytes.isEmpty {
                    return bytes.map { String(format: "%02x", $0) }.joined()
                }
            }
            struct Sm2DecryptError: LocalizedError {
                var errorDescription: String? { "SM2 解密失败" }
            }
            throw Sm2DecryptError()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(unlocker)
                .tint(Theme.brand)
                .onOpenURL(perform: handleIncomingURL)
        }
    }

    /// 处理 URL scheme 触发的开锁。格式：
    /// - `baiyunkeys://unlock`               开当前默认门禁
    /// - `baiyunkeys://unlock?door=<门禁 id>`  开指定门禁
    ///
    /// 通过写入 `pendingUnlockDoorID`，走跟快捷指令完全一样的通路——
    /// `RootView.handlePendingIntent()` 会在场景变 active 时接管。
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "baiyunkeys" else { return }

        let host = url.host?.lowercased()
        let firstPath = url.pathComponents.dropFirst().first?.lowercased()
        guard host == "unlock" || firstPath == "unlock" else { return }

        let doorID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "door" })?
            .value
        // 空串表示「用当前默认门禁」；RootView 里查不到 id 时也自动 fallback
        store.pendingUnlockDoorID = doorID ?? ""
    }
}
