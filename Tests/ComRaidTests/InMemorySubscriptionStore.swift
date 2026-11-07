import Foundation
@testable import ComRaid

final class InMemorySubscriptionStore: SubscriptionCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _subscriptionId: String?
  private var _credential: String?
  private var _externalUserId: String?

  var subscriptionId: String? {
    lock.withLock { _subscriptionId }
  }

  var credential: String? {
    lock.withLock { _credential }
  }

  var externalUserId: String? {
    lock.withLock { _externalUserId }
  }

  func save(subscriptionId: String, credential: String?) {
    lock.withLock {
      _subscriptionId = subscriptionId
      if let credential {
        _credential = credential
      }
    }
  }

  func setExternalUserId(_ externalUserId: String?) {
    lock.withLock { _externalUserId = externalUserId }
  }

  func clear() {
    lock.withLock {
      _subscriptionId = nil
      _credential = nil
      _externalUserId = nil
    }
  }
}
