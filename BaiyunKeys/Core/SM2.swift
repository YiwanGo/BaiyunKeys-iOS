import Foundation

// ============================================================
// MARK: - 精简 BigUInt（仅支撑 SM2 256 位模运算）
// ============================================================

struct BigUInt: Comparable, CustomStringConvertible {
    private var limbs: [UInt64]  // little-endian, base 2^64

    init(_ value: UInt64 = 0) {
        limbs = value == 0 ? [] : [value]
    }

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        var result = BigUInt(0)
        for ch in s {
            guard let d = UInt64(String(ch), radix: 16) else { continue }
            result = result * BigUInt(16) + BigUInt(d)
        }
        self = result
    }

    static let zero = BigUInt(0)
    static let one  = BigUInt(1)

    var isZero: Bool { limbs.isEmpty }
    var bitWidth: Int {
        guard let h = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - h.leadingZeroBitCount)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }
    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool { lhs.limbs == rhs.limbs }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var a = lhs.limbs, b = rhs.limbs
        let n = max(a.count, b.count)
        while a.count < n { a.append(0) }
        while b.count < n { b.append(0) }
        var res = [UInt64](); res.reserveCapacity(n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            res.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry > 0 { res.append(carry) }
        var r = BigUInt(0); r.limbs = res; r.normalize(); return r
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var a = lhs.limbs, b = rhs.limbs
        while b.count < a.count { b.append(0) }
        var res = [UInt64](); res.reserveCapacity(a.count)
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let (s1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (s2, o2) = s1.subtractingReportingOverflow(borrow)
            res.append(s2)
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        var r = BigUInt(0); r.limbs = res; r.normalize(); return r
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        var res = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let (hi, lo) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = res[i+j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                res[i+j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            res[i + rhs.limbs.count] = carry
        }
        var r = BigUInt(0); r.limbs = res; r.normalize(); return r
    }

    static func / (lhs: BigUInt, rhs: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!rhs.isZero, "Division by zero")
        if lhs < rhs { return (.zero, lhs) }
        var quotient = [UInt64](repeating: 0, count: lhs.bitWidth)
        var remainder = BigUInt(0)
        for i in stride(from: lhs.bitWidth - 1, through: 0, by: -1) {
            remainder = remainder << 1
            if lhs.bit(at: i) { remainder = remainder + BigUInt(1) }
            if remainder >= rhs {
                remainder = remainder - rhs
                quotient[i / 64] |= (1 << (i % 64))
            }
        }
        var q = BigUInt(0); q.limbs = quotient; q.normalize()
        return (q, remainder)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt { (lhs / rhs).remainder }

    static func << (lhs: BigUInt, shift: Int) -> BigUInt {
        if lhs.isZero || shift <= 0 { return lhs }
        let limbShift = shift / 64, bitShift = shift % 64
        var res = [UInt64](repeating: 0, count: lhs.limbs.count + limbShift + 1)
        for i in 0..<lhs.limbs.count {
            res[i + limbShift] |= lhs.limbs[i] << bitShift
            if bitShift > 0 { res[i + limbShift + 1] |= lhs.limbs[i] >> (64 - bitShift) }
        }
        var r = BigUInt(0); r.limbs = res; r.normalize(); return r
    }

    func bit(at index: Int) -> Bool {
        let limb = index / 64, offset = index % 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> offset) & 1 == 1
    }

    /// 模逆。原稿用无符号扩展欧几里得,中间会 underflow 崩溃;SM2 的 p、n 都是素数,
    /// 这里用 Fermat 小定理走 modPow —— a⁻¹ ≡ a^(m-2) mod m,一步到位且永不 underflow。
    static func modInverse(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        return modPow(a, m - BigUInt(2), m)
    }

    /// 模幂（平方-乘）
    static func modPow(_ base: BigUInt, _ exp: BigUInt, _ mod: BigUInt) -> BigUInt {
        if mod == BigUInt(1) { return .zero }
        var result = BigUInt(1), b = base % mod
        for i in stride(from: exp.bitWidth - 1, through: 0, by: -1) {
            result = (result * result) % mod
            if exp.bit(at: i) { result = (result * b) % mod }
        }
        return result
    }

    func toHex(minLength: Int = 0) -> String {
        guard !isZero else { return String(repeating: "0", count: max(minLength, 1)) }
        var s = ""
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            s += String(format: "%016llx", limbs[i])
        }
        while s.hasPrefix("0") && s.count > 1 { s.removeFirst() }
        if s.count < minLength { s = String(repeating: "0", count: minLength - s.count) + s }
        return s
    }
    var description: String { toHex() }
}

