import Foundation
import Testing
import UserNotifications
@testable import ComRaid

@Test func dataOnlyNeverPresentsEvenWithTitleAndActions() {
  let dataOnly: [String: String] = [
    "cr_delivery_id": "d1",
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_data_only": "true",
  ]
  let withActions = dataOnly.merging([
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ]) { _, new in new }

  #expect(RemoteDisplayPolicy.presentationOptions(
    data: dataOnly,
    displayForegroundNotifications: true
  ).isEmpty)
  #expect(RemoteDisplayPolicy.presentationOptions(
    data: withActions,
    displayForegroundNotifications: true
  ).isEmpty)
}

@Test func foregroundAlertPresentsByDefault() {
  let options = RemoteDisplayPolicy.presentationOptions(
    data: [
      "cr_delivery_id": "d1",
      "cr_title": "Hello",
      "cr_body": "World",
    ],
    displayForegroundNotifications: true
  )
  #expect(!options.isEmpty)
  #expect(options.contains(.sound))
}

@Test func foregroundOptOutSuppressesPresentation() {
  let alert: [String: String] = [
    "cr_delivery_id": "d1",
    "cr_title": "Hello",
    "cr_body": "World",
  ]
  #expect(RemoteDisplayPolicy.presentationOptions(
    data: alert,
    displayForegroundNotifications: false
  ).isEmpty)
}

@Test func blankTitleNeverPresents() {
  #expect(RemoteDisplayPolicy.presentationOptions(
    data: ["cr_delivery_id": "d1", "cr_body": "only body"],
    displayForegroundNotifications: true
  ).isEmpty)
}

@Test func presentNotificationContentRequiresTitleAndKeepsPayload() {
  let content = RemoteNotificationDisplay.content(from: [
    "cr_delivery_id": "d1",
    "cr_attribution_token": "tok",
    "cr_title": "Rematch",
    "cr_body": "Accept?",
    "cr_subtitle": "Now",
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
    "path": "/rematch",
  ])
  #expect(content.title == "Rematch")
  #expect(content.body == "Accept?")
  #expect(content.subtitle == "Now")
  #expect(content.userInfo["cr_delivery_id"] as? String == "d1")
  #expect(content.userInfo["path"] as? String == "/rematch")
  #expect(content.categoryIdentifier == "comraid.actions")
}
