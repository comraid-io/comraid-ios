import Foundation
import Security

protocol SubscriptionCredentialStore: Sendable {
  var subscriptionId: String? { get }
  var credential: String? { get }
  func save(subscriptionId: String, credential: String?)
  func clear()
}

/// Persists Subscription id + credential in the Keychain.
final class KeychainSubscriptionStore: SubscriptionCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private let service: String
  private let legacyService: String
  private let idAccount = "subscription_id"
  private let credentialAccount = "subscription_credential"

  init(suiteName: String?) {
    service = suiteName.map { "com.comraid.subscription.\($0)" } ?? "com.comraid.subscription"
    legacyService = suiteName.map { "com.comraide.subscription.\($0)" } ?? "com.comraide.subscription"
  }

  var subscriptionId: String? {
    lock.withLock { readMigrating(account: idAccount) }
  }

  var credential: String? {
    lock.withLock { readMigrating(account: credentialAccount) }
  }

  func save(subscriptionId: String, credential: String?) {
    lock.withLock {
      write(service: service, account: idAccount, value: subscriptionId)
      delete(service: legacyService, account: idAccount)
      if let credential {
        write(service: service, account: credentialAccount, value: credential)
        delete(service: legacyService, account: credentialAccount)
      }
    }
  }

  func clear() {
    lock.withLock {
      delete(service: service, account: idAccount)
      delete(service: service, account: credentialAccount)
      delete(service: legacyService, account: idAccount)
      delete(service: legacyService, account: credentialAccount)
    }
  }

  private func readMigrating(account: String) -> String? {
    if let value = read(service: service, account: account) {
      return value
    }
    guard let legacy = read(service: legacyService, account: account) else { return nil }
    write(service: service, account: account, value: legacy)
    delete(service: legacyService, account: account)
    return legacy
  }

  private func read(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func write(service: String, account: String, value: String) {
    delete(service: service, account: account)
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(query as CFDictionary, nil)
  }

  private func delete(service: String, account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