// ============================================================
// MARK: - SM3 杂凑
// ============================================================

struct SM3 {
    private static let IV: [UInt32] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e
    ]

    static func hash(_ data: [UInt8]) -> [UInt8] {
        var msg = data
        let bitLen = UInt64(data.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(i)) & 0xff))
        }

        var v = IV
        for blockStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 68)
            for j in 0..<16 {
                let base = blockStart + j * 4
                w[j] = UInt32(msg[base]) << 24 | UInt32(msg[base+1]) << 16
                     | UInt32(msg[base+2]) << 8 | UInt32(msg[base+3])
            }
            for j in 16..<68 {
                w[j] = p1(w[j-16] ^ w[j-9] ^ rotl(w[j-3], 15)) ^ rotl(w[j-13], 7) ^ w[j-6]
            }
            var w1 = [UInt32](repeating: 0, count: 64)
            for j in 0..<64 { w1[j] = w[j] ^ w[j+4] }

            var (a, b, c, d, e, f, g, h) = (v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
            for j in 0..<64 {
                let t = j < 16 ? UInt32(0x79cc4519) : UInt32(0x7a879d8a)
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t, j % 32), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c))
                let gg = j < 16 ? (e ^ f ^ g) : ((e & f) | (~e & g))
                let tt1 = ff &+ d &+ ss2 &+ w1[j]
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e; e = p0(tt2)
            }
            v[0] ^= a; v[1] ^= b; v[2] ^= c; v[3] ^= d
            v[4] ^= e; v[5] ^= f; v[6] ^= g; v[7] ^= h
        }

        var out = [UInt8]()
        for word in v {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: Int) -> UInt32 {
        let s = n % 32
        return s == 0 ? x : (x << s) | (x >> (32 - s))
    }
    private static func p0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
    private static func p1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }
}

// ============================================================
// MARK: - SM2 椭圆曲线
// ============================================================

struct ECPoint {
    let x: BigUInt
    let y: BigUInt
    let isInfinity: Bool

    static let infinity = ECPoint(x: .zero, y: .zero, isInfinity: true)

    init(x: BigUInt, y: BigUInt, isInfinity: Bool = false) {
        self.x = x; self.y = y; self.isInfinity = isInfinity
    }
}

enum SM2Curve {
    static let p = BigUInt(hex: "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF")
    static let a = BigUInt(hex: "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC")
    static let b = BigUInt(hex: "28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93")
    static let n = BigUInt(hex: "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123")
    static let gx = BigUInt(hex: "32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7")
    static let gy = BigUInt(hex: "BC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0")
    static let G = ECPoint(x: gx, y: gy)

    static func mod(_ a: BigUInt) -> BigUInt { a % p }

