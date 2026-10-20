import Foundation

protocol TokenProvider: Sendable {
  func currentToken() async throws -> String
}

/// Holds the APNs device token once the host forwards it from AppDelegate.
actor StoredAPNsTokenProvider: TokenProvider {
  private var hexToken: String?

  func setDeviceToken(_ tokenData: Data) {
    hexToken = tokenData.map { String(format: "%02x", $0) }.joined()
  }

  func currentToken() async throws -> String {
    guard let hexToken, !hexToken.isEmpty else {
      throw ComraidError.notReady
    }
    return hexToken
  }
}
