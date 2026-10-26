# Profiles

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

**Read this before touching `ProfileStore`, `ProfileSession`, `ProfileScope`, `ActingProfile`,
`ProfileRoutes.swift`, `Accounts.deleteProfile`, `Notifier`'s audience, or anything that reads a
key out of `UserDefaults`.**

"A profile is a person; a mood is a board" (`ROADMAP.md`). Shopping for a partner needs their
own sizes, gender filter, follows, saves, taste and alerts; suits against streetwear is the same
person in another mood and needs only a board. A profile is therefore one whole person, and the
two concepts are never merged.

## The server: one user per profile

- **A profile is a `users` row under the account** (`users.account_id`, already non-unique so an
  account could hold several). Its follows, watches, poll hints, brand-check watchers and size
  profile are that user's, exactly as an anonymous user's are. Nothing new is personal; the
  catalogue is untouched.
- **The account holder's own profile is the account's oldest user** (`Accounts.primaryUser`,
  oldest first, ties broken by id so the answer cannot move). It is the user sign-in creates or
  adopts, and the one every device on the account belongs to. It cannot be deleted except by
  deleting the account — the account *is* that person, and an account with no holder would have
  nobody for sign-in to merge into.
- **Two columns, `AddUserProfiles`.** `users.display_name` (nullable — the holder needs none, and
  every anonymous user has none) and `users.alerts_enabled` (`NOT NULL DEFAULT true`, for the
  reason `follows.mode` is not nullable: `alerts_enabled = false` is NULL, not true, on a NULL row,
  and the obvious filter would silence everybody older than the migration). One `update()` per
  column. No array column, so the `TEXT[]` trap does not apply.
- **At most `Profiles.maxPerAccount` (6), names cleaned by `ProfileNaming.clean`** (whitespace
  collapsed, at most 24 characters). A name is printed at the start of every alert for that
  profile, so it is kept short, and the count bounds what one sign-in can make the notifier fan
  out over.
- **Deleting a profile removes that user's follows, watches, poll hints and brand-check watchers,
  then the user** (`Accounts.deleteProfile`, one transaction, each table by hand for the reason
  `Accounts.delete` gives). Never the catalogue. A device that somehow hangs off the profile is
  moved to the holder rather than deleted — a device is a phone, not a person.
- **Profiles share the account; they hold no balance and no location of their own.** Credits are
  the account's (`accounts.unlimited_credits` and whatever follows it). **Location, being built
  as `users.country`, must be read from the account holder's user** (`Accounts.holder(of:)`) for
  any user on an account: a profile is a person you shop *for*, and the shop is still in the
  holder's country. Reading the profile's own row would give every profile the column default.

### Which profile a request acts for

- **`X-Profile-ID: <user id>`, checked against the device's account** (`ProfileHeader.name`,
  `ActingProfile` in the authed group). Absent, the request acts for the device's own user —
  which is every request 1.0 and 1.1 make, every request from a device with no account, and
  every request the holder's profile makes. So no existing route changes for anybody who does
  not send it.
- **Present, it must name a user on the same account as the device's user**, or the request is
  refused with 403 and the reason `ProfileHeader.refusal`. A device with no account is refused
  too: profiles need an account. One rule in one middleware, so a route cannot forget it, and
  `req.actingUserID()` is the only way a route asks whose data it is touching.
- **Device-level routes ignore it**: the APNs token, the delivery check, usage reports, and the
  account routes themselves (sign-in, deletion, the profile list) act on the device and its
  account. `PATCH /v1/devices/me` is both — the token is the device's, the sizes are the acting
  profile's.
- **The refusal is a reason string the app recognises, not a status of its own.** A 403 is also
  what an edge or a WAF says, and the app must not abandon a profile on one of those; it falls
  back to the holder only on the exact reason (`APIError.profileRefused`).

### Push

- **A device on an account receives the alerts of every profile on that account with alerts on**
  (`Notifier.audience`). Devices belong to the holder, so a profile's devices are the account's
  devices; an anonymous user's are its own, as before.
- **Labelled "For Anna: …" when the profile is not the holder's** (`ProfileAlert.labelled`), on
  the body, so the title stays the brand. The holder's alerts read exactly as they did. Every
  path — the brand summary, the watch alert, the watched markdown, the brand-check reply — goes
  through the same audience, so a profile cannot be labelled on one and not another.
