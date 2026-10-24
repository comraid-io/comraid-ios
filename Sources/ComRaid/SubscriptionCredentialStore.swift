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
    service = suiteName.map { "com.comraid.subscription.\($0)" } ?? "com.comraid.subscription"
  }

  var subscriptionId: String? {
    lock.withLock { read(service: service, account: idAccount) }
  }

  var credential: String? {
    lock.withLock { read(service: service, account: credentialAccount) }
  }

  func save(subscriptionId: String, credential: String?) {
    lock.withLock {
      write(service: service, account: idAccount, value: subscriptionId)
      if let credential {
        write(service: service, account: credentialAccount, value: credential)
      }
    }
  }

  func clear() {
    lock.withLock {
      delete(service: service, account: idAccount)
      delete(service: service, account: credentialAccount)
    }
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
