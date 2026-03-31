#if canImport(Security)
import Foundation
import Security

enum KeychainHelperError: LocalizedError {
  case invalidUTF8(account: String)
  case operationFailed(operation: String, account: String, status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidUTF8(let account):
      return "Could not encode keychain value for \(account)."
    case .operationFailed(let operation, let account, let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Keychain \(operation) failed for \(account): \(message)"
    }
  }
}

enum KeychainHelper {
  private static let service: String = {
    if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
      return bundleID
    }
    return "app.immich.desktop.macos"
  }()

  static func save(account: String, password: String) throws {
    guard let data = password.data(using: .utf8) else {
      throw KeychainHelperError.invalidUTF8(account: account)
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    // Delete any existing item first
    let deleteStatus = SecItemDelete(query as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      throw KeychainHelperError.operationFailed(operation: "delete", account: account, status: deleteStatus)
    }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainHelperError.operationFailed(operation: "save", account: account, status: addStatus)
    }
  }

  static func load(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainHelperError.operationFailed(operation: "load", account: account, status: status)
    }
    guard let string = String(data: data, encoding: .utf8) else {
      throw KeychainHelperError.invalidUTF8(account: account)
    }
    return string
  }

  static func delete(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainHelperError.operationFailed(operation: "delete", account: account, status: status)
    }
  }

}
#endif