    static func add(_ P: ECPoint, _ Q: ECPoint) -> ECPoint {
        if P.isInfinity { return Q }
        if Q.isInfinity { return P }
        if P.x == Q.x && P.y == Q.y {
            // 倍点
            let num = (mod(BigUInt(3) * P.x * P.x) + a) % p
            let den = BigUInt.modInverse(mod(BigUInt(2) * P.y), p)
            let λ = (num * den) % p
            let x3 = mod(λ * λ - BigUInt(2) * P.x)
            let y3 = mod(λ * (P.x - x3) - P.y)
            return ECPoint(x: x3, y: y3)
        }
        if P.x == Q.x { return .infinity }
        let num = mod(Q.y - P.y)
        let den = BigUInt.modInverse(mod(Q.x - P.x), p)
        let λ = (num * den) % p
        let x3 = mod(λ * λ - P.x - Q.x)
        let y3 = mod(λ * (P.x - x3) - P.y)
        return ECPoint(x: x3, y: y3)
    }

    static func mul(_ P: ECPoint, _ k: BigUInt) -> ECPoint {
        if k.isZero || P.isInfinity { return .infinity }
        var result = ECPoint.infinity
        var addend = P
        for i in 0..<k.bitWidth {
            if k.bit(at: i) { result = add(result, addend) }
            addend = add(addend, addend)
        }
        return result
    }

    static func neg(_ P: ECPoint) -> ECPoint {
        if P.isInfinity { return P }
        return ECPoint(x: P.x, y: (p - P.y) % p)
    }
}

// ============================================================
// MARK: - SM2 核心 API（对应 sm-crypto 的 sm2 对象）
// ============================================================

struct SM2 {

    // MARK: 密钥对
    struct KeyPairHex {
        let privateKey: String  // 64 位 hex，无 04 前缀
        let publicKey: String   // 130 位 hex，以 04 开头
    }

    static func generateKeyPairHex() -> KeyPairHex {
        var d: BigUInt
        repeat {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            d = BigUInt(hex: bytes.map { String(format: "%02x", $0) }.joined())
        } while d.isZero || d >= SM2Curve.n

        let PA = SM2Curve.mul(SM2Curve.G, d)
        return KeyPairHex(
            privateKey: d.toHex(minLength: 64),
            publicKey: "04" + PA.x.toHex(minLength: 64) + PA.y.toHex(minLength: 64)
        )
    }

    // MARK: 根据私钥推导公钥
    static func getPublicKeyFromPrivateKey(_ privateKey: String) -> String {
        let d = BigUInt(hex: privateKey)
        let PA = SM2Curve.mul(SM2Curve.G, d)
        return "04" + PA.x.toHex(minLength: 64) + PA.y.toHex(minLength: 64)
    }

    // MARK: 加密（C1C2C3 模式）
    static func doEncrypt(_ msg: [UInt8], publicKey: String, cipherMode: Int = 1) -> String {
        guard let pub = decodePublicKey(publicKey) else { fatalError("Invalid public key") }

        let keypair = generateKeyPairHex()
        let k = BigUInt(hex: keypair.privateKey)

        var c1 = keypair.publicKey
        if c1.count > 128 { c1 = String(c1.suffix(128)) }

        let p = SM2Curve.mul(pub, k)
        let x2 = p.x.toHex(minLength: 64)
        let y2 = p.y.toHex(minLength: 64)

        let c3 = SM3.hash(hexToBytes(x2) + msg + hexToBytes(y2))
        let c3Hex = bytesToHex(c3)

        // KDF 生成掩码
        var ct: UInt32 = 1
        var offset = 0
        var t: [UInt8] = []
        let z = hexToBytes(x2) + hexToBytes(y2)

        func nextT() {
            var input = z
            input.append(UInt8((ct >> 24) & 0xff))
            input.append(UInt8((ct >> 16) & 0xff))
            input.append(UInt8((ct >> 8) & 0xff))
            input.append(UInt8(ct & 0xff))
            t = SM3.hash(input)
            ct += 1
            offset = 0
        }
        nextT()

        var c2 = msg
        for i in 0..<c2.count {
            if offset == t.count { nextT() }
            c2[i] ^= t[offset]
            offset += 1
        }
        let c2Hex = bytesToHex(c2)

        return cipherMode == 1 ? c1 + c2Hex + c3Hex : c1 + c3Hex + c2Hex
    }

