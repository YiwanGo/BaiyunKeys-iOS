import Foundation
import UIKit

/// 「自动获取」通道：把已授权的门禁参数从官方接口取回本地。
/// 支持两种身份验证：
/// - `.login(...) + .entranceGuards(auth:)`：手机号 + 身份证（老接口，`www.pinganbaiyun.cn`）；
/// - `.entranceGuards(byPhone:openId:)`：手机号 + 微信 OpenID（新接口，`xcx.pinganbaiyun.cn`，
///   官方公钥加密手机号后请求，不需要身份证）。
enum BaiyunAPI {

    struct Auth {
        let token: String
        let loginUser: String
        let phone: String
    }

    struct Entrance {
        let name: String
        let mac: String
        let key: String
        let bluetoothName: String

        var asDoorConfig: DoorConfig {
            DoorConfig(name: name, mac: Hex.formatMac(mac), key: Hex.sanitizeKey(key), bluetoothName: bluetoothName.uppercased())
        }
    }

    /// 新接口激活握手的返回。
    struct GoHomeLoginResult {
        /// 服务器返的新 login_token。
        let newLoginToken: String
        /// 服务器带回的用户基本信息（可选用来显示 / 校验）。
        let phone: String
        let name: String
        let idCard: String
    }

    /// 加密版门禁列表项，encryptedKey 需要用对应 SM2 私钥解完才是明文。
    struct EncryptedEntrance {
        let name: String
        let mac: String
        let bluetoothName: String
        /// 服务器用你送上去的 SM2 公钥加密后的门禁 key（112 字节 hex，C1C3C2 结构）。
        let encryptedKey: String
    }

