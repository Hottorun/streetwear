# Profiles

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

**Read this before touching `ProfileStore`, `ProfileStores`, `ProfileSession`, `ProfileScope`,
`BackgroundServices.syncProfiles`, `ActingProfile`,
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
- **Profiles share the account's credits and location.** A profile is somebody you shop *for*,
  and it is still your money and your country.
  - **Credits**: every credit route (`GET /v1/credits`, purchases) reads the *device's* user,
    never the acting one, so a spend, a purchase or a balance asked as any profile is the one
    account ledger (`CreditLedger.accountID`). A profile has no balance of its own.
  - **Location is written to every user of the account** (`Accounts.setCountry`) — by
    `PATCH /v1/devices/me` sent as any profile, by the sign-in merge (the account's country,
    else the device's), and when a profile is made (its holder's). It is a copy rather than a
    lookup through the holder because `users.country` has three readers: `Storefronts.wanted`
    (a join from follows to users, in SQL, every tick — so a profile's follow counts for the
    country's shop), `Storefronts.serving` (feed, brand feed, Discover, every `BrandDTO`) and
    `Notifier` per recipient. Routing each through the account's oldest user would be a second
    join in three places, and one missed reader would serve a profile the main shop or leave a
    country's shop unpolled; three writers through one function is the smaller surface.
    Registration writes it directly: an anonymous user has no account to share.
  - On the phone, `LocationSetting` and `CreditStore` are app-level, not per session: a switch
    neither resets the country nor rebuilds the balance, and You's credits task is keyed on the
    token and account, not the profile.

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
  data simply *is* the holder's profile. Every other store is filed under its account —
  `Accounts/<account>/profile-<id>.store` — and its keys are `<key>.<home>`
  (`ProfileScope.key`, `ProfileScope.home`). See *Another Apple ID on the same phone* below for
  the one holder that does not get `default.store`.
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
  watch deletions, the Discover ledger, Shop's picks, the feed's visit line, drop-hint state,
  the starter-pack latch and the questions and follows shares are waiting on (`ShareQuestions`).
  The share sheet's own picture of a store (`SharedContext`) is a file per store in the App
  Group, not a key. Device: the server address, token and account, `didRegisterAfresh`, the
  usage tally, the saved-price-drop alert setting and every dev flag. A new key has to be put in
  one list or the other (`ProfileScope.scopedKeys`), which is also what deletion clears.
- **Local alerts carry the label too.** `WatchNotifier`, `PriceAlerts` and `DropReminders` run on
  one profile's store and label for a non-holder scope with the same `ProfileAlert.labelled`, and
  carry its `profileID`, so tapping one switches to that profile through the same
  `ProfileStore.adopt(pushedFor:)` a server push uses. They run for every profile on the
  account, not only the current one — see *The background pass* below. Drop reminders are
  prefixed per **store** (`drop-` for `default.store`, unchanged; `drop@<home>-` for any other),
  so rewriting one profile's set never clears another's, and the holder of a second Apple ID
  does not share `drop-` with the first one's holder.

### The background pass

- **A background refresh or a push wake syncs every profile on the account, each into its own
  store** (`BackgroundServices.syncProfiles`). It used to sync the current store only, so another
  profile's feed was as old as the last switch to it, and the alerts said on the phone —
  `PriceAlerts` on that profile's saves, `WatchNotifier` — waited for the same switch.
- **One merge path.** Each profile goes through the very `RemoteSync.sync` the foreground uses,
  built over the container this launch already holds for that store, with that profile's keys,
  sizes and `X-Profile-ID` (`ProfileStore.syncer`). The current profile's is the session's own.
  Not the full `ProfileSession`: the deck, the suggestions and the confirmation are a screen's,
  and nobody is looking.
- **The order is the budget.** iOS allows about thirty seconds. The profile a push names goes
  first, then the current one, then the rest by when a pass last reached them
  (`backgroundPassAt`, a phone key). The pass starts nothing new after `passBudget` (22s) and
  stops at once when iOS expires the task; whoever it missed is first in line next time, because
  only a sync that finished is stamped. A push that arrives with the app open syncs the one
  profile it names, because the banner waits on it.
- **One writer per store.** `RemoteSync.sync` takes a per-store lock across every instance
  (`StoreWriters`): a background pass **skips** a store the foreground is syncing, and a
  foreground sync **waits** for a background one on the store it was just switched to. Two
  merges interleaving on one context at every `await` would each decide what is new from rows
  the other is halfway through writing.
- **Drop reminders are rewritten from each store in the pass too**, so a profile that is not
  current still has its reminders armed after permission was granted while another was on
  screen.
- **Verified on the simulator with `-debugBackgroundPass YES`**, which runs the same pass when the
  app is backgrounded, under a background-task assertion. The simulator cannot run a
  `BGAppRefreshTask` without lldb attached (`_simulateLaunchForTaskWithIdentifier:`), and refuses
  a silent `simctl push` as having no visible content. With the holder current, four events for a
  profile's brand landed in that profile's store, unread and arrived.

### Switching, adding and losing a profile

- **Profiles need an account.** Signed out, standalone, or against a server that answers no
  profile list, there is exactly one implicit profile and nothing on screen mentions profiles.
  A remembered profile id is ignored unless the device is signed in and the id is in the list.
- **Adding a profile does not switch to it.** The row appears and says *Switch*. Switching to a
  new profile lands on onboarding, because its store has no brands and its starter-pack latch is
  its own — which is the right first screen for setting somebody else up.
- **The share extension saves into the store that was current when it ran**
  (`SharedInbox.currentProfile`, a file in the App Group container rather than a
  `UserDefaults(suiteName:)`, which the privacy manifest says does not exist). Each share carries
  that store's `home` in `profileID`, and the app drains only the current store's items, so a
  share filed while Anna was current lands in Anna's wall whenever Anna is next current — and a
  share filed while another Apple ID was signed in waits for that account, never landing in a
  hidden account's wall or in this one's. A share for a store this phone no longer has lands in
  the current holder's, rather than waiting forever.
- **A profile's local store goes with the profile.** Deleting it on this phone deletes its store
  and its scoped keys; a list from the server that no longer names a profile (deleted on another
  phone) does the same — **only the signed-in account's list, and only in that account's
  directory**. Deleting the account deletes every store filed under it. `default.store` stays
  when the account owned it — it was the phone's before there was an account and stays the
  phone's after, free for the next account to sign in — and the confirmation says which of the
  two the holder's saves are (`ProfileStore.accountDeletionKeepsSaves`).

### Another Apple ID on the same phone

The phone used to hold only the signed-in account's stores: signing into a second Apple ID
pruned the first one's profile stores the moment its list arrived, so Anna's saves, boards and
fits were gone from the phone for good because somebody else had signed in. Now:

- **Stores are filed by account and hidden, not deleted** (`ProfileStores`). Signed in, the app
  shows only that account's stores; the rest wait in their directories, untouched by any list, and
  come back with their saves, boards and fits when that account signs in again. Only three things
  delete a store: deleting its profile, deleting its account from this phone, and Remove (below).
- **`default.store` belongs to the first account that signs in** (`ProfileStores.owner`, a phone
  key). What was on the phone signed out becomes that account's holder profile — the rule from
  before, kept. **A later Apple ID gets an empty holder store of its own**,
  `Accounts/<account>/holder.store`, whose `home` is the account's id. It still sends no header:
  it is the holder.
- **Signed out, the phone shows `default.store`, whoever owns it.** There is no sign-out in the
  app: a phone is signed out by deleting the account (which releases `default.store`) or by a
  token the server no longer knows, which re-registers as nobody. The latter is the owner's own
  phone more often than not, and it keeps working on the phone's data as it did before accounts.
  `ServerSettings.accountChanged` moves the app off any account's own store the moment that
  happens, and `RemoteSync.sync` refuses to sync a store filed under an account that is not
  signed in — before both, a lapsed token left the phone on the second account's store and
  re-followed its brands on the new anonymous device.
- **Unowned again after Remove.** If Remove deletes `default.store`, the next account to sign in
  without a holder store of its own takes the empty one; an account that has one keeps it.
- **Hidden accounts' drop reminders are cancelled** (`DropReminders.retain`), because "Supreme
  drops today" on somebody else's phone session is the first account's calendar read out to
  them. They are a rewrite from each store, so `ProfileStore.signIn` reschedules every visible
  profile's on the way back.
- **Remove** is one quiet row on You, drawn only when another account's stores are on the phone
  (`OtherAccountsRow`, `ProfileStore.removeOtherAccounts`), and confirmed. It deletes every store
  of every account but the one shown — signed out, the one shown is `default.store`'s owner —
  with its scoped keys and its waiting shares. Profile stores written before stores were filed by
  account, which no list has claimed, count as another account's: nothing says whose they are.
  Such a store is moved into an account's directory the first time that account's list names it
  (`ProfileStores.adoptLegacy`).
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

- **A second Apple ID's follows can start with the phone's.** Signing in folds the anonymous
  device's follows and empty size ladders into the account (`Accounts.merge`, the server's rule
  for a reinstall). A phone signed out on the first account's `default.store` has re-followed
  that store's brands on its anonymous device, so the second account's empty holder store fills
  with those brands — never the saves, boards or fits — on its first sync. Fixing it is a
  server change (a sign-in that does not merge) or a re-registration before signing in, which
  orphans a device row holding the phone's APNs token.
- A background pass reaches only the signed-in account's profiles; a hidden account's feeds and
  local alerts wait for it to sign in again. Standalone has one implicit profile and no pass.
