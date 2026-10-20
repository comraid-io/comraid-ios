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
  private let idAccount = "subscription_id"
  private let credentialAccount = "subscription_credential"

  init(suiteName: String?) {
    service = suiteName.map { "com.comraide.subscription.\($0)" } ?? "com.comraide.subscription"
  }

  var subscriptionId: String? {
    lock.withLock { read(account: idAccount) }
  }

  var credential: String? {
    lock.withLock { read(account: credentialAccount) }
  }

  func save(subscriptionId: String, credential: String?) {
    lock.withLock {
      write(account: idAccount, value: subscriptionId)
      if let credential {
        write(account: credentialAccount, value: credential)
      }
    }
  }

  func clear() {
    lock.withLock {
      delete(account: idAccount)
      delete(account: credentialAccount)
    }
  }

  private func read(account: String) -> String? {
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

  private func write(account: String, value: String) {
    delete(account: account)
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

  private func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