    // MARK: 解密
    static func doDecrypt(_ encryptData: String, privateKey: String,
                          cipherMode: Int = 1, output: String = "string") -> Any {
        let d = BigUInt(hex: privateKey)
        let c3Hex: String
        let c2Hex: String
        if cipherMode == 1 {
            c3Hex = String(encryptData.suffix(64))
            c2Hex = String(encryptData.dropFirst(128).dropLast(64))
        } else {
            c3Hex = String(encryptData.dropFirst(128).prefix(64))
            c2Hex = String(encryptData.dropFirst(192))
        }

        guard let c1 = decodePublicKey("04" + String(encryptData.prefix(128))) else {
            return output == "array" ? [UInt8]() : ""
        }

        let p = SM2Curve.mul(c1, d)
        let x2 = p.x.toHex(minLength: 64)
        let y2 = p.y.toHex(minLength: 64)

        var msg = hexToBytes(c2Hex)
        var ct: UInt32 = 1
        var offset = 0
        var t: [UInt8] = []
        let z = hexToBytes(x2) + hexToBytes(y2)

        func nextT() {
            var input = z
            input.append(UInt8((ct >> 24) & 0xff))
            input.append(UInt8((ct >> 16) & 0xff))
            input.append(UInt8((ct >> 8) & 0xff))
            input.append(UInt8(ct & 0xff))
            t = SM3.hash(input)
            ct += 1
            offset = 0
        }
        nextT()

        for i in 0..<msg.count {
            if offset == t.count { nextT() }
            msg[i] ^= t[offset]
            offset += 1
        }

        let checkC3 = bytesToHex(SM3.hash(hexToBytes(x2) + msg + hexToBytes(y2)))
        guard checkC3 == c3Hex.lowercased() else {
            return output == "array" ? [UInt8]() : ""
        }

        if output == "array" { return msg }
        return String(bytes: msg, encoding: .utf8) ?? ""
    }

    // MARK: 签名
    static func doSignature(_ msg: [UInt8], privateKey: String,
                            der: Bool = false, hash: Bool = true,
                            publicKey: String? = nil, userId: String = "1234567812345678") -> String {
        var hashHex = bytesToHex(msg)
        if hash {
            let pub = publicKey ?? getPublicKeyFromPrivateKey(privateKey)
            hashHex = getHash(hashHex, publicKey: pub, userId: userId)
        }

        let dA = BigUInt(hex: privateKey)
        let e = BigUInt(hex: hashHex)
        let n = SM2Curve.n

        var r: BigUInt, s: BigUInt
        repeat {
            var k: BigUInt
            repeat {
                let kp = generateKeyPairHex()
                k = BigUInt(hex: kp.privateKey)
                let point = SM2Curve.mul(SM2Curve.G, k)
                r = (e + point.x) % n
            } while r.isZero || (r + k) == n

            let inv = BigUInt.modInverse((dA + BigUInt(1)) % n, n)
            s = (inv * (k - r * dA)) % n
        } while s.isZero

        if der { return encodeDer(r, s) }
        return r.toHex(minLength: 64) + s.toHex(minLength: 64)
    }

    // MARK: 验签
    static func doVerifySignature(_ msg: [UInt8], signHex: String, publicKey: String,
                                  der: Bool = false, hash: Bool = true,
                                  userId: String = "1234567812345678") -> Bool {
        guard let PA = decodePublicKey(publicKey) else { return false }

        var hashHex = bytesToHex(msg)
        if hash { hashHex = getHash(hashHex, publicKey: publicKey, userId: userId) }

        let (r, s): (BigUInt, BigUInt)
        if der {
            guard let decoded = decodeDer(signHex) else { return false }
            (r, s) = decoded
        } else {
            guard signHex.count == 128 else { return false }
            r = BigUInt(hex: String(signHex.prefix(64)))
            s = BigUInt(hex: String(signHex.suffix(64)))
        }

        let n = SM2Curve.n
        guard !r.isZero, r < n, !s.isZero, s < n else { return false }

        let e = BigUInt(hex: hashHex)
        let t = (r + s) % n
        guard !t.isZero else { return false }

        let x1y1 = SM2Curve.add(SM2Curve.mul(SM2Curve.G, s), SM2Curve.mul(PA, t))
        let R = (e + x1y1.x) % n
        return r == R
    }

