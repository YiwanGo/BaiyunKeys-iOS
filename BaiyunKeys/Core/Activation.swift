import Foundation

/// 「手机号 + OpenID + SM2 加密版」自动获取:换 token → 送公钥握手 → 拉门禁列表 → 本地按需 SM2 解。
/// 服务器按 RSA payload 是否带 xx 字段决定返明文还是密文,两种都兼容:
/// 明文直接用,密文才走 SM2 解密。
/// 解密算法由外部通过 `Sm2DecryptHook.decrypt` 注入,本模块本身不实现 SM2。
enum Activation {

    enum Failure: LocalizedError {
        case invalidPublicKey
        case invalidPrivateKey
        case allDecryptionFailed
        case noUsableGuards

        var errorDescription: String? {
            switch self {
            case .invalidPublicKey:    return "SM2 公钥格式不对（应为 130 字符 hex,04 开头）"
            case .invalidPrivateKey:   return "SM2 私钥格式不对（应为 64 字符 hex）"
            case .allDecryptionFailed: return "全部密文解密失败,公/私钥可能对不上"
            case .noUsableGuards:      return "获取失败,服务器未返回任何可用门禁"
            }
        }
    }

    /// 判断服务器返回的 productKey 是明文(可直接用)还是密文(需要 SM2 解)。
    private static func isPlainKey(_ hex: String) -> Bool {
        let clean = hex.filter { $0.isHexDigit }
        return clean.count >= 16 && clean.count <= 32 && clean.count % 2 == 0
    }

    /// 一次性走完整套流程。
    static func fetchDecryptedGuards(
        phone: String,
        openId: String,
        smPublicKey: String,
        smPrivateKey: String
    ) async throws -> [BaiyunAPI.Entrance] {
        let pub  = smPublicKey.trimmingCharacters(in: .whitespaces)
        let priv = smPrivateKey.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .filter { $0.isHexDigit }
        guard pub.count == 130, pub.hasPrefix("04") else { throw Failure.invalidPublicKey }
        guard priv.count == 64 else { throw Failure.invalidPrivateKey }

        let accessToken = try await BaiyunAPI.checkState(openId: openId)
        _ = try await BaiyunAPI.goHomeServiceLogin(
            openId: openId, loginToken: "",
            smPublicKey: pub, accessToken: accessToken
        )

        let encrypted = try await BaiyunAPI.encryptedEntranceGuards(
            phone: phone, accessToken: accessToken
        )

        var results: [BaiyunAPI.Entrance] = []
        var encryptedCount = 0
        for item in encrypted {
            // 明文:直接当门禁 key 用,SM2 用不上
            if isPlainKey(item.encryptedKey) {
                let key = item.encryptedKey.uppercased().filter { $0.isHexDigit }
                results.append(BaiyunAPI.Entrance(
                    name: item.name, mac: item.mac,
                    key: key, bluetoothName: item.bluetoothName
                ))
                continue
            }
            // 密文:走 SM2 解密
            guard let decrypt = Sm2DecryptHook.decrypt else { continue }
            encryptedCount += 1
            do {
                let plaintextHex = try decrypt(item.encryptedKey, priv)
                let key = plaintextHex.uppercased().filter { $0.isHexDigit }
                guard !key.isEmpty else { continue }
                results.append(BaiyunAPI.Entrance(
                    name: item.name, mac: item.mac,
                    key: key, bluetoothName: item.bluetoothName
                ))
            } catch {
                continue
            }
        }

        if !encrypted.isEmpty, results.isEmpty {
            throw encryptedCount > 0 ? Failure.allDecryptionFailed : Failure.noUsableGuards
        }
        return results
    }
}

/// SM2 解密函数的注入点。签名 `(cipherHex, privateKeyHex) throws -> plaintextHex`。
/// App 启动时赋值 `Sm2DecryptHook.decrypt = ...`;没赋值时若服务器返密文,该条会被跳过。
enum Sm2DecryptHook {
    static var decrypt: ((_ cipherHex: String, _ privateKeyHex: String) throws -> String)?
}
