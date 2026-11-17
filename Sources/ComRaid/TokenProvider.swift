import Foundation

protocol TokenProvider: Sendable {
  func currentToken() async throws -> String
}

/// Holds the APNs device token once the host forwards it from AppDelegate.
actor StoredAPNsTokenProvider: TokenProvider {
  private var hexToken: String?
  private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]

  func setDeviceToken(_ tokenData: Data) {
    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
    hexToken = hex
    let pending = waiters
    waiters.removeAll()
    for continuation in pending.values {
      continuation.resume(returning: hex)
    }
  }

  func currentToken() async throws -> String {
    guard let hexToken, !hexToken.isEmpty else {
      throw ComRaidError.notReady
    }
    return hexToken
  }

  /// Waits until a token is stored, or throws `tokenTimeout` when `timeout` elapses.
  func waitForToken(timeout: TimeInterval) async throws -> String {
    if let hexToken, !hexToken.isEmpty {
      return hexToken
    }
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      waiters[id] = continuation
      Task {
        if timeout > 0 {
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        await self.resumeWaiter(id, throwing: .tokenTimeout)
      }
    }
  }

  private func resumeWaiter(_ id: UUID, throwing error: ComRaidError) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    continuation.resume(throwing: error)
  }
}
