import CryptoKit
import Foundation

/// Authenticated bytes for the existing recording and publication stores. This value owns
/// no paths, account transitions or I/O. Composition supplies one verified profile key.
nonisolated struct MeetingRecordingCipher: Sendable {
    enum ArtifactKind: String, Sendable { case sessionManifest, publicationOutbox }
    enum Failure: Error, Equatable, Sendable {
        case invalidConfiguration, unavailableKey, invalidEnvelope, authenticationFailed, limitExceeded
    }

    static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let magic = Data("MRCE0001".utf8)
    static let envelopeOverhead = 8 + 12 + 16
    let profileID: String
    private let key: SymmetricKey
    private let keyDigest: Data

    init(profileID: String, key: Data) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 512,
              profileID.rangeOfCharacter(from: .controlCharacters) == nil, key.count == 32 else {
            throw Failure.invalidConfiguration
        }
        self.profileID = profileID
        self.key = SymmetricKey(data: key)
        self.keyDigest = Data(SHA256.hash(data: key))
    }

    static func isEncryptedEnvelope(_ bytes: Data) -> Bool { bytes.starts(with: magic) }
    static var envelopePrefixBytes: Int { magic.count }

    func hasSameKey(as other: Self) -> Bool {
        profileID == other.profileID && keyDigest == other.keyDigest
    }

    func seal(_ plaintext: Data, sessionID: UUID, artifactKind: ArtifactKind,
              maximumPlaintextBytes: Int) throws -> Data {
        guard maximumPlaintextBytes > 0, maximumPlaintextBytes <= Self.maximumManifestBytes,
              !plaintext.isEmpty, plaintext.count <= maximumPlaintextBytes else { throw Failure.limitExceeded }
        let box = try AES.GCM.seal(plaintext, using: key,
            authenticating: authenticatedContext(sessionID: sessionID, artifactKind: artifactKind))
        guard let combined = box.combined else { throw Failure.invalidEnvelope }
        var envelope = Self.magic
        envelope.append(combined)
        return envelope
    }

    func open(_ envelope: Data, sessionID: UUID, artifactKind: ArtifactKind,
              maximumPlaintextBytes: Int) throws -> Data {
        guard maximumPlaintextBytes > 0, maximumPlaintextBytes <= Self.maximumManifestBytes,
              envelope.count > Self.envelopeOverhead,
              envelope.count <= maximumPlaintextBytes + Self.envelopeOverhead,
              Self.isEncryptedEnvelope(envelope) else { throw Failure.invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(Self.magic.count))
            let plaintext = try AES.GCM.open(box, using: key,
                authenticating: authenticatedContext(sessionID: sessionID, artifactKind: artifactKind))
            guard !plaintext.isEmpty, plaintext.count <= maximumPlaintextBytes else { throw Failure.limitExceeded }
            return plaintext
        } catch let error as Failure { throw error }
        catch { throw Failure.authenticationFailed }
    }

    private func authenticatedContext(sessionID: UUID, artifactKind: ArtifactKind) throws -> Data {
        // A length-delimited encoding prevents a profile/role/ID substitution from acquiring
        // another artifact's authenticated bytes. Process generations are deliberately absent.
        try JSONEncoder().encode(["recording-envelope-v1", profileID,
            sessionID.uuidString.lowercased(), artifactKind.rawValue])
    }
}
