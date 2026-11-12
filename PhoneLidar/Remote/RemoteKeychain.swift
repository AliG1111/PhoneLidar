import Foundation
import Security

/// The phone this phone is paired with, and the shared key (design §7.20).
struct RemotePairing: Codable, Equatable, Sendable {
    var peerID: UUID
    var peerName: String
    /// 32-byte pairing key.
    var key: Data
    var created: Date
}

/// One Keychain item per role: account `scanner` (the scanner's paired remote) or `remote` (the remote's
/// paired scanner). This-device-only, readable after the first unlock.
enum RemoteKeychain {
    static let service = "ca.gervais.phonelidar.remote-link"
    static let scannerAccount = "scanner"
    static let remoteAccount = "remote"

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The pairing could not be saved in the Keychain (\(text))."
            }
        }
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(account: String) -> RemotePairing? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let pairing = try? JSONDecoder.iso.decode(RemotePairing.self, from: data),
              pairing.key.count == 32 else { return nil }
        return pairing
    }

    static func save(_ pairing: RemotePairing, account: String) throws {
        let data = try JSONEncoder.pretty.encode(pairing)
        SecItemDelete(query(account: account) as CFDictionary)
        var item = query(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
