#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import ComRaid

/// Seam: the default In-app layouts (placement rules, the views built for a message, how taps are
/// reported, image handling). Real views in the simulator; no network and no app host.

private final class RecordingHandle: InAppMessageHandle, InAppInterruptible, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var events: [String] { lock.withLock { recorded } }
  func impression() { lock.withLock { recorded.append("impression") } }
  func clicked(buttonId: String) { lock.withLock { recorded.append("clicked:\(buttonId)") } }
  func dismissed() { lock.withLock { recorded.append("dismissed") } }
  func interrupted() { lock.withLock { recorded.append("interrupted") } }
}

private func message(
  layout: InAppLayout = .modal,
  imageURL: String? = nil,
  buttons: [InAppButton] = [InAppButton(id: "open", label: "Open", deepLink: "myapp://x"), InAppButton(id: "later", label: "Later")]
) -> InAppMessage {
  InAppMessage(id: "m1", layout: layout, title: "Welcome back", body: "See what is new", imageURL: imageURL, buttons: buttons)
}

@MainActor private func allViews(_ root: UIView) -> [UIView] {
  [root] + root.subviews.flatMap(allViews)
}

@MainActor private func labelTexts(_ root: UIView) -> [String] {
  allViews(root).compactMap { ($0 as? UILabel)?.text }
}

@MainActor private func buttonTitles(_ root: UIView) -> [String] {
  allViews(root).compactMap { ($0 as? UIButton)?.title(for: .normal) }
}

@MainActor private func tapButton(_ root: UIView, titled title: String) {
  (allViews(root).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == title })?.sendActions(for: .touchUpInside)
}

@MainActor private func tapIdentified(_ root: UIView, _ identifier: String) {
  (allViews(root).first { $0.accessibilityIdentifier == identifier } as? UIControl)?.sendActions(for: .touchUpInside)
}

@MainActor private func makeWindow() -> UIWindow {
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  window.rootViewController = UIViewController()
  window.isHidden = false
  return window
}

@Test func presentationRulesFollowTheLayout() {
  let modal = InAppPresentationSpec.for(.modal)
  #expect(modal.placement == .center && modal.dimsBackground && modal.blocksTouchesBehind)

  let top = InAppPresentationSpec.for(.bannerTop)
  #expect(top.placement == .top && !top.dimsBackground && !top.blocksTouchesBehind)

  let bottom = InAppPresentationSpec.for(.bannerBottom)
  #expect(bottom.placement == .bottom && !bottom.dimsBackground && !bottom.blocksTouchesBehind)

  let full = InAppPresentationSpec.for(.fullscreen)
  #expect(full.placement == .fill && full.blocksTouchesBehind)
}

@Test @MainActor func contentShowsTitleBodyButtonsAndAClose() {
  let content = InAppContentView(message: message(), imageLoader: nil, onButton: { _ in }, onClose: {})

  let texts = labelTexts(content)
  #expect(texts.contains("Welcome back") && texts.contains("See what is new"))
  #expect(buttonTitles(content).contains("Open") && buttonTitles(content).contains("Later"))
  #expect(allViews(content).contains { $0.accessibilityLabel == "Close" })
}

@Test @MainActor func atMostTwoButtonsAreDrawn() {
  let many = [InAppButton(id: "a", label: "A"), InAppButton(id: "b", label: "B"), InAppButton(id: "c", label: "C")]
  let content = InAppContentView(message: message(buttons: many), imageLoader: nil, onButton: { _ in }, onClose: {})

  #expect(buttonTitles(content).contains("A") && buttonTitles(content).contains("B"))
  #expect(!buttonTitles(content).contains("C"))
}

@Test @MainActor func tappingAButtonOrTheCloseControlCallsBack() {
  var tapped: [String] = []
  let content = InAppContentView(
    message: message(), imageLoader: nil,
    onButton: { tapped.append("button:\($0.id)") }, onClose: { tapped.append("close") }
  )

  tapButton(content, titled: "Open")
  tapIdentified(content, InAppContentView.closeIdentifier)

  #expect(tapped == ["button:open", "close"])
}

