# Releasing

The repeatable part. `REVIEW_NOTES.md` is what App Review is told and `PRIVACY_POLICY.md` is what
users are told; this is the order of operations that gets a build to both of them.

Written after the 1.0 submission. Everything here was verified by doing it — where a step exists
because something failed silently, the entry says so, because that is the only part worth keeping.

---

## One-time setup

Done once for the account, not per release. Skip to *Every release* once these are true.

- [ ] **Apple Developer Program** active for team `JD6NETLE45` (KERN AG).
- [x] **App IDs registered** — `com.kern.functional.streetw` with Push Notifications and App
      Groups, `com.kern.functional.streetw.ShareExtension` with App Groups, and the group
      `group.com.kern.functional.streetw` itself. Background modes need no portal capability;
      they live in `streetw-Info.plist`.

      **An App ID existing is not an App ID configured, and the difference is silent.** Xcode
      creates identifiers by itself on a first build, carrying only the capabilities it knew
      about at that moment — so a row named `com.kern.functional.streetw` sits on the portal
      looking complete with Push switched off. The archive can still succeed. Push then simply
      never works, which is the failure this repository has already had once.

      So check the **profiles Apple issued**, not the list of identifiers. A profile can only
      carry an entitlement the App ID is actually configured for — the provisioning service
      strips the rest — which makes `aps-environment` appearing below positive proof that Push
      is enabled, in a way that reading a checkbox is not:

      ```bash
      cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
      for f in *.mobileprovision; do
        p=$(security cms -D -i "$f" 2>/dev/null)
        id=$(echo "$p" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null)
        case "$id" in *com.kern.functional.streetw*) ;; *) continue ;; esac
        echo "$id"
        echo "   type      : $(echo "$p" | plutil -extract Entitlements.get-task-allow raw - 2>/dev/null \
                                 | sed 's/true/development/;s/false/DISTRIBUTION/')"
        echo "   aps-env   : $(echo "$p" | plutil -extract Entitlements.aps-environment raw - 2>/dev/null || echo none)"
        echo "   app group : $(echo "$p" | plutil -extract Entitlements.com\\.apple\\.security\\.application-groups.0 raw - 2>/dev/null || echo none)"
        echo "   expires   : $(echo "$p" | plutil -extract ExpirationDate raw - 2>/dev/null)"
      done
      ```

      Note the path — Xcode moved this cache out of `~/Library/MobileDevice/Provisioning
      Profiles/`, which still exists and is usually empty, and an empty directory there reads
      exactly like "nothing has ever been provisioned".

      What it should print: `aps-environment` on the app and none on the extension, the group on
      both, and — until the first archive — `development` for the type. Distribution profiles
      appear only once Xcode has been asked to make one.
- [ ] **Distribution certificate exists.** Easiest via Xcode: *Signing & Capabilities*,
      *Automatically manage signing* on all three targets, then archive — Xcode requests the
      certificate and profiles as part of that.
- [ ] **`APNS_TOPIC` is exactly the bundle ID** in the server's environment. `apnsConfigured: true`
      only says the four variables are *set*, not that the topic is right — and a wrong topic is
      not a startup error, it is every push rejected by Apple long after the deploy reads healthy.
- [x] **The privacy policy is hosted** — <https://www.hottorun.com/dropwall/privacy>. That URL is
      in App Store Connect and must not change. It is served out of `public/dropwall/privacy/` in
      the hottorun.com site repository (`Hottorun/MyBlog`), which deploys from GitHub; the source
      of truth is `AppStore/privacy-policy.html` here, so **edit here first and copy across** or
      the two drift and the published one wins.

      It must keep agreeing with `streetw/PrivacyInfo.xcprivacy` and with the App Privacy answers
      in App Store Connect — a contradiction between the three is its own review problem, and the
      kind reviewers check. Bump the date at the top whenever the text changes.
- [x] **The API is on a domain we control** — `app.streetw.hottorun.com`. The address ships in the
      binary and there is no UI to change it, so the hostname has to be one that cannot be taken
      away.

      **It lives in two literals, on opposite sides of the app/server line.**
      `ServerSettings.defaultBaseURLString` is what the app talks to;
      `UCPAgent.defaultBase` is the profile URL merchants fetch before they will answer a
      catalogue query. Only the second has to resolve *from a merchant's network*, and a stale
      value there does not fail visibly — it fails as a 422 on every catalogue call with nothing
      naming the cause. Change both, and note `PUBLIC_BASE_URL` in the server environment
      overrides the second at runtime.

      **Changing the constant does not migrate anyone on its own.** `ServerSettings.init` prefers
      a stored `serverBaseURL` over the default — correct for a value somebody chose, wrong for
      one the app wrote itself, and since the settings field is gone every stored value is the
      latter. `legacyBaseURLStrings` is the list of hosts we have shipped pointing at; an install
      holding one adopts the current default instead. **Add the outgoing host to that set** on any
      future move, and leave the old one resolving until the installed base has turned over.

---

## Every release

