import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Apple SRP-6a Client

/// RFC 5054 2048-bit Group 14
struct SRPGroup {
    static let N = BigUInt("AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73", radix: 16)!
    static let g = BigUInt(2)
}

final class AppleSRPClient {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func generateClientCredentials() -> (a: BigUInt, A: BigUInt) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let a = BigUInt(Data(bytes))
        let A = SRPGroup.g.power(a, modulus: SRPGroup.N)
        return (a, A)
    }

    func computeProof(
        a: BigUInt,
        A: BigUInt,
        serverB: BigUInt,
        salt: Data,
        iterations: Int,
        protocol proto: String,
        serverC: String
    ) -> (M1: Data, M2: Data) {
        let N = SRPGroup.N
        let g = SRPGroup.g

        // u = SHA256(PAD(A) || PAD(B)) — rfc5054: padded for u computation
        var uHash = SHA256()
        uHash.update(data: padToN(A))
        uHash.update(data: padToN(serverB))
        let u = BigUInt(Data(uHash.finalize()))

        // x = derived password key (with srp library's gen_x wrapping)
        let x = deriveX(password: password, salt: salt, iterations: iterations, protocol: proto)

        // k = SHA256(N || PAD(g)) — rfc5054: g padded to N length
        var kHash = SHA256()
        kHash.update(data: N.serialize())
        kHash.update(data: padToN(g))
        let k = BigUInt(Data(kHash.finalize()))

        // S = (B - k * g^x mod N) ^ (a + u * x) mod N
        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base: BigUInt = serverB > kgx ? serverB - kgx : (serverB + N) - kgx
        let exponent = (a + u * x)
        let S = base.power(exponent, modulus: N)

        // K = SHA256(S) — raw bytes, no padding (matches srp lib)
        let K = Data(SHA256.hash(data: S.serialize()))

        // M1 — uses raw (unpadded) A and B (matches srp lib's long_to_bytes)
        let rawA = A.serialize()
        let rawB = serverB.serialize()
        let M1 = computeM1(N: N, g: g, username: username, salt: salt, A: rawA, B: rawB, K: K)

        // M2 = SHA256(raw_A || M1 || K) — unpadded A
        var m2Hash = SHA256()
        m2Hash.update(data: rawA)
        m2Hash.update(data: M1)
        m2Hash.update(data: K)
        let M2 = Data(m2Hash.finalize())

        return (M1, M2)
    }

    private func deriveX(password: String, salt: Data, iterations: Int, protocol proto: String) -> BigUInt {
        let passwordDigest = Data(SHA256.hash(data: password.data(using: .utf8)!))

        let pbkdfInput: Data
        if proto == "s2k_fo" {
            let hexString = passwordDigest.map { String(format: "%02x", $0) }.joined()
            pbkdfInput = hexString.data(using: .utf8)!
        } else {
            // s2k: use raw digest bytes
            pbkdfInput = passwordDigest
        }

        var derivedKey = [UInt8](repeating: 0, count: 32)
        let _ = pbkdfInput.withUnsafeBytes { inputPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    inputPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    inputPtr.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        // Match srp library: x = H(salt, H(b':' + password))
        // where password = PBKDF2 derived key, and username is empty (no_username_in_x)
        let colonPlusPassword = Data([0x3A]) + Data(derivedKey) // b':' + pbkdf2_key
        let innerHash = Data(SHA256.hash(data: colonPlusPassword))
        var outerHash = SHA256()
        outerHash.update(data: salt)
        outerHash.update(data: innerHash)
        return BigUInt(Data(outerHash.finalize()))
    }

    private func padToN(_ value: BigUInt) -> Data {
        let nLen = (SRPGroup.N.bitWidth + 7) / 8
        var data = value.serialize()
        while data.count < nLen {
            data.insert(0, at: 0)
        }
        return data
    }

    private func computeM1(N: BigUInt, g: BigUInt, username: String, salt: Data, A: Data, B: Data, K: Data) -> Data {
        let hN = Data(SHA256.hash(data: N.serialize()))
        // g padded to N byte length (rfc5054)
        let nLen = N.serialize().count
        var gBytes = g.serialize()
        gBytes = Data(repeating: 0, count: nLen - gBytes.count) + gBytes
        let hg = Data(SHA256.hash(data: gBytes))

        var hNxorHg = Data(count: 32)
        for i in 0..<32 {
            hNxorHg[i] = hN[i] ^ hg[i]
        }

        // Hash the actual username (no_username_in_x only affects gen_x, NOT M1)
        let usernameData = username.data(using: .utf8) ?? Data()
        var m1Hash = SHA256()
        m1Hash.update(data: hNxorHg)
        m1Hash.update(data: Data(SHA256.hash(data: usernameData)))
        m1Hash.update(data: salt)
        m1Hash.update(data: A)
        m1Hash.update(data: B)
        m1Hash.update(data: K)
        return Data(m1Hash.finalize())
    }
}
