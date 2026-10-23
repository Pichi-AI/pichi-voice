import Foundation
import Security

/// Narrow Keycloak RS256 verifier. Unsupported algorithms fail closed; no token-supplied URLs.
nonisolated enum AccountJWTValidator {
    struct JWKSet: Decodable, Sendable { let keys: [JWK] }
    struct JWK: Decodable, Sendable {
        let kty: String; let kid: String; let alg: String?; let use: String?
        let n: String?; let e: String?; let key_ops: [String]?
    }
    struct Claims: Sendable { let subject: String; let expiresAt: Date }

    static func validate(_ token: String, keys: JWKSet, issuer: String, audience: String,
                         nonce: String? = nil, authorizedParty: String? = nil,
                         requireNonce: Bool = true, now: Date = Date()) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 32_768, parts.count == 3,
              let headerData = Data(accountBase64URL: parts[0]), let payload = Data(accountBase64URL: parts[1]),
              let signature = Data(accountBase64URL: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              header["b64"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              keys.keys.count <= 100 else { throw AccountError.invalidToken }
        let matches = keys.keys.filter { $0.kid == kid }
        guard matches.count == 1, let key = matches.first, key.kty == "RSA", key.alg == nil || key.alg == "RS256",
              key.use == nil || key.use == "sig", key.key_ops == nil || key.key_ops!.contains("verify"),
              let n = key.n.flatMap({ Data(accountBase64URL: $0) }), let e = key.e.flatMap({ Data(accountBase64URL: $0) }),
              (256...1024).contains(n.count), !e.isEmpty, e.count <= 8 else { throw AccountError.invalidToken }
        let der = sequence(integer(n) + integer(e))
        guard let rsa = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                  kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(rsa, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(rsa, .rsaSignatureMessagePKCS1v15SHA256,
                  Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == issuer,
              let sub = claims["sub"] as? String, !sub.isEmpty, sub.utf8.count <= 512,
              let exp = number(claims["exp"]), let issued = number(claims["iat"]),
              exp > now.timeIntervalSince1970 - 30, issued <= now.timeIntervalSince1970 + 30,
              exp > issued else { throw AccountError.invalidToken }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(audience), audiences.count <= 20 else { throw AccountError.invalidToken }
        if let authorizedParty {
            if let azp = claims["azp"] as? String {
                guard azp == authorizedParty else { throw AccountError.invalidToken }
            } else if audiences.count > 1 { throw AccountError.invalidToken }
        }
        if let nbf = claims["nbf"] {
            guard let value = number(nbf), value <= now.timeIntervalSince1970 + 30 else { throw AccountError.invalidToken }
        }
        if let nonce, requireNonce || claims["nonce"] != nil {
            guard claims["nonce"] as? String == nonce else { throw AccountError.invalidToken }
        }
        return Claims(subject: sub, expiresAt: Date(timeIntervalSince1970: exp))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var count = count; var bytes: [UInt8] = []
        while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func integer(_ value: Data) -> Data {
        var value = Data(value.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! >= 128 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }
    private static func sequence(_ value: Data) -> Data { Data([0x30]) + length(value.count) + value }
}
