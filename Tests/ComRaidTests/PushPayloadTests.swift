import Foundation
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