    // MARK: - 内部辅助

    private static func decodePublicKey(_ hex: String) -> ECPoint? {
        var s = hex
        if s.hasPrefix("04") { s = String(s.dropFirst(2)) }
        guard s.count == 128 else { return nil }
        let x = BigUInt(hex: String(s.prefix(64)))
        let y = BigUInt(hex: String(s.suffix(64)))
        let P = ECPoint(x: x, y: y)
        // 验证点在曲线上
        let left = (y * y) % SM2Curve.p
        let right = (x * x * x + SM2Curve.a * x + SM2Curve.b) % SM2Curve.p
        return left == right ? P : nil
    }

    private static func getHash(_ hashHex: String, publicKey: String,
                                userId: String = "1234567812345678") -> String {
        let uidHex = bytesToHex(Array(userId.utf8))
        let a = SM2Curve.a.toHex(minLength: 64)
        let b = SM2Curve.b.toHex(minLength: 64)
        let gx = SM2Curve.gx.toHex(minLength: 64)
        let gy = SM2Curve.gy.toHex(minLength: 64)

        var px: String, py: String
        if publicKey.count == 128 {
            px = String(publicKey.prefix(64))
            py = String(publicKey.suffix(64))
        } else {
            guard let P = decodePublicKey(publicKey) else { return "" }
            px = P.x.toHex(minLength: 64)
            py = P.y.toHex(minLength: 64)
        }

        var data = hexToBytes(uidHex + a + b + gx + gy + px + py)
        let entl = uidHex.count * 4
        data.insert(UInt8(entl & 0xff), at: 0)
        data.insert(UInt8((entl >> 8) & 0xff), at: 0)

        let z = SM3.hash(data)
        return bytesToHex(SM3.hash(z + hexToBytes(hashHex)))
    }

    private static func encodeDer(_ r: BigUInt, _ s: BigUInt) -> String {
        let rBytes = hexToBytes(r.toHex(minLength: 64))
        let sBytes = hexToBytes(s.toHex(minLength: 64))
        let rInt = [0x02] + derLength(rBytes.count) + rBytes
        let sInt = [0x02] + derLength(sBytes.count) + sBytes
        let seq = rInt + sInt
        return bytesToHex([0x30] + derLength(seq.count) + seq)
    }

    private static func derLength(_ len: Int) -> [UInt8] {
        if len < 0x80 { return [UInt8(len)] }
        var bytes = [UInt8]()
        var l = len
        while l > 0 { bytes.insert(UInt8(l & 0xff), at: 0); l >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func decodeDer(_ hex: String) -> (BigUInt, BigUInt)? {
        let bytes = hexToBytes(hex)
        guard bytes.count > 4, bytes[0] == 0x30 else { return nil }
        var idx = 2
        guard bytes[idx] == 0x02 else { return nil }
        idx += 1
        let rLen = Int(bytes[idx]); idx += 1
        let r = BigUInt(hex: bytesToHex(Array(bytes[idx..<idx+rLen])))
        idx += rLen
        guard idx < bytes.count, bytes[idx] == 0x02 else { return nil }
        idx += 1
        let sLen = Int(bytes[idx]); idx += 1
        let s = BigUInt(hex: bytesToHex(Array(bytes[idx..<idx+sLen])))
        return (r, s)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var s = hex
        if s.count % 2 != 0 { s = "0" + s }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            if let b = UInt8(s[i..<next], radix: 16) { out.append(b) }
            i = next
        }
        return out
    }

    private static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
