import Foundation

/// Builds an ACK queue from persisted SDK config so notification handlers /
/// the Notification Service Extension can enqueue/flush without a foreground
/// `ComRaid.configure` in this process (no `BGTaskScheduler`).
///
/// When the host configures with `storageSuiteName` (App Group), pass the same
/// suite here so the extension can read config and the durable ACK queue.
enum BackgroundAckHelpers {
  static func makeQueue(
    storageSuiteName: String? = nil,
    configStore: SdkConfigStore? = nil,
    ackStore: (any AckQueueStore)? = nil,
    transport: (any HttpTransport)? = nil
  ) -> AckQueue? {
    let resolvedConfigStore = configStore ?? SdkConfigStore(suiteName: storageSuiteName)
    guard let config = resolvedConfigStore.load() else { return nil }
    let suite = config.storageSuiteName ?? storageSuiteName
    let store = ackStore ?? UserDefaultsAckQueueStore(suiteName: suite)
    let http = transport ?? URLSessionHttpTransport(apiBaseURL: config.apiBaseURL)
    return AckQueue(apiBaseURL: config.apiBaseURL, store: store, transport: http)
  }

  /// Drain the durable ACK queue (NSE and other extension entry points).
  static func flushQueued(
    storageSuiteName: String? = nil,
    configStore: SdkConfigStore? = nil,
    ackStore: (any AckQueueStore)? = nil,
    transport: (any HttpTransport)? = nil
  ) async {
    guard let queue = makeQueue(
      storageSuiteName: storageSuiteName,
      configStore: configStore,
      ackStore: ackStore,
      transport: transport
    ) else {
      return
    }
    await queue.flush()
  }

  /// Enqueue delivered ACK and flush immediately (queue persists on failure).
  static func acknowledgeDelivered(
    data: [String: String],
    storageSuiteName: String? = nil,
    configStore: SdkConfigStore? = nil,
    ackStore: (any AckQueueStore)? = nil,
    transport: (any HttpTransport)? = nil
  ) async {
    guard let queue = makeQueue(
      storageSuiteName: storageSuiteName,
      configStore: configStore,
      ackStore: ackStore,
      transport: transport
    ) else {
      return
    }
    _ = await queue.enqueueFromPayload(kind: .delivered, data: data)
    await queue.flush()
  }

  /// Handle an incoming remote notification: enqueue delivered ACK and register actions.
  static func handleReceived(
    data: [String: String],
    storageSuiteName: String? = nil
  ) async {
    await RemoteNotificationDisplay.registerCategories(from: data)
    await acknowledgeDelivered(data: data, storageSuiteName: storageSuiteName)
  }

  /// Handle notification open / action: enqueue opened ACK.
  static func handleOpened(
    data: [String: String],
    actionId: String? = nil,
    storageSuiteName: String? = nil
  ) async {
    guard let queue = makeQueue(storageSuiteName: storageSuiteName) else { return }
    _ = await queue.enqueueFromPayload(kind: .opened, data: data, actionId: actionId)
    await queue.flush()
  }
}
