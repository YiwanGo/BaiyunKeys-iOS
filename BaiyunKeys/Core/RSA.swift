import Foundation
import Security

/// 服务端 `get_rsa_public_key` 下发 PEM 公钥，业务侧要求：
/// - 明文按 30 字节分块（`{"phone":"..."}` 就一块，但保留分块逻辑）；
/// - 每块 RSA/PKCS#1 v1.5 加密，密文转十六进制拼接；
/// - 末尾追加固定串 `RSA_STRTOK@@@` 才是服务端要的 `key` 字段值。
enum RSA {

    enum Failure: LocalizedError {
        case invalidPEM
        case unsupportedKey
        case chunkTooLarge
        case encrypt(String)

        var errorDescription: String? {
            switch self {
            case .invalidPEM:          return "官方公钥格式无法解析"
            case .unsupportedKey:      return "无法导入 RSA 公钥"
            case .chunkTooLarge:       return "RSA 明文分块过大"
            case .encrypt(let msg):    return "RSA 加密失败：\(msg)"
            }
        }
    }

    /// 固定后缀，服务端用它标识加密结束位置。
    static let suffix = "RSA_STRTOK@@@"

    /// 分块大小：30 字节。
    static let chunkSize = 30

    /// 用给定 PEM 公钥加密字符串，返回 `hex(cipher1)+SUFFIX+hex(cipher2)+SUFFIX+...`。
    /// 每块后面都要加分隔符,服务器用它分块解密;只在末尾加一个会导致多块时解析错。
    static func encrypt(_ plaintext: String, pem: String) throws -> String {
        let key = try importPublicKey(pem: pem)
        let bytes = Array(plaintext.utf8)

        var hex = ""
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            let cipher = try encryptBlock(Array(bytes[index..<end]), key: key)
            hex += Hex.string(cipher)
            hex += suffix
            index = end
        }
        return hex
    }

    // MARK: - 内部

    /// 走 PKCS#1 v1.5。分块最大长度为 keySize / 8 − 11，30 字节远在其内。
    private static func encryptBlock(_ block: [UInt8], key: SecKey) throws -> [UInt8] {
        let maxChunk = SecKeyGetBlockSize(key) - 11
        guard block.count <= maxChunk else { throw Failure.chunkTooLarge }

        var error: Unmanaged<CFError>?
        let data = Data(block)
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionPKCS1,
            data as CFData,
            &error
        ) else {
            let message = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
            throw Failure.encrypt(message)
        }
        return [UInt8](encrypted as Data)
    }

    /// 服务端返回的是 X.509/SPKI 格式 PEM，`SecKeyCreateWithData` 需要 PKCS#1（modulus+exponent）
    /// 的裸公钥。这里手解 DER 剥掉 SPKI 外层，再交给 `SecKeyCreateWithData`。
    static func importPublicKey(pem: String) throws -> SecKey {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else { throw Failure.invalidPEM }

        let pkcs1 = try stripSPKIHeaderIfNeeded(der)

        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw Failure.unsupportedKey
        }
        return key
    }

    /// 输入若是 SPKI，剥掉外层 `SEQUENCE { AlgorithmIdentifier, BIT STRING { PKCS#1 } }`，
    /// 返回 BIT STRING 里那段裸的 PKCS#1 公钥；输入若已经是 PKCS#1，原样返回。
    private static func stripSPKIHeaderIfNeeded(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var offset = 0

        // 顶层必须是 SEQUENCE
        guard offset < bytes.count, bytes[offset] == 0x30 else { throw Failure.invalidPEM }
        offset += 1
        _ = try readLength(bytes: bytes, offset: &offset)

        // 第一个子节点：SPKI 才有 AlgorithmIdentifier（SEQUENCE），PKCS#1 直接是 INTEGER (modulus)。
        guard offset < bytes.count else { throw Failure.invalidPEM }
        let firstTag = bytes[offset]
        if firstTag == 0x02 {
            // 已经是 PKCS#1：{ INTEGER n, INTEGER e }
            return der
        }
        guard firstTag == 0x30 else { throw Failure.invalidPEM }
        offset += 1
        let algLength = try readLength(bytes: bytes, offset: &offset)
        offset += algLength  // 跳过 AlgorithmIdentifier 内容

        // 下一个应是 BIT STRING
        guard offset < bytes.count, bytes[offset] == 0x03 else { throw Failure.invalidPEM }
        offset += 1
        let bitLength = try readLength(bytes: bytes, offset: &offset)
        // BIT STRING 首字节是「未使用位数」，通常为 0
        guard offset < bytes.count else { throw Failure.invalidPEM }
        let unusedBits = bytes[offset]
        offset += 1
        guard unusedBits == 0 else { throw Failure.invalidPEM }

        let payloadLength = bitLength - 1
        guard offset + payloadLength <= bytes.count else { throw Failure.invalidPEM }
        return Data(bytes[offset..<(offset + payloadLength)])
    }

    /// 解析 DER 的长度字段，游标推进到内容起点。
    private static func readLength(bytes: [UInt8], offset: inout Int) throws -> Int {
        guard offset < bytes.count else { throw Failure.invalidPEM }
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, offset + count <= bytes.count else { throw Failure.invalidPEM }
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }
}
