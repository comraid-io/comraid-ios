import Foundation
import UserNotifications
import Testing
@testable import ComRaid

@Test func attributionRequiresDeliveryIdAndToken() {
  #expect(PushPayload.attribution(["cr_delivery_id": "d1"]) == nil)
  #expect(PushPayload.attribution([:]) == nil)
  let attr = PushPayload.attribution([
    "cr_delivery_id": "d1",
    "cr_attribution_token": "tok",
  ])
  #expect(attr?.deliveryId == "d1")
  #expect(attr?.attributionToken == "tok")
}

@Test func displayReadsCrTitleBodyAndImage() {
  let display = PushPayload.display([
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_image_url": "https://img",
  ])
  #expect(display.title == "Hello")
  #expect(display.body == "World")
  #expect(display.imageUrl == "https://img")
}

@Test func actionsParseCrActionsJSON() {
  let actions = PushPayload.actions([
    "cr_actions": #"[{"id":"accept","text":"Accept"},{"id":"x"}]"#,
  ])
  #expect(actions.count == 1)
  #expect(actions[0].id == "accept")
  #expect(actions[0].text == "Accept")
}

@Test func fromUserInfoFillsTitleBodyFromApsWhenMissing() {
  let data = PushPayload.fromUserInfo([
    "cr_delivery_id": "d1",
    "aps": [
      "alert": [
        "title": "NTitle",
        "body": "NBody",
      ],
    ],
  ])
  #expect(data["cr_title"] == "NTitle")
  #expect(data["cr_body"] == "NBody")
  #expect(data["cr_delivery_id"] == "d1")
}

@Test func displayReadsSoundBadgeAndThreadHints() {
  let display = PushPayload.display([
    "cr_title": "Hello",
    "cr_sound": "chime.caf",
    "cr_badge": "3",
    "cr_thread_id": "order-42",
  ])
  #expect(display.sound == "chime.caf")
  #expect(display.badge == 3)
  #expect(display.threadId == "order-42")
}

@Test func displayIgnoresBadOrNegativeBadge() {
  #expect(PushPayload.display(["cr_title": "Hello", "cr_badge": "lots"]).badge == nil)
  #expect(PushPayload.display(["cr_title": "Hello", "cr_badge": "-1"]).badge == nil)
  let display = PushPayload.display(["cr_title": "Hello"])
  #expect(display.sound == nil)
  #expect(display.threadId == nil)
}

@Test func fromUserInfoFillsSoundBadgeThreadFromAps() {
  let data = PushPayload.fromUserInfo([
    "aps": [
      "alert": ["title": "T", "body": "B"],
      "sound": "chime.caf",
      "badge": 2,
      "thread-id": "order-42",
    ],
  ])
  #expect(data["cr_sound"] == "chime.caf")
  #expect(data["cr_badge"] == "2")
  #expect(data["cr_thread_id"] == "order-42")
}

@Test func fromUserInfoPrefersCrHintsAndReadsCriticalSoundName() {
  let data = PushPayload.fromUserInfo([
    "cr_thread_id": "from-data",
    "aps": [
      "sound": ["critical": 1, "name": "alarm.caf"],
      "thread-id": "from-aps",
    ],
  ])
  #expect(data["cr_sound"] == "alarm.caf")
  #expect(data["cr_thread_id"] == "from-data")
}

@Test func senderDataStripsPresentationHints() {
  let sender = PushPayload.senderData([
    "order_id": "42",
    "cr_sound": "chime",
    "cr_badge": "1",
    "cr_thread_id": "t",
    "cr_priority": "normal",
  ])
  #expect(sender == ["order_id": "42"])
}

@Test func contentAppliesSoundBadgeAndThread() {
  let content = RemoteNotificationDisplay.content(from: [
    "cr_title": "Hello",
    "cr_sound": "chime.caf",
    "cr_badge": "4",
    "cr_thread_id": "order-42",
  ])
  #expect(content.sound == UNNotificationSound(named: UNNotificationSoundName("chime.caf")))
  #expect(content.badge == 4)
  #expect(content.threadIdentifier == "order-42")
}

@Test func contentDefaultsToSystemSoundAndNoBadge() {
  let content = RemoteNotificationDisplay.content(from: ["cr_title": "Hello", "cr_sound": "default"])
  #expect(content.sound == .default)
  #expect(content.badge == nil)
  #expect(content.threadIdentifier == "")
}

@Test func imageFileExtensionUsesMimeTypeThenUrl() {
  let url = URL(string: "https://cdn.example.com/a/photo")!
  #expect(RemoteNotificationDisplay.imageFileExtension(mimeType: "image/jpeg", url: url) == "jpg")
  #expect(RemoteNotificationDisplay.imageFileExtension(mimeType: "image/png", url: url) == "png")
  #expect(RemoteNotificationDisplay.imageFileExtension(mimeType: nil, url: url) == nil)
  let gif = URL(string: "https://cdn.example.com/a/anim.GIF?x=1")!
  #expect(RemoteNotificationDisplay.imageFileExtension(mimeType: "application/octet-stream", url: gif) == "gif")
  #expect(RemoteNotificationDisplay.imageFileExtension(mimeType: "image/webp", url: url) == nil)
}

@Test func imageAttachmentRejectsNonHttpUrls() async {
  #expect(await RemoteNotificationDisplay.imageAttachment(from: "file:///etc/hosts") == nil)
  #expect(await RemoteNotificationDisplay.imageAttachment(from: "not a url") == nil)
}