- **Each profile has its own switch** (`users.alerts_enabled`). Off means no push for that
  profile on any path. A watch still fires and is still stamped — "a watch is spent even when no
  device can receive it" — or turning alerts back on would release a burst of stale restocks.
- **One push per brand per cooldown, per profile.** The cooldown ledger is the brand's
  (`brands.last_notified_at`) and is unchanged, so within one pass each profile following a brand
  hears about it once and nobody hears again inside the cooldown. Two profiles following one
  brand on one phone get two alerts, each about its own person — the claim (`Notifier.Pair`) is
  per user, so a watch alert for Anna suppresses Anna's summary and nobody else's.
- **`collapseID` is per profile; `threadID` is still one for the app.** The holder keeps the
  brand id; another profile appends `/` and its first eight hex digits (APNs caps the id at 64
  bytes, and two UUIDs are 73). Without it Anna's alert about Kith would silently replace the
  holder's unread one, which is the collapse doing its job on the wrong pair. Grouping stays
  `PushGrouping.threadID` — profiles are one app's alerts.
- **The payload names the profile** (`PushPayload.profileID`, the recipient user's id, nil for an
  anonymous user), so tapping "For Anna" switches to Anna before it opens the item.

## The app: one SwiftData store per profile

**Decided: a store per profile, swapped at the root — not a profile id on every model.**

Tagging was the other option and it fails quietly in every direction this project has a rule
about:

- Every `@Query` and `FetchDescriptor` in the app (there are dozens) would need a profile
  predicate, and every `TasteScope` consumer would need to apply it. A missed one does not crash:
  it puts Anna's saves into the holder's taste, or Anna's unread rows into the holder's counts —
  the "every visible count is subject to the same filter" rule, broken by omission.
- `BrandUpdate.externalID` and `Brand.remoteID` are the dedupe keys, and two profiles following
  Kith are two different readers of the same events: read state, arrival stamps, follow modes and
  saves all differ. Sharing rows would need per-profile copies of `isSeen` and friends; not
  sharing them means the dedupe keys stop being unique, which every merge assumes.
- A field added to eight models is eight lenient-decoding obligations, and narrowing on it in a
  `#Predicate` is the shape `docs/performance.md` warns costs a fault per row.

A store per profile makes partitioning a property of the container, which no query can forget:

- **`ProfileScope`** is who the app is acting for: nil for the holder — and for every install
  that has never signed in, which is the implicit one profile — or a profile's user id.
- **The holder's store is `default.store`, unchanged, and its `UserDefaults` keys are the
  unscoped ones.** That is the whole upgrade: nothing moves, nothing is migrated, and the 1.1
  data simply *is* the holder's profile. A profile's store is `profile-<id>.store` beside it,
  and its keys are `<key>.<id>` (`ProfileScope.key`).
- **`ProfileSession` holds everything that is about one person** — the container, sizes, the
  style statement, `RemoteSync`, `SyncEngine`, the Discover deck, recommendations, the save
  confirmation, the collection route and the drop-hint status — and **a switch builds a new one
  rather than resetting the old.** Resetting nine objects by hand is nine chances to leave one
  person's state in another's page. The root view is keyed on the scope (`.id`), so every `@State`
  and `@Query` below it is rebuilt against the new container.
- **An in-flight sync finishes in the store it started in.** Each session's `RemoteSync` captures
  its own context, its own keys and its own `X-Profile-ID`; nothing reads "the current profile"
  halfway through a sync. A switch mid-sync therefore lets the old pass land in the old store
  rather than writing one person's feed into another's.
