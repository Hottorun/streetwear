// PlannedDrop.swift
// A release you know about and the app cannot.
//
// The Upcoming page is built out of three kinds of claim, and every one of them is
// *observed*: a storefront that is password-walled right now, a product carrying a future
// publication date, a rhythm read out of a brand's own history. That is the correct bar for
// something the app asserts on its own, and it leaves a large hole — because most of what a
// person actually knows about an upcoming drop did not come from the storefront at all. It
// came from the brand's Instagram, a newsletter, a group chat, or a friend.
//
// The two cases that hurt:
//
// - **A locked storefront with no stated time.** This is the app's strongest signal and it
//   arrives half-finished: the calendar can say "locked", and can very often say nothing
//   about *when*, because `DropDateParser` only reads dates a page has explicitly labelled
//   and a password wall labels nothing. So the one row somebody most wants a countdown on
//   is the one row that has none.
// - **A brand that never locks and never publishes a date.** Stüssy announces a Friday
//   release and the storefront gives no machine-readable sign of it until the products are
//   already up — which is exactly too late.
//
// So this is the fourth kind, and it is labelled as honestly as the other three: **you said
// so**. It is never inferred, never merged with an observed date, and never guessed at.
//
// **Local only, and deliberately.** A hand-entered date is a personal claim, not a fact
// about the catalogue — the same line `StyleStatement` and the taste vector sit on, and the
// same reason the server's tables have no `user_id` on anything catalogue-shaped. One
// person being wrong about a Thursday must not become everybody's Thursday. It also means
// the reminders are local notifications, which is the right mechanism anyway: a scheduled
// alert needs no APNs key, no server round trip, and works with the phone offline.

import Foundation
import SwiftData

@Model
final class PlannedDrop {
    var id: UUID = UUID()

    /// Which brand this is about. Optional only because SwiftData relationships are, and
    /// because a brand can be unfollowed out from under a row — `brandName` is what keeps
    /// the entry readable when that happens.
    var brand: Brand?

    /// The brand's name, copied at the time it was added.
    ///
    /// Not redundant. Unfollowing a brand nullifies the relationship, and a reminder that
    /// then fires saying "something drops in 10 minutes" without saying what is worse than
    /// no reminder. The notification is scheduled once, months ahead; it has to carry
    /// everything it will need to say.
    var brandName: String = ""

    /// What is dropping, when that is known. Empty is normal and fine — "Stüssy, Friday
    /// 11am" is a complete thought.
    var title: String = ""

    var releaseAt: Date = Date()

    /// Anything else worth remembering — where the date came from, usually.
    var note: String?

    var createdAt: Date = Date()

    /// A heads-up on the morning of the release.
    var remindsOnTheDay: Bool = true

    /// And one at the moment it opens. In streetwear this is the one that matters: a
    /// release is decided in its first minute, so an alert an hour later is a notification
    /// about something that has already sold out.
    var remindsAtRelease: Bool = true

    init(
        brand: Brand?,
        title: String = "",
        releaseAt: Date,
        note: String? = nil,
        remindsOnTheDay: Bool = true,
        remindsAtRelease: Bool = true
    ) {
        self.id = UUID()
        self.brand = brand
        self.brandName = brand?.name ?? ""
        self.title = title
        self.releaseAt = releaseAt
        self.note = note
        self.createdAt = Date()
        self.remindsOnTheDay = remindsOnTheDay
        self.remindsAtRelease = remindsAtRelease
    }

    /// What a notification and a row both call this.
    var label: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New drop" : title
    }

    var isPast: Bool { releaseAt <= Date() }

    /// When the morning heads-up should land: 9am on the day of the release.
    ///
    /// Nil when that moment has already gone, which includes the ordinary case of a drop
    /// added *on* the day it happens — there is no point scheduling a reminder for this
    /// morning at four in the afternoon, and `UNCalendarNotificationTrigger` would silently
    /// roll a past `DateComponents` forward to the same time next year.
    func morningReminder(calendar: Calendar = .current, now: Date = Date()) -> Date? {
        guard let morning = calendar.date(
            bySettingHour: Self.morningHour, minute: 0, second: 0, of: releaseAt
        ) else { return nil }
        // A drop at 8am has no useful "morning of" slot distinct from the release itself.
        guard morning > now, morning < releaseAt else { return nil }
        return morning
    }

    /// Early enough to be read over breakfast, late enough not to be an alarm clock.
    static let morningHour = 9
}
