import Foundation
import Testing
import UserNotifications
@testable import ComRaid

@Test func differentButtonSetsGetDifferentCategoryIds() {
  let accept: [String: String] = [
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ]
  let decline: [String: String] = [
    "cr_actions": #"[{"id":"decline","text":"Decline"}]"#,
  ]
  let acceptCategory = RemoteNotificationDisplay.categories(from: accept)[0]
  let declineCategory = RemoteNotificationDisplay.categories(from: decline)[0]

  #expect(acceptCategory.identifier != declineCategory.identifier)
  #expect(acceptCategory.identifier.hasPrefix("comraid.actions."))
  #expect(declineCategory.identifier.hasPrefix("comraid.actions."))
  #expect(acceptCategory.identifier != RemoteNotificationDisplay.actionsCategoryIdentifier)
}

@Test func sameButtonSetReusesOneCategoryId() {
  let first: [String: String] = [
    "cr_actions": #"[{"id":"accept","text":"Accept"},{"id":"later","text":"Later"}]"#,
  ]
  let second: [String: String] = [
    "cr_actions": #"[{"id":"accept","text":"Accept"},{"id":"later","text":"Later"}]"#,
  ]
  let id1 = RemoteNotificationDisplay.categories(from: first)[0].identifier
  let id2 = RemoteNotificationDisplay.categories(from: second)[0].identifier
  #expect(id1 == id2)
  #expect(id1.hasPrefix("comraid.actions."))
}

@Test func contentCategoryMatchesHashedCategoryFromSameButtons() {
  let data: [String: String] = [
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ]
  let content = RemoteNotificationDisplay.content(from: data)
  let categories = RemoteNotificationDisplay.categories(from: data)
  #expect(categories.count == 1)
  #expect(content.categoryIdentifier == categories[0].identifier)
  #expect(content.categoryIdentifier.hasPrefix("comraid.actions."))
}

@Test func categoryActionsKeepPayloadActionIds() {
  let data: [String: String] = [
    "cr_actions": #"[{"id":"accept","text":"Accept"},{"id":"decline","text":"Decline"}]"#,
  ]
  let category = RemoteNotificationDisplay.categories(from: data)[0]
  #expect(category.actions.map(\.identifier) == ["accept", "decline"])
  #expect(category.actions.map(\.title) == ["Accept", "Decline"])
}

@Test func mergingCategoriesKeepsHostAndDistinctComRaidIds() {
  let host = UNNotificationCategory(
    identifier: "host.custom",
    actions: [],
    intentIdentifiers: [],
    options: []
  )
  let accept = RemoteNotificationDisplay.categories(from: [
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ])
  let decline = RemoteNotificationDisplay.categories(from: [
    "cr_actions": #"[{"id":"decline","text":"Decline"}]"#,
  ])
  let merged = RemoteNotificationDisplay.mergingCategories(
    existing: [host],
    with: accept + decline
  )
  let ids = Set(merged.map(\.identifier))
  #expect(ids.contains("host.custom"))
  #expect(ids.contains(accept[0].identifier))
  #expect(ids.contains(decline[0].identifier))
  #expect(accept[0].identifier != decline[0].identifier)
}

@Test func enrichmentsOverrideServerCategoryWithHashedId() {
  let data: [String: String] = [
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ]
  let original = UNMutableNotificationContent()
  original.title = "Hello"
  original.body = "World"
  original.userInfo = data
  original.categoryIdentifier = RemoteNotificationDisplay.actionsCategoryIdentifier
  let request = UNNotificationRequest(identifier: "enrich-test", content: original, trigger: nil)

  let enriched = RemoteNotificationDisplay.applyingEnrichments(to: request, data: data)
  let expected = RemoteNotificationDisplay.categories(from: data)[0].identifier
  #expect(enriched.categoryIdentifier == expected)
  #expect(enriched.categoryIdentifier != RemoteNotificationDisplay.actionsCategoryIdentifier)
}