@Test @MainActor func anImageIsRequestedOnlyWhenTheMessageHasOneAndShownWhenItArrives() {
  var requested: [String] = []
  var deliver: (@MainActor (UIImage?) -> Void)?
  let loader: InAppImageLoading = { url, completion in
    requested.append(url)
    deliver = completion
  }

  let noImage = InAppContentView(message: message(), imageLoader: loader, onButton: { _ in }, onClose: {})
  #expect(requested.isEmpty)
  #expect(!allViews(noImage).contains { $0 is UIImageView })

  let withImage = InAppContentView(
    message: message(imageURL: "https://cdn.example.com/a.png"), imageLoader: loader, onButton: { _ in }, onClose: {}
  )
  #expect(requested == ["https://cdn.example.com/a.png"])
  let imageView = allViews(withImage).compactMap { $0 as? UIImageView }.first
  #expect(imageView?.isHidden == true) // hidden until the image arrives

  deliver?(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
  #expect(imageView?.isHidden == false)
  #expect(imageView?.image != nil)
}

@Test @MainActor func presentingDrawsTheOverlayAndReportsOneImpression() {
  let window = makeWindow()
  let handle = RecordingHandle()

  let shown = InAppRenderer.present(message(), handle: handle, in: window, imageLoader: nil)

  #expect(shown)
  #expect(handle.events == ["impression"])
  #expect(allViews(window).contains { $0.accessibilityIdentifier == InAppRenderer.overlayIdentifier })
}

@Test @MainActor func tappingAButtonReportsTheClickThenTheCloseAndRemovesTheOverlay() {
  let window = makeWindow()
  let handle = RecordingHandle()
  _ = InAppRenderer.present(message(), handle: handle, in: window, imageLoader: nil)

  tapButton(window, titled: "Open")

  #expect(handle.events == ["impression", "clicked:open", "dismissed"])
  #expect(!allViews(window).contains { $0.accessibilityIdentifier == InAppRenderer.overlayIdentifier })
}

@Test @MainActor func theCloseControlAndATapOutsideAModalAreDismissals() {
  let window = makeWindow()
  let closed = RecordingHandle()
  _ = InAppRenderer.present(message(), handle: closed, in: window, imageLoader: nil)
  tapIdentified(window, InAppContentView.closeIdentifier)
  #expect(closed.events == ["impression", "dismissed"])

  let outside = RecordingHandle()
  _ = InAppRenderer.present(message(), handle: outside, in: window, imageLoader: nil)
  tapIdentified(window, InAppRenderer.backdropIdentifier)
  #expect(outside.events == ["impression", "dismissed"])
}

@Test @MainActor func aBannerLeavesTheScreenBehindItTouchable() {
  let window = makeWindow()
  _ = InAppRenderer.present(message(layout: .bannerTop), handle: RecordingHandle(), in: window, imageLoader: nil)

  #expect(!allViews(window).contains { $0.accessibilityIdentifier == InAppRenderer.backdropIdentifier })
}

@Test @MainActor func anOverlayRemovedWithoutTheUserIsReportedAsInterrupted() {
  let window = makeWindow()
  let handle = RecordingHandle()
  _ = InAppRenderer.present(message(), handle: handle, in: window, imageLoader: nil)

  allViews(window).first { $0.accessibilityIdentifier == InAppRenderer.overlayIdentifier }?.removeFromSuperview()

  #expect(handle.events == ["impression", "interrupted"])
}

@Test @MainActor func aUserCloseIsNeverAlsoAnInterruption() {
  let window = makeWindow()
  let handle = RecordingHandle()
  _ = InAppRenderer.present(message(), handle: handle, in: window, imageLoader: nil)

  tapButton(window, titled: "Later")

  #expect(!handle.events.contains("interrupted"))
}

@Test @MainActor func displayIsAvailableOnlyWhenThereIsAWindow() {
  #expect(UIKitInAppDisplay(windowProvider: { nil }, imageLoader: nil).isAvailable() == false)
  let window = makeWindow()
  let display = UIKitInAppDisplay(windowProvider: { window }, imageLoader: nil)
  #expect(display.isAvailable())

  let handle = RecordingHandle()
  #expect(display.show(message(), handle: handle))
  #expect(UIKitInAppDisplay(windowProvider: { nil }, imageLoader: nil).show(message(), handle: handle) == false)
}

@Test func aLargeImageIsDownsampledToTheRequestedSize() throws {
  let big = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000)).image { context in
    UIColor.red.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
  }
  let data = try #require(big.pngData())

  let small = try #require(downsampledImage(from: data, maxPixelSize: 500))

  #expect(max(small.size.width * small.scale, small.size.height * small.scale) <= 500)
}

@Test func bytesThatAreNotAnImageDownsampleToNil() {
  #expect(downsampledImage(from: Data(repeating: 7, count: 64), maxPixelSize: 500) == nil)
}
#endif