- **App-level objects stay app-level**: `ServerSettings` (the token and account are the device's),
  `PushRoute` (a tap can arrive before any view), `YouRoute`, `DiscoveryAnalysis` (measurements of
  photographs, not of a person), the usage counts and the share inbox.
- **Saves, boards, fits, the style statement and the taste vector stay local**, as they always
  were. Partitioning by store changes where they live on the phone and nothing about where they
  go: still nowhere.
- **`UserDefaults` keys that describe a person are scoped; keys that describe the phone are not.**
  Scoped: sizes, the style statement, the feed cursor and pending reads, pending unfollows and
  watch deletions, the Discover ledger, Shop's picks, the feed's visit line, drop-hint state and
  the starter-pack latch. Device: the server address, token and account, `didRegisterAfresh`, the
  usage tally, the saved-price-drop alert setting and every dev flag. A new key has to be put in
  one list or the other (`ProfileScope.scopedKeys`), which is also what deletion clears.
- **Local alerts carry the label too.** `WatchNotifier`, `PriceAlerts` and `DropReminders` run on
  the current store and label for a non-holder scope with the same `ProfileAlert.labelled`. Drop
  reminders are prefixed per profile (`drop-` for the holder, unchanged; `drop@<id>-` for a
  profile), so rewriting one profile's set never clears another's. Watches and price drops of a
  profile that is not current are said by the server; locally they wait until it is.

### Switching, adding and losing a profile

- **Profiles need an account.** Signed out, standalone, or against a server that answers no
  profile list, there is exactly one implicit profile and nothing on screen mentions profiles.
  A remembered profile id is ignored unless the device is signed in and the id is in the list.
- **Adding a profile does not switch to it.** The row appears and says *Switch*. Switching to a
  new profile lands on onboarding, because its store has no brands and its starter-pack latch is
  its own — which is the right first screen for setting somebody else up.
- **The share extension saves into the profile that was current when it ran**
  (`SharedInbox.currentProfile`, a file in the App Group container rather than a
  `UserDefaults(suiteName:)`, which the privacy manifest says does not exist). Each share carries
  its `profileID`, and the app drains only the current profile's items, so a share filed while
  Anna was current lands in Anna's wall whenever Anna is next current. A share for a profile this
  phone no longer has lands in the holder's, rather than waiting forever.
- **A profile's local store goes with the profile.** Deleting it on this phone deletes its store
  and its scoped keys; a list from the server that no longer names a profile (deleted on another
  phone) does the same. Deleting the account deletes every profile's store and keeps the holder's,
  which was the phone's before there was an account and stays the phone's after.
- **A refused profile falls back to the holder** (`APIError.profileRefused`): deleted elsewhere,
  account deleted elsewhere, or the device re-registered. The store is not deleted on a refusal —
  only a list that omits the profile does that — so a misread refusal costs a switch, not data.
- **A re-registration is the holder's to spend.** `didRegisterAfresh` re-follows the store's
  brands on the new anonymous device; a profile session that sees it set does not consume it
  (that would re-follow Anna's brands as the holder) and falls back to the holder instead.
- **Tapping an alert for another profile switches first** (`PushPayload.profileID`), then syncs
  and opens the item in that profile's store.
- **Each profile's watches come back from the server** (`RemoteSync.mergeWatches`). A watch the
  server holds and the store does not — a reinstall signing in, a profile opened for the first
  time on this phone — is rebuilt against the store's row for that product, or against a row made
  from what `GET /v1/watches` now says about the product (title, photographs, link, price,
  variants), stored read. A deletion still being sent is remembered (`pendingWatchDeletes`) so the
  restore cannot undo it. Before this, a reinstall's watches kept firing server-side while the
  Watching page was empty. A watch is sent by its product's id (`productExternalID`), never the
  feed row's `event:` key, which the route could never find.
- **A signed-in phone must launch signed in.** `ServerSettings.init` reads the token and the
  account before assigning either: on an `@Observable` class the token's `didSet` runs in `init`,
  and it cleared the account on every launch — invisible until profiles, which need the account
  at launch to restore the current one.
- **One registration at a time, across sessions.** A switch builds a session whose launch sync
  can race the old session's work; two callers that both find no token used to mint two devices.
  `RemoteSync.ensureRegistered` shares the one in flight.

### Known gaps

- Background refresh and push wakes sync the current profile only. Other profiles' feeds catch
  up when they are next current; their alerts are the server's and do not depend on it.
- `PriceAlerts` reads saves, which never leave the phone, so a markdown on a save of a profile
  that is not current is said when that profile is next current.
- A phone holds the stores of the account it is signed into. Signing into a different Apple ID
  on the same phone prunes the previous account's profile stores once its list arrives.
