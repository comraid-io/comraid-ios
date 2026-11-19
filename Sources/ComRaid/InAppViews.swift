#if canImport(UIKit)
import ImageIO
import UIKit

/// Where an In-app layout sits on screen.
enum InAppPlacement: Equatable {
  case center
  case top
  case bottom
  case fill
}

/// How a layout is presented: where, whether it dims the screen, and whether it blocks touches behind it.
struct InAppPresentationSpec: Equatable {
  let placement: InAppPlacement
  let dimsBackground: Bool
  let blocksTouchesBehind: Bool

  static func `for`(_ layout: InAppLayout) -> InAppPresentationSpec {
    switch layout {
    case .modal: InAppPresentationSpec(placement: .center, dimsBackground: true, blocksTouchesBehind: true)
    case .bannerTop: InAppPresentationSpec(placement: .top, dimsBackground: false, blocksTouchesBehind: false)
    case .bannerBottom: InAppPresentationSpec(placement: .bottom, dimsBackground: false, blocksTouchesBehind: false)
    case .fullscreen: InAppPresentationSpec(placement: .fill, dimsBackground: false, blocksTouchesBehind: true)
    }
  }
}

/// Loads a message image and delivers it (or nil) on the main actor.
typealias InAppImageLoading = @MainActor (String, @escaping @MainActor (UIImage?) -> Void) -> Void

/// Decode `data` no larger than `maxPixelSize` on its longest side, so a huge campaign image cannot
/// exhaust memory. Returns nil when the bytes are not an image.
func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
  guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
    return nil
  }
  let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
  ]
  guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
  return UIImage(cgImage: image)
}

/// The default image loader: a size-capped download, downsampled off the main thread.
let defaultInAppImageLoader: InAppImageLoading = { urlString, completion in
  guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
    completion(nil)
    return
  }
  URLSession.shared.dataTask(with: url) { data, response, _ in
    let image: UIImage? = {
      guard let data, data.count <= 5 * 1024 * 1024, (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
      return downsampledImage(from: data, maxPixelSize: 1080)
    }()
    DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
  }.resume()
}

/// The visible card: close control, optional image, title, body and up to two buttons.
@MainActor
final class InAppContentView: UIView {
  static let closeIdentifier = "comraid.inapp.close"
  private static let maxButtons = 2

  init(
    message: InAppMessage,
    imageLoader: InAppImageLoading?,
    onButton: @escaping (InAppButton) -> Void,
    onClose: @escaping () -> Void
  ) {
    super.init(frame: .zero)
    let fullscreen = message.layout == .fullscreen
    backgroundColor = .systemBackground
    layer.cornerRadius = fullscreen ? 0 : 16
    clipsToBounds = true

    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    if fullscreen { stack.alignment = .fill }
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
    ])

    let close = UIButton(type: .system)
    close.setTitle("\u{00D7}", for: .normal)
    close.titleLabel?.font = .systemFont(ofSize: 28)
    close.accessibilityLabel = "Close"
    close.accessibilityIdentifier = Self.closeIdentifier
    close.contentHorizontalAlignment = .trailing
    close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
    stack.addArrangedSubview(close)

    if let imageURL = message.imageURL, let imageLoader {
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      imageView.isHidden = true // until the image arrives
      imageView.heightAnchor.constraint(equalToConstant: fullscreen ? 200 : 140).isActive = true
      stack.addArrangedSubview(imageView)
      imageLoader(imageURL) { [weak imageView] image in
        guard let imageView, let image else { return }
        imageView.image = image
        imageView.isHidden = false
      }
    }

    let title = UILabel()
    title.text = message.title
    title.font = .boldSystemFont(ofSize: 20)
    title.numberOfLines = 0
    stack.addArrangedSubview(title)

    let body = UILabel()
    body.text = message.body
    body.font = .systemFont(ofSize: 15)
    body.textColor = .secondaryLabel
    body.numberOfLines = 0
    stack.addArrangedSubview(body)

    let buttons = Array(message.buttons.prefix(Self.maxButtons))
    if !buttons.isEmpty {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 12
      row.distribution = .fillEqually
      for button in buttons {
        let control = UIButton(type: .system)
        control.setTitle(button.label, for: .normal)
        control.addAction(UIAction { _ in onButton(button) }, for: .touchUpInside)
        row.addArrangedSubview(control)
      }
      stack.addArrangedSubview(row)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Full-window container that reports a teardown it did not cause itself.
@MainActor
private final class InAppOverlayView: UIView {
  var closedByUser = false
  var onInterrupted: (() -> Void)?
  var passesTouchesThrough = false

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview == nil, !closedByUser { onInterrupted?() }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return passesTouchesThrough && hit === self ? nil : hit
  }
}

