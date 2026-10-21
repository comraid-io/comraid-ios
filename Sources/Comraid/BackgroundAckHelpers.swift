import Foundation

/// Builds an ACK queue from persisted SDK config so notification handlers can
/// enqueue/flush without requiring a foreground `Comraid.configure` in this process.
enum BackgroundAckHelpers {
  static func makeQueue(
    configStore: SdkConfigStore = SdkConfigStore(),
    ackStore: (any AckQueueStore)? = nil,
    transport: (any HttpTransport)? = nil
  ) -> AckQueue? {
    guard let config = configStore.load() else { return nil }
    let store = ackStore ?? UserDefaultsAckQueueStore(suiteName: config.storageSuiteName)
    let http = transport ?? URLSessionHttpTransport(apiBaseURL: config.apiBaseURL)
    return AckQueue(apiBaseURL: config.apiBaseURL, store: store, transport: http)
  }

  /// Handle an incoming remote notification: enqueue delivered ACK and register actions.
  static func handleReceived(data: [String: String]) async {
    await RemoteNotificationDisplay.registerCategories(from: data)
    guard let queue = makeQueue() else { return }
    _ = await queue.enqueueFromPayload(kind: .delivered, data: data)
    await queue.flush()
  }

  /// Handle notification open / action: enqueue opened ACK.
  static func handleOpened(data: [String: String], actionId: String? = nil) async {
    guard let queue = makeQueue() else { return }
    _ = await queue.enqueueFromPayload(kind: .opened, data: data, actionId: actionId)
    await queue.flush()
  }
}
