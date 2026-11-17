import Foundation
import Testing
@testable import ComRaid

@Test func isDataOnlyReadsCrDataOnly() {
  #expect(PushPayload.isDataOnly(nil) == false)
  #expect(PushPayload.isDataOnly([:]) == false)
  #expect(PushPayload.isDataOnly(["cr_data_only": "false"]) == false)
  #expect(PushPayload.isDataOnly(["cr_data_only": "true"]) == true)
  #expect(PushPayload.isDataOnly(["cr_data_only": "1"]) == true)
  #expect(PushPayload.isDataOnly(["cr_data_only": " TRUE "]) == true)
}

@Test func messageIdReadsCrMessageId() {
  #expect(PushPayload.messageId([:]) == nil)
  #expect(PushPayload.messageId(["cr_message_id": "m1"]) == "m1")
}

@Test func senderDataStripsCrKeysPreservesAppKeys() {
  let data: [String: String] = [
    "path": "/orders/1",
    "params": #"{"id":1}"#,
    "cr_delivery_id": "d1",
    "cr_attribution_token": "tok",
    "cr_message_id": "m1",
    "cr_title": "Hi",
    "cr_body": "Body",
    "cr_deep_link": "app://x",
    "cr_actions": "[]",
    "cr_data_only": "true",
    "cr_image_url": "https://x",
    "cr_android_channel_id": "general",
  ]
  #expect(PushPayload.senderData(data) == [
    "path": "/orders/1",
    "params": #"{"id":1}"#,
  ])
}

@Test func deepLinkReadsCrDeepLink() {
  #expect(PushPayload.deepLink([:]) == nil)
  #expect(PushPayload.deepLink(["cr_deep_link": "app://home"]) == "app://home")
  #expect(PushPayload.deepLink(["cr_deep_link": "not-a-uri"]) == nil)
}

@Test func remoteMessageMapperBuildsEventAndStripsReservedKeys() {
  let event = RemoteMessageMapper.toEvent([
    "cr_delivery_id": "d1",
    "cr_attribution_token": "tok",
    "cr_message_id": "m1",
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_deep_link": "app://x",
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
    "cr_data_only": "true",
    "path": "/invite",
  ], actionId: "accept")
  #expect(event.messageId == "m1")
  #expect(event.deliveryId == "d1")
  #expect(event.attributionToken == "tok")
  #expect(event.title == "Hello")
  #expect(event.body == "World")
  #expect(event.deepLink == "app://x")
  #expect(event.actionId == "accept")
  #expect(event.data == ["path": "/invite"])
  #expect(event.actions.count == 1)
  #expect(event.actions[0].id == "accept")
}

@Test func remoteMessageMapperCarriesPresentationFieldsOutsideData() {
  let event = RemoteMessageMapper.toEvent([
    "cr_title": "Hello",
    "cr_image_url": "https://cdn.example.com/a.png",
    "cr_subtitle": "Order update",
    "cr_sound": "chime.caf",
    "cr_badge": "3",
    "cr_thread_id": "order-42",
    "cr_android_channel_id": "orders",
    "cr_priority": "normal",
    "order_id": "42",
  ])
  #expect(event.imageUrl == "https://cdn.example.com/a.png")
  #expect(event.subtitle == "Order update")
  #expect(event.sound == "chime.caf")
  #expect(event.badge == 3)
  #expect(event.threadId == "order-42")
  #expect(event.androidChannelId == "orders")
  #expect(event.priority == "normal")
  #expect(event.data == ["order_id": "42"])
}

@Test func remoteMessageMapperLeavesPresentationFieldsNilWhenAbsent() {
  let event = RemoteMessageMapper.toEvent(["cr_title": "Hello", "cr_badge": "lots"])
  #expect(event.imageUrl == nil)
  #expect(event.subtitle == nil)
  #expect(event.sound == nil)
  #expect(event.badge == nil)
  #expect(event.threadId == nil)
  #expect(event.androidChannelId == nil)
  #expect(event.priority == "high")
}

@Test func remoteMessageMapperTreatsBlankPresentationFieldsAsAbsent() {
  let event = RemoteMessageMapper.toEvent([
    "cr_title": "Hello",
    "cr_subtitle": "  ",
    "cr_android_channel_id": "",
    "cr_priority": "  ",
  ])
  #expect(event.subtitle == nil)
  #expect(event.androidChannelId == nil)
  #expect(event.priority == "high")
}

@Test func senderDataStripsCrSubtitle() {
  #expect(PushPayload.senderData([
    "order_id": "42",
    "cr_subtitle": "Hidden",
  ]) == ["order_id": "42"])
}

@Test func fromUserInfoFillsSubtitleFromApsAlert() {
  let data = PushPayload.fromUserInfo([
    "aps": [
      "alert": [
        "title": "T",
        "body": "B",
        "subtitle": "From aps",
      ],
    ],
  ])
  #expect(data["cr_subtitle"] == "From aps")
}

@Test func fromUserInfoPrefersCrSubtitleOverAps() {
  let data = PushPayload.fromUserInfo([
    "cr_subtitle": "From data",
    "aps": [
      "alert": ["subtitle": "From aps"],
    ],
  ])
  #expect(data["cr_subtitle"] == "From data")
}

@Test func remoteMessageMapperRoundTripsPresentationFields() {
  let payload: [String: String] = [
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_image_url": "https://cdn.example.com/a.png",
    "cr_subtitle": "Order update",
    "cr_sound": "chime.caf",
    "cr_badge": "3",
    "cr_thread_id": "order-42",
    "cr_android_channel_id": "orders",
    "cr_priority": "normal",
    "order_id": "42",
  ]
  let roundTripped = RemoteMessageMapper.toPayload(RemoteMessageMapper.toEvent(payload))
  #expect(roundTripped["cr_image_url"] == "https://cdn.example.com/a.png")
  #expect(roundTripped["cr_subtitle"] == "Order update")
  #expect(roundTripped["cr_sound"] == "chime.caf")
  #expect(roundTripped["cr_badge"] == "3")
  #expect(roundTripped["cr_thread_id"] == "order-42")
  #expect(roundTripped["cr_android_channel_id"] == "orders")
  #expect(roundTripped["cr_priority"] == "normal")
  #expect(roundTripped["order_id"] == "42")
  #expect(roundTripped["cr_title"] == "Hello")
}