/// Puts a message on a window using the layout's presentation rules.
@MainActor
enum InAppRenderer {
  static let overlayIdentifier = "comraid.inapp.overlay"
  static let backdropIdentifier = "comraid.inapp.backdrop"

  /// Draw `message` on `window` and report an impression. Returns false when it cannot be drawn.
  static func present(
    _ message: InAppMessage,
    handle: any InAppMessageHandle,
    in window: UIWindow,
    imageLoader: InAppImageLoading?
  ) -> Bool {
    let spec = InAppPresentationSpec.for(message.layout)
    let overlay = InAppOverlayView()
    overlay.accessibilityIdentifier = overlayIdentifier
    overlay.passesTouchesThrough = !spec.blocksTouchesBehind
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.onInterrupted = { [weak handle] in (handle as? InAppInterruptible)?.interrupted() }

    func close(_ report: () -> Void) {
      overlay.closedByUser = true
      report()
      overlay.removeFromSuperview()
    }

    // A tap outside a modal closes it (a dismissal). Banners and full screen have no backdrop.
    if message.layout == .modal {
      let backdrop = UIButton(type: .custom)
      backdrop.accessibilityIdentifier = backdropIdentifier
      backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.4)
      backdrop.translatesAutoresizingMaskIntoConstraints = false
      backdrop.addAction(UIAction { _ in close { handle.dismissed() } }, for: .touchUpInside)
      overlay.addSubview(backdrop)
      NSLayoutConstraint.activate([
        backdrop.topAnchor.constraint(equalTo: overlay.topAnchor),
        backdrop.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        backdrop.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
        backdrop.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      ])
    }

    let content = InAppContentView(
      message: message,
      imageLoader: imageLoader,
      onButton: { button in
        close {
          // The host routes the deep link; the SDK reports the click, then closes the message
          // (the manager does not send a dismissal ACK for a close that follows a click).
          handle.clicked(buttonId: button.id)
          handle.dismissed()
        }
      },
      onClose: { close { handle.dismissed() } }
    )
    content.translatesAutoresizingMaskIntoConstraints = false
    overlay.addSubview(content)
    constrain(content, in: overlay, placement: spec.placement)

    window.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: window.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: window.bottomAnchor),
      overlay.leadingAnchor.constraint(equalTo: window.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: window.trailingAnchor),
    ])
    handle.impression()
    return true
  }

  private static func constrain(_ content: UIView, in overlay: UIView, placement: InAppPlacement) {
    let guide = overlay.safeAreaLayoutGuide
    switch placement {
    case .center:
      let width = content.widthAnchor.constraint(equalToConstant: 340)
      width.priority = .defaultHigh
      NSLayoutConstraint.activate([
        content.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        content.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        content.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
        content.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
        width,
      ])
    case .top:
      NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
        content.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 8),
        content.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
      ])
    case .bottom:
      NSLayoutConstraint.activate([
        content.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
        content.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 8),
        content.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
      ])
    case .fill:
      NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: overlay.topAnchor),
        content.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      ])
    }
  }
}

/// The SDK's default layouts, drawn on the app's active window.
@MainActor
final class UIKitInAppDisplay: InAppDisplay {
  private let windowProvider: @MainActor () -> UIWindow?
  private let imageLoader: InAppImageLoading?

  nonisolated init(
    windowProvider: @escaping @MainActor () -> UIWindow? = defaultInAppWindow,
    imageLoader: InAppImageLoading? = defaultInAppImageLoader
  ) {
    self.windowProvider = windowProvider
    self.imageLoader = imageLoader
  }

  func isAvailable() -> Bool { windowProvider() != nil }

  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool {
    guard let window = windowProvider() else { return false }
    return InAppRenderer.present(message, handle: handle, in: window, imageLoader: imageLoader)
  }
}

/// The key window of the foreground-active scene. Reaches `UIApplication` without `UIApplication.shared`
/// so the SDK still compiles when linked into an app extension (where it finds no window).
@MainActor
func defaultInAppWindow() -> UIWindow? {
  guard let application = (UIApplication.self as AnyObject)
    .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
  else { return nil }
  let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
  let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  return active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first
}
#endif