### 1. The tree is green and says what it is

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                                    # expect 394 passing
xcodebuild -project streetw.xcodeproj -scheme streetw -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/streetw-rel CODE_SIGNING_ALLOWED=NO build
```

**Run the tests on a quiet machine.** `honoursCrawlDelay` measures `0.4s` minus whatever
scheduling delay falls between the first request returning and the second reaching its timer —
`PoliteFetcher` reserves a host's slot *before* it sleeps. Alongside an Xcode build that delay
reaches 0.13s and the assertion wants ≥ 0.3s. It is a tight tolerance, not a regression.

The one warning a clean Release build prints is `appintentsmetadataprocessor … No
AppIntents.framework dependency found`. That is Apple's, and expected.

- [ ] `REVIEW_NOTES.md` still describes the app that exists. It makes factual claims the code
      enforces — which endpoints are read, that robots.txt is obeyed, that the UCP integration
      declares no checkout capability, that Instagram is never fetched. If one stopped being true,
      the note is now a false statement to App Review.
- [ ] `CURRENT_PROJECT_VERSION` bumped. It must be unique per binary uploaded, even when
      `MARKETING_VERSION` does not move.

### 2. Verify the built bundle, never the build setting

Xcode silently ignores some Info.plist keys as build settings, so the bundle is the only authority:

```bash
APP=/tmp/streetw-rel/Build/Products/Release-iphonesimulator/streetw.app
ls "$APP/PrivacyInfo.xcprivacy"      # ITMS-91053 at intake if this is missing
plutil -p "$APP/Info.plist" | grep -E 'ITSApp|BGTask|UIBackgroundModes|MinimumOSVersion'
```

Expect `ITSAppUsesNonExemptEncryption => false`, both background modes, the
`functional.streetw.refresh` task identifier, and `MinimumOSVersion => 18.0`.

### 3. Run it on the floor of the deployment target, not just the ceiling

The target is 18.0 and there is not one `#available` in the project, so the compiler cannot catch
a behavioural difference — only running can. Both ends, every release:

```bash
xcrun simctl list devices available | grep -E '^--|iPhone'
```

**Boot one simulator at a time.** Two booted at once wedges `simctl bootstatus` indefinitely;
`xcrun simctl shutdown all` clears it.

### 4. Screenshots

`AppStore/screenshots/` is scripted rather than captured by hand, for the same reason the app icon
is code: a set re-shot by hand drifts from the app the first time a screen changes. The launch
flags make it possible with no UI automation at all:

```
-startTab feed|discover|saved|style    open straight to a tab
-didOfferStarterPack YES               skip onboarding deterministically
-seedBrands / -seedSizes / -seedSaves  populate the store
```

Server mode is what you want even though `-seedBrands` polls from the phone: `/v1/discover`
returns cards for a device with no follows at all, and standalone mode has no equivalent — so the
Discover tab is empty without a server. Set a marketing status bar first:

```bash
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --wifiMode active --wifiBars 3
```

`-seedSizes` only takes effect on the **next** launch, so seed once, terminate, then capture.

- [ ] At least one 6.9" set (iPhone 17 Pro Max, 1320×2868). No iPad set is needed —
      `TARGETED_DEVICE_FAMILY` is 1.

### 5. Archive, upload, and then actually test push

Xcode: *Any iOS Device (arm64)* → *Product → Archive* → *Distribute App → App Store Connect*.

**Push is the one thing no simulator exercises**, and this pipeline has reported healthy end to end
while producing no notifications at all — that is what `aps-environment` being absent did, and
every layer read green throughout. A release build reports its APNs environment as `production` and
the entitlement is rewritten to match at export, so TestFlight is the first time that half of the
pipe runs.

- [ ] On a real device: grant permission, then check *Settings → Alerts* in the app. It reports the
      three failure modes separately — no key on the server, no token from this device,
      unreachable. None of them should be showing.
- [ ] `POST /admin/push-test`. It bypasses events, follows, freshness and size targeting, reports
      per device rather than as a count, and writes nothing, so it is safe during a drop.
- [ ] Then a real one: follow a brand that is dropping, and wait for the poller.
- [ ] Walk first run once — onboarding, starter pack, and the share extension from Safari.
- [ ] **Time the first launch.** Shooting the 1.0 screenshots, a debug build on the simulator with
      three seeded brands took ~90s from launch to first paint, showing a blank paper ground the
      whole way with no spinner. That is very likely a simulator artefact — a release build on real
      hardware is a different machine — but it is unmeasured on a device, and if any of it survives
      there, a new user's first screen is blank for long enough to give up on.

### 6. Submit

- [ ] Review notes pasted from `REVIEW_NOTES.md`. Leave *Sign-in required* unchecked; there is no
      account.
- [ ] App Privacy answers match `PrivacyInfo.xcprivacy`: no tracking, and three types — Device ID,
      Product Interaction, Other Data — all linked, none tracking, all App Functionality.
- [ ] Age rating 4+. Answer **no** to unrestricted web access: every outbound link goes through
      `openURL` to Safari and there is no embedded browser in the app.

If it comes back, answer the guideline cited in Resolution Center rather than re-sending the whole
note. The likeliest question is about brand names, logos and product photographs, which the review
notes already address.