    enum Failure: LocalizedError {
        case http(Int)
        case decode
        case server(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code):   return "请求失败：HTTP \(code)"
            case .decode:           return "返回数据解析失败"
            case .server(let msg):  return msg
            case .empty:            return "返回数据为空"
            }
        }
    }

    private static let baseURL = URL(string: "https://www.pinganbaiyun.cn")!
    private static let baseURLXcx = URL(string: "https://xcx.pinganbaiyun.cn")!

    // MARK: - 老接口：手机号 + 身份证

    static func login(phone: String, idCard: String) async throws -> Auth {
        let normalizedPhone = phone.trimmingCharacters(in: .whitespaces)
        let payload: [String: Any] = [
            "sex": 0,
            "idcardNo": idCard.trimmingCharacters(in: .whitespaces).uppercased(),
            "deviceInfo": [
                "osVersion": UIDevice.current.systemVersion,
                "wifiMac": "02:00:00:00:00:00",
                "brand": "Apple",
                "os": 0,
                "udid": deviceUDID,
                "appVersion": "1.3.6",
                "imsi": "46015",
                "model": deviceModel
            ],
            "faceUploadCount": 0,
            "isreal": 0,
            "age": 0,
            "appVersion": "1.3.6",
            "phone": normalizedPhone
        ]

        let response = try await requestObject(path: "/baiyunuser/account/login/v1", body: payload)
        guard response["state"] as? Bool == true, response["code"] as? String == "0000" else {
            throw Failure.server(response["msg"] as? String ?? "登录失败")
        }
        let token = response["extension"] as? String ?? ""
        let user = (response["obj"] as? [String: Any])?["id"]
        let loginUser = user.map { "\($0)" } ?? ""
        guard !token.isEmpty, !loginUser.isEmpty else {
            throw Failure.server("登录返回数据缺失，请稍后重试")
        }
        return Auth(token: token, loginUser: loginUser, phone: normalizedPhone)
    }

    static func entranceGuards(auth: Auth) async throws -> [Entrance] {
        let response = try await requestObject(
            path: "/baiyunuser/entranceguard/getList",
            body: ["pageNum": 0, "pages": 0, "pageSize": 0],
            headers: ["TOKEN": auth.token, "LOGIN_USER": auth.loginUser]
        )

        var collected: [[String: Any]] = []
        collect(from: response, into: &collected)
        if collected.isEmpty, let obj = response["obj"] as? [[String: Any]] {
            collected = obj
        }

        return mapGuards(collected)
    }

    static func logout(auth: Auth) async {
        _ = try? await requestObject(
            path: "/baiyunuser/account/loginOut",
            body: ["phone": auth.phone],
            headers: ["TOKEN": auth.token, "LOGIN_USER": auth.loginUser]
        )
    }

    // MARK: - 新接口：手机号 + OpenID（三步）

    /// 一次性完成 OpenID → access_token → RSA 公钥 → 门禁列表 三步。
    static func entranceGuards(byPhone phone: String, openId: String) async throws -> [Entrance] {
        let normalizedPhone = phone.trimmingCharacters(in: .whitespaces)
        let normalizedOpenId = openId.trimmingCharacters(in: .whitespaces)

        // ① OpenID 换 access_token
        let checkState = try await requestArray(
            path: "/mini_program/api_01/check_state",
            body: ["openId": normalizedOpenId, "oper_type": "INDEX"],
            base: baseURLXcx
        )
        guard let accessToken = string(checkState.first?["access_token"]).nonEmpty else {
            throw Failure.server(string(checkState.first?["resp_msg"]).nonEmpty
                                 ?? "OpenID 换取令牌失败，请确认 OpenID 正确且未过期")
        }

        // ② 取 RSA 公钥（GET）
        let rsaResp = try await requestArray(
            path: "/health_passport/api_001_health_passport/get_rsa_public_key",
            method: "GET",
            headers: ["cloud_shield_token": accessToken],
            base: baseURLXcx
        )
        guard let publicKey = string(rsaResp.first?["result"]).nonEmpty else {
            throw Failure.server(string(rsaResp.first?["resp_msg"]).nonEmpty ?? "获取 RSA 公钥失败")
        }

        // ③ 手机号加密后换门禁列表
        let plaintext = "{\"phone\":\"\(normalizedPhone)\"}"
        let encryptedKey = try RSA.encrypt(plaintext, pem: publicKey)
        let listResp = try await requestArray(
            path: "/p_021_health_passport/api_007_wbyw_002/get_guard_list_by_phone",
            body: ["key": encryptedKey],
            headers: ["cloud_shield_token": accessToken],
            base: baseURLXcx
        )
        let first = listResp.first ?? [:]
        if let code = first["resp_code"] as? String, code != "000000000000" {
            throw Failure.server(string(first["resp_msg"]).nonEmpty ?? "获取门禁列表失败")
        }
        let dataList = (first["data_list"] as? [[String: Any]]) ?? []
        return mapGuards(dataList)
    }

    // MARK: - 新接口：加密版（手机号 + OpenID + 本地 SM2 密钥对）

    /// 用 openId 换 `cloud_shield_token`。独立抽出来，激活流程和老 OpenID 路线都能复用。
    static func checkState(openId: String) async throws -> String {
        let resp = try await requestArray(
            path: "/mini_program/api_01/check_state",
            body: ["openId": openId.trimmingCharacters(in: .whitespaces),
                   "oper_type": "INDEX"],
            base: baseURLXcx
        )
        guard let token = string(resp.first?["access_token"]).nonEmpty else {
            throw Failure.server(string(resp.first?["resp_msg"]).nonEmpty
                                 ?? "OpenID 换取令牌失败，请确认 OpenID 正确且未过期")
        }
        return token
    }

    /// 新接口激活握手。把本地 SM2 公钥告诉服务器;后续 get_guard_list_by_phone 若
    /// 加密下发 productKey,就是用这把公钥加密的。
    static func goHomeServiceLogin(openId: String,
                                   loginToken: String,
                                   smPublicKey: String,
                                   accessToken: String) async throws -> GoHomeLoginResult {
        let resp = try await requestArray(
            path: "/p_021_health_passport/api_007_wbyw_002/go_home_service_login",
            body: [
                "openId": openId.trimmingCharacters(in: .whitespaces),
                "login_token": loginToken,
                "sm_publickey": smPublicKey.trimmingCharacters(in: .whitespaces),
            ],
            headers: ["cloud_shield_token": accessToken],
            base: baseURLXcx
        )
        let first = resp.first ?? [:]
        if let code = first["resp_code"] as? String, code != "000000000000" {
            throw Failure.server(string(first["resp_msg"]).nonEmpty ?? "激活握手失败")
        }
        return GoHomeLoginResult(
            newLoginToken: string(first["token"]),
            phone: string(first["phone"]),
            name: string(first["name"]),
            idCard: string(first["id_card"])
        )
    }

    /// 拉取门禁列表。payload 不带 xx 字段时服务器直接返明文 productKey,带了才会用
    /// sm_publickey 做 SM2 加密下发;目前只传 phone,走明文分支。
    static func encryptedEntranceGuards(phone: String,
                                        accessToken: String) async throws -> [EncryptedEntrance] {
        // ① RSA 公钥
        let rsaResp = try await requestArray(
            path: "/health_passport/api_001_health_passport/get_rsa_public_key",
            method: "GET",
            headers: ["cloud_shield_token": accessToken],
            base: baseURLXcx
        )
        guard let publicKey = string(rsaResp.first?["result"]).nonEmpty else {
            throw Failure.server(string(rsaResp.first?["resp_msg"]).nonEmpty ?? "获取 RSA 公钥失败")
        }

        // ② 手机号 RSA 加密后换门禁列表
        let normalizedPhone = phone.trimmingCharacters(in: .whitespaces)
        let plaintext = "{\"phone\":\"\(normalizedPhone)\"}"
        let encryptedKey = try RSA.encrypt(plaintext, pem: publicKey)
        let listResp = try await requestArray(
            path: "/p_021_health_passport/api_007_wbyw_002/get_guard_list_by_phone",
            body: ["key": encryptedKey],
            headers: ["cloud_shield_token": accessToken],
            base: baseURLXcx
        )
        let first = listResp.first ?? [:]
        if let code = first["resp_code"] as? String, code != "000000000000" {
            throw Failure.server(string(first["resp_msg"]).nonEmpty ?? "获取门禁列表失败")
        }
        let dataList = (first["data_list"] as? [[String: Any]]) ?? []
        return mapEncryptedGuards(dataList)
    }

    /// 不做 isValidKey 过滤，保留 112 字节 hex 密文。
    private static func mapEncryptedGuards(_ list: [[String: Any]]) -> [EncryptedEntrance] {
        list.compactMap { item in
            let bluetoothName = string(item["bluetoothName"]).uppercased()

            let rawMac = string(item["macNum"]).nonEmpty ?? string(item["mac"]).nonEmpty ?? ""
            var mac = Hex.formatMac(rawMac)
            if !Hex.isValidMac(mac), !bluetoothName.isEmpty,
               let derived = BLEProtocol.macFromBluetoothName(bluetoothName) {
                mac = derived
            }

            let encrypted = string(item["productKey"]).nonEmpty
                         ?? string(item["key"]).nonEmpty
                         ?? ""

            guard !mac.isEmpty, !encrypted.isEmpty else { return nil }
            let name = [string(item["address"]), string(item["name"]), string(item["doorName"])]
                .first { !$0.isEmpty } ?? "导入门禁"
            return EncryptedEntrance(name: name, mac: mac, bluetoothName: bluetoothName,
                                      encryptedKey: encrypted)
        }
    }

    // MARK: - 内部：请求

    private static func requestObject(path: String,
                                      body: [String: Any]? = nil,
                                      method: String = "POST",
                                      headers: [String: String] = [:],
                                      base: URL? = nil) async throws -> [String: Any] {
        let data = try await requestData(path: path, body: body, method: method, headers: headers, base: base)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.decode
        }
        return json
    }

    private static func requestArray(path: String,
                                     body: [String: Any]? = nil,
                                     method: String = "POST",
                                     headers: [String: String] = [:],
                                     base: URL? = nil) async throws -> [[String: Any]] {
        let data = try await requestData(path: path, body: body, method: method, headers: headers, base: base)
        let root = try? JSONSerialization.jsonObject(with: data)
        if let array = root as? [[String: Any]] { return array }
        if let single = root as? [String: Any] { return [single] }
        throw Failure.decode
    }

    private static func requestData(path: String,
                                    body: [String: Any]?,
                                    method: String,
                                    headers: [String: String],
                                    base: URL?) async throws -> Data {
        var request = URLRequest(url: (base ?? baseURL).appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hans-US;q=1, en-US;q=0.9", forHTTPHeaderField: "Accept-Language")
        if method != "GET", let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        guard !data.isEmpty else { throw Failure.empty }
        return data
    }

    // MARK: - 内部：字段映射

    /// 两条通道下发的字段名一致，抽出公共映射：
    /// - 名称：address / name / doorName 三选一
    /// - MAC ：macNum / mac ；若空且有蓝牙名，由蓝牙名推一个
    /// - Key ：productKey / key
    /// - 蓝牙名：bluetoothName，转大写
    /// - 过滤：丢掉 MAC 或 Key 为空的
    private static func mapGuards(_ list: [[String: Any]]) -> [Entrance] {
        list.compactMap { item in
            let bluetoothName = string(item["bluetoothName"]).uppercased()

            let rawMac = string(item["macNum"]).nonEmpty ?? string(item["mac"]).nonEmpty ?? ""
            var mac = Hex.formatMac(rawMac)
            if !Hex.isValidMac(mac), !bluetoothName.isEmpty, let derived = BLEProtocol.macFromBluetoothName(bluetoothName) {
                mac = derived
            }
            let key = Hex.sanitizeKey(string(item["productKey"]).nonEmpty ?? string(item["key"]).nonEmpty ?? "")
            guard !mac.isEmpty, !key.isEmpty else { return nil }

            let name = [string(item["address"]), string(item["name"]), string(item["doorName"])]
                .first { !$0.isEmpty } ?? "导入门禁"
            return Entrance(name: name, mac: mac, key: key, bluetoothName: bluetoothName)
        }
    }

    /// 接口把门禁数组藏在嵌套的 `obj.data_list` 里，递归收集。
    private static func collect(from node: Any?, into result: inout [[String: Any]]) {
        if let array = node as? [Any] {
            array.forEach { collect(from: $0, into: &result) }
            return
        }
        guard let dict = node as? [String: Any] else { return }
        if let list = dict["data_list"] as? [[String: Any]] {
            result.append(contentsOf: list)
        }
        if let obj = dict["obj"] {
            collect(from: obj, into: &result)
        }
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return "\(value)".trimmingCharacters(in: .whitespaces)
    }

    /// deviceInfo 需要一个设备标识：安装期内保持稳定的 UUID，写入 UserDefaults。
    private static var deviceUDID: String {
        let key = "baiyun.udid"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return identifier.isEmpty ? "iPhone17,2" : identifier
    }
}

private extension String {
    /// 空串视作 nil，方便链式 `?? "fallback"`。
    var nonEmpty: String? { isEmpty ? nil : self }
}
