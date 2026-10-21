import Foundation
@testable import ComRaid

final class InMemorySubscriptionStore: SubscriptionCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _subscriptionId: String?
  private var _credential: String?

  var subscriptionId: String? {
    lock.withLock { _subscriptionId }
  }

  var credential: String? {
    lock.withLock { _credential }
  }

  func save(subscriptionId: String, credential: String?) {
    lock.withLock {
      _subscriptionId = subscriptionId
      if let credential {
        _credential = credential
      }
    }
  }

  func clear() {
    lock.withLock {
      _subscriptionId = nil
      _credential = nil
    }
  }
}
