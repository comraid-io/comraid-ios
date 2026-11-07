import CryptoKit
import Foundation
import UserNotifications

/// Builds UNNotification content and categories from ComRaid push data keys.
public enum RemoteNotificationDisplay {
  /// Prefix for ComRaid action categories. Server APNs still send this as `aps.category`;
  /// the SDK registers and displays `comraid.actions.<stable hash>` per button set.
  public static let actionsCategoryIdentifier = "comraid.actions"

  static let imageTimeout: TimeInterval = 10
  static let imageMaxBytes = 5 * 1024 * 1024

  public static func content(from data: [String: String]) -> UNMutableNotificationContent {
    let display = PushPayload.display(data)
    let content = UNMutableNotificationContent()
    content.title = display.title
    content.body = display.body
    if let subtitle = display.subtitle {
      content.subtitle = subtitle
    }
    content.userInfo = data
    content.sound = sound(named: display.sound)
    if let badge = display.badge {
      content.badge = NSNumber(value: badge)
    }
    if let threadId = display.threadId {
      content.threadIdentifier = threadId
    }
    let actions = PushPayload.actions(data)
    if !actions.isEmpty {
      content.categoryIdentifier = categoryIdentifier(for: actions)
    }
    return content
  }

  /// APNs `sound` semantics: blank or `default` is the system sound, otherwise a bundled file name (`chime.caf`).
  static func sound(named raw: String?) -> UNNotificationSound {
    guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
          name.caseInsensitiveCompare("default") != .orderedSame else {
      return .default
    }
    return UNNotificationSound(named: UNNotificationSoundName(name))
  }

  /**
   Notification Service Extension helper for `didReceive(_:withContentHandler:)`.
   The server sets `mutable-content` when a push has an image or action buttons; this
   registers per-button-set categories and attaches `cr_image_url` before the OS draws it.
   Returns the original content unchanged when there is nothing to add.
   */
  public static func enrich(_ request: UNNotificationRequest) async -> UNNotificationContent {
    let data = PushPayload.fromUserInfo(request.content.userInfo)
    await registerCategories(from: data)
    let attachment: UNNotificationAttachment?
    if let imageUrl = PushPayload.display(data).imageUrl {
      attachment = await imageAttachment(from: imageUrl)
    } else {
      attachment = nil
    }
    return applyingEnrichments(to: request, data: data, imageAttachment: attachment)
  }

  /// Applies hashed action category and optional image attachment for NSE / tests.
  static func applyingEnrichments(
    to request: UNNotificationRequest,
    data: [String: String],
    imageAttachment: UNNotificationAttachment? = nil
  ) -> UNNotificationContent {
    let actions = PushPayload.actions(data)
    guard !actions.isEmpty || imageAttachment != nil,
          let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      return request.content
    }
    if !actions.isEmpty {
      content.categoryIdentifier = categoryIdentifier(for: actions)
    }
    if let imageAttachment {
      content.attachments = [imageAttachment]
    }
    return content
  }

  /// Downloads an http(s) image into a temporary file the system can attach (size- and time-bounded).
  static func imageAttachment(
    from urlString: String,
    session: URLSession = .shared
  ) async -> UNNotificationAttachment? {
    guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http" else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = imageTimeout
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          !data.isEmpty, data.count <= imageMaxBytes,
          let ext = imageFileExtension(mimeType: http.mimeType, url: url) else { return nil }
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("comraid-\(UUID().uuidString)")
      .appendingPathExtension(ext)
    do {
      try data.write(to: file)
      return try UNNotificationAttachment(identifier: "comraid.image", url: file)
    } catch {
      try? FileManager.default.removeItem(at: file)
      return nil
    }
  }

  /// The attachment type comes from the file extension; nil for formats notifications cannot show.
  static func imageFileExtension(mimeType: String?, url: URL) -> String? {
    switch mimeType?.lowercased() {
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/heic": return "heic"
    default:
      let ext = url.pathExtension.lowercased()
      return ["jpg", "jpeg", "png", "gif", "heic"].contains(ext) ? ext : nil
    }
  }

  public static func categories(from data: [String: String]) -> [UNNotificationCategory] {
    let actions = PushPayload.actions(data)
    guard !actions.isEmpty else {
      return []
    }
    let unActions = actions.map { action in
      UNNotificationAction(
        identifier: action.id,
        title: action.text,
        options: [.foreground]
      )
    }
    return [
      UNNotificationCategory(
        identifier: categoryIdentifier(for: actions),
        actions: unActions,
        intentIdentifiers: [],
        options: []
      ),
    ]
  }

  /// Stable category id for a button set: `comraid.actions.<hash>`.
  public static func categoryIdentifier(from data: [String: String]) -> String? {
    let actions = PushPayload.actions(data)
    guard !actions.isEmpty else { return nil }
    return categoryIdentifier(for: actions)
  }

  /// Category id for action-bearing pushes. Prefer `categoryIdentifier(from:)`.
  /// - Parameter deliveryId: Unused; kept for source compatibility with earlier per-delivery ids.
  @available(*, deprecated, message: "Use categoryIdentifier(from:) derived from the button set")
  public static func categoryIdentifier(for deliveryId: String) -> String {
    _ = deliveryId
    return actionsCategoryIdentifier
  }

  /// Stable `comraid.actions.<hash>` id for the given button set (order-sensitive).
  static func categoryIdentifier(for actions: [PushAction]) -> String {
    let canonical = actions.map { action in
      [action.id, action.text, action.icon ?? ""].joined(separator: "\u{1f}")
    }.joined(separator: "\u{1e}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "\(actionsCategoryIdentifier).\(hex)"
  }

  /// Merge next ComRaid categories into existing ones; host categories with other ids are kept.
  static func mergingCategories(
    existing: [UNNotificationCategory],
    with next: [UNNotificationCategory]
  ) -> Set<UNNotificationCategory> {
    var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
    for category in next {
      merged[category.identifier] = category
    }
    return Set(merged.values)
  }

  /// Register action categories with the system notification center.
  /// Merges hashed per-button-set categories into existing ones (host categories kept).
  /// Background OS-drawn alerts only show buttons when the category was already
  /// registered (for example after a prior present/register, or via an NSE).
  public static func registerCategories(from data: [String: String]) async {
    let next = categories(from: data)
    guard !next.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    let existing = await center.notificationCategories()
    center.setNotificationCategories(mergingCategories(existing: Array(existing), with: next))
  }

  /**
   Post a local tray item immediately from `cr_*` payload keys (optional promotion).
   Requires a non-blank `cr_title`. Applies `cr_sound`, `cr_badge`, `cr_thread_id`,
   `cr_subtitle`, and attaches `cr_image_url` when it downloads.
   */
  public static func present(
    data: [String: String],
    notificationCenter: UNUserNotificationCenter = .current()
  ) async throws {
    let display = PushPayload.display(data)
    let title = display.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw ComRaidError.invalidIdentifier
    }
    await registerCategories(from: data)
    let content = content(from: data)
    if let imageUrl = PushPayload.display(data).imageUrl,
       let attachment = await imageAttachment(from: imageUrl) {
      content.attachments = [attachment]
    }
    let deliveryId = data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = (deliveryId?.isEmpty == false ? deliveryId! : UUID().uuidString)
    try await notificationCenter.add(
      UNNotificationRequest(identifier: "comraid.present.\(identifier)", content: content, trigger: nil)
    )
  }
}
