# Dates you know and the app cannot

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Dates you know and the app cannot

Everything else the app announces is retrospective — an event landed, and then it said so. The drop
calendar is the one screen about the future and it announced nothing at all: you could read
"28 Aug · 11:00", close the app, and hear from it for the first time when the drop was already
gone. The countdown was doing a notification's job, and only while you were looking at it.

- **A hand-entered date is a fourth kind of claim, labelled as such.** The other three are
  *observed* — a storefront locked right now, a product with a future publication date, a rhythm
  read from history — and that is the correct bar for anything the app asserts on its own.
  `PlannedDrop` is the one that isn't, so the row says "ADDED BY YOU" and it is never blended with a
  date a storefront stated. It exists because two cases hurt: a locked storefront with no stated
  time is the strongest signal in the app arriving with no countdown, and a brand that never locks
  and never publishes a date gives no machine-readable sign until the products are already up.
- **Local only, and that is the same bargain `StyleStatement` makes.** A date somebody typed is a
  personal claim, not a fact about the catalogue — one person being wrong about a Thursday must not
  become everybody's Thursday. It also settles the mechanism: local notifications need no APNs key,
  no round trip, and fire with the phone offline.
- **Two alerts, because they answer different questions.** 09:00 on the day is a planning fact — it
  decides whether you are near a phone at eleven. The one at the release is the one that matters;
  streetwear is decided in the first minute. A drop early enough that 09:00 falls *after* it gets
  only the second, because `UNCalendarNotificationTrigger` matches *components* and a past
  `DateComponents` silently rolls forward to the same time next year.
- **`DropReminders.refresh` rewrites the whole set rather than diffing it**, and runs on every
  foreground as well as on every edit. Diffing means tracking outstanding identifiers across edits,
  deletions, renames and permission being revoked and granted again, and a reconciliation that can
  drift produces the one failure this cannot have — an alert about a drop somebody deleted, or
  silence about one they did not. The foreground pass is specifically about **permission**: a drop
  is normally written down *before* notifications are allowed, the grant happens in iOS Settings
  where this app is not running, and nothing else would ever go back and schedule the alerts. The
  row would sit there looking armed and the drop would pass without a word.
- **It clears only its own `drop-` prefixed requests.** `WatchNotifier` schedules `watch-<uuid>`
  into the same notification centre and a blanket `removeAllPendingNotificationRequests()` takes
  those with it.
- **The payload carries `brand.remoteID`, not `Brand.id`.** `ContentView.follow` resolves a tapped
  notification against `remoteID`; the local id finds nothing and drops the tap on the feed.
- **A manual date now tightens the poller too, and that is the only thing about it that leaves
  the phone** (`DropHints`, `PollHintPolicy`, `PUT /v1/poll-hints`). The reminder firing at eleven
  is half the job; the products still have to have been *found* by eleven, and the ordinary
  cadence is twenty minutes or two hours. A brand with a readable rhythm already gets 60 seconds
  inside its own window (`Cadence.next(inDropWindow:)`), so this is deliberately the minority
  case: the brand that never locks and never publishes a date until the products are up. Sixty
  seconds is not a new capability — a locked storefront already reaches it.
  **One brand id and one instant cross, and nothing else.** Not the title, not the note, not how
  many drops you track. No row anybody else can read, no event, no notification: the most a hint
  can do is make the poller look sooner, so nobody else's Thursday moves. The calendar itself
  stays local, exactly as `PlannedDrop` says.
  **The exploit is resource exhaustion, so it is bounded in two independent places.** What one
  account may *ask for* is in `PollHintPolicy` and on the route — a device token, a follow on the
  brand (re-checked, and revoked with the follow in `DELETE /v1/follows/:brandID`, or "follow,
  hint, unfollow" holds a window on a stranger's storefront), one hint per brand, `maxPerUser` of
  them, `maxLeadTime` ahead, and a window length the client cannot name because it is not on the
  wire. What all of them together may *get* is `Poller.hintBudget`: hinted sources are claimed
  against a **separate fixed budget** and the ordinary claim explicitly excludes them, so hinting
  more brands divides the same five sources per tick rather than buying more, and the general
  queue cannot be starved by construction rather than by tuning. `PoliteFetcher` still spaces
  every request per host on top.
  Two details worth keeping. An oversized set is **refused whole rather than truncated** — quietly
  keeping the first twenty of somebody's thirty is the class of silent wrong answer this file is a
  list of — and a refusal **names which of the four reasons it was**, because "your hint didn't
  work" is equally true for an unfollowed brand, an unknown id and a date that has passed.
  The client sends its **whole set** on every change and every foreground, for the reason
  `DropReminders.refresh` rewrites rather than diffs: a reconciliation that can drift means the
  server polling hard for a drop somebody deleted in March. It is fingerprinted so an unchanged
  set costs no request, and the device token is folded into that fingerprint — otherwise a
  reinstall reads "already sent" forever and the hints silently never exist.
- **…and the row says whether it took** (`DropHintStore`, `DropCalendarView.watchLine`). A hint is
  invisible when it works and invisible when it doesn't: the row reads "added by you" either way,
  the reminders fire either way, and the only difference is whether the products are there when
  the alert arrives — the "every layer reports healthy and the feature does not exist" failure
  again. So the server's reply is kept and printed. Four states, and the two in the middle are why
  it is not a boolean: `WATCHING FROM 22:45` — the window start, computed from the width the
  *server* echoed rather than from a local constant, since the two deploy separately — `queued`,
  meaning the brand is covered but for an earlier drop (`DropHints.build` sends the soonest per
  brand), `refused`, naming which of the four reasons, and `local`, which prints **nothing**
  because standalone still does exactly what the line above already promises and repeating it in
  a more worrying voice helps nobody. Vermilion only on `refused`: an accent on every healthy row
  makes the one broken row invisible. Only on a date *you* entered — the other three kinds are
  observed and narrating cadence on them would be the app explaining its plumbing. The editor
  says it once too, where the date is being typed, because nobody would otherwise guess that
  writing a time down changes anything. Measured end to end against a real Kith catalogue: the
  same source polls at **7201s without a hint and 60s with one**.
