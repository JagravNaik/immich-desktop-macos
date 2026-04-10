#if canImport(Security)
import Foundation
import Security

enum KeychainHelperError: LocalizedError {
  case invalidUTF8(account: String)
  case operationFailed(operation: String, account: String, status: OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidUTF8(let account):
      return "Stored keychain value for \(account) is not valid UTF-8."
    case .operationFailed(let operation, let account, let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Keychain \(operation) failed for \(account): \(message)"
    }
  }
}

enum KeychainHelper {
  #if DEBUG
  nonisolated(unsafe) static var testServiceOverride: String?
  #endif

  private enum KeychainStore {
    case standard
    case dataProtection
  }

  private static let service: String = {
    if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
      return bundleID
    }
    return "app.immich.desktop.macos"
  }()

  private static var activeService: String {
    #if DEBUG
    return testServiceOverride ?? service
    #else
    return service
    #endif
  }

  private static func baseQuery(account: String, store: KeychainStore) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: activeService,
      kSecAttrAccount as String: account,
    ]
    if store == .dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private static func isIgnorableLegacyStatus(_ status: OSStatus) -> Bool {
    status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
  }

  static func save(account: String, password: String) throws {
    let data = Data(password.utf8)
    let query = baseQuery(account: account, store: .standard)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      let updateQuery = query as CFDictionary
      let updateAttributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
      ]
      let updateStatus = SecItemUpdate(updateQuery, updateAttributes as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw KeychainHelperError.operationFailed(operation: "update", account: account, status: updateStatus)
      }
    } else if addStatus != errSecSuccess {
      throw KeychainHelperError.operationFailed(operation: "save", account: account, status: addStatus)
    }

    // Clean up any legacy item saved to the data protection keychain.
    let legacyDeleteStatus = SecItemDelete(baseQuery(account: account, store: .dataProtection) as CFDictionary)
    guard isIgnorableLegacyStatus(legacyDeleteStatus) else {
      throw KeychainHelperError.operationFailed(operation: "delete legacy item", account: account, status: legacyDeleteStatus)
    }
  }

  static func load(account: String) throws -> String? {
    if let value = try load(account: account, store: .standard) {
      return value
    }
    if let legacyValue = try? load(account: account, store: .dataProtection) {
      try save(account: account, password: legacyValue)
      return legacyValue
    }
    return nil
  }

  private static func load(account: String, store: KeychainStore) throws -> String? {
    var query = baseQuery(account: account, store: store)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
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
    for store in [KeychainStore.standard, .dataProtection] {
      let status = SecItemDelete(baseQuery(account: account, store: store) as CFDictionary)
      let isAllowedFailure = store == .dataProtection ? isIgnorableLegacyStatus(status) : (status == errSecSuccess || status == errSecItemNotFound)
      guard isAllowedFailure else {
        throw KeychainHelperError.operationFailed(operation: "delete", account: account, status: status)
      }
    }
  }

}
#endif
