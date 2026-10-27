# Releasing Dropwall 1.3 (build 4) — Phase 4, AI

A handover for the agent that ships this release. Read `CLAUDE.md` first, then `docs/ai.md` and
`docs/credits.md`. Everything below is in order; a step that depends on the owner says so.

## What 1.3 is

Phase 4 on branch `phase-4`:

- Ask Dropwall in Shop (AI search, free follow-ups, "Show me more" on the web)
- The clothes scan (Saved "+" and Shop's field)
- Ask on a fit (judge and suggest)
- Worded daily picks with an optional morning alert
- More like this on saved items
- **Credits switched on**, with three consumable packs

The version in the project is already `MARKETING_VERSION = 1.3`, `CURRENT_PROJECT_VERSION = 4`.
The texts are drafted in this folder: `WHATS_NEW_1.3.txt`, `REVIEW_NOTES.md` (the block under
*The text to paste*), `PRIVACY_POLICY.md` / `privacy-policy.html`.

Facts you need:

| | |
|---|---|
| Bundle id | `com.kern.functional.streetw`, team `JD6NETLE45` |
| Production server | `https://app.streetw.hottorun.com` (Railway, auto-deploys every push to `main`) |
| Credit packs | `com.kern.functional.streetw.credits.50`, `.credits.150`, `.credits.500` — consumables; the server only credits ids listed in `CreditPacks` (`Server/Sources/StreetwServer/Services/Credits.swift`) |
| Placeholder prices | 0.99 / 2.99 / 8.99 in `streetw.storekit` — the owner decides the real ones |

## Rules for this job

- **Never read, print or commit secrets.** The owner types keys into Railway and App Store Connect
  themselves; you only tell them which variable and what kind of value.
- **Merging to `main` deploys the production server.** Ask the owner before you merge, and say so.
- Don't push, merge, submit or publish anything without the owner's go-ahead for that step.
- Commit messages are short and plain, with no mention of Claude or AI tooling and no
  `Co-Authored-By` line.
- `xcodebuild`, `simctl` and `swift test` need
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on the original machine. Check
  `xcode-select -p` here; if it points at Xcode already, you don't need it.
- The repo must be checked out in a folder named **`streetw`** for the server package to build
  (`CLAUDE.md`, *The repo directory name is load-bearing*). If it isn't, build the server from a
  `git worktree add --detach /tmp/rel/streetw phase-4`.

## 1. Get the branch and check it builds

```bash
git fetch origin && git switch phase-4 && git pull
swift test                                  # expect 725 passing
cd Server && swift test --no-parallel       # expect 397 passing (13 more run with STREETW_TEST_POSTGRES_URL)
```

Then build the app for a simulator (any iOS 18+ device) as in `CLAUDE.md`, *Build and run*.

Optionally run the app against a local server with the fake AI (`AI_FAKE=true`,
`SIWA_TEST_TOKENS=true`, launch flag `-fakeAppleSignIn alice`). The flow has been driven end to
end that way already.

## 2. Railway variables — the owner sets these

On the **server** service in Railway, the owner adds:

| Variable | Value | Why |
|---|---|---|
| `ANTHROPIC_API_KEY` | their Anthropic API key | Turns AI on. Without it `GET /v1/ai` says unavailable and the app draws no AI at all |
| `AI_THREAD_SECRET` | output of `openssl rand -hex 32` | Signs search threads so free follow-ups survive deploys |
| `CREDITS_ALLOW_SANDBOX` | `true` | **Required for App Review and TestFlight.** Both buy packs in the sandbox against the production server, and without this the server refuses those purchases. Every purchase row records its store environment, so testers' credits can be taken back later |

These are optional and have defaults: `AI_MODEL` (`claude-sonnet-5-5`), `AI_MODEL_FAST`
(`claude-haiku-4-5-20251001`), and `AI_BACKGROUND_DAILY_CAP_MICROS` (`1000000`, which is $1 a day
of owner-paid background reading).

**Never set** `AI_FAKE` or `SIWA_TEST_TOKENS` on production. The server refuses both there anyway
and logs it at boot.

Also confirm with the owner that App Store Server Notifications V2 point at
`https://app.streetw.hottorun.com/v1/app-store/notifications`, for **both** Production and
Sandbox (App Store Connect › the app › App Information). That is how refunds reach the server.

## 3. Merge to `main` (deploys the server) — ask first

Open a PR from `phase-4` into `main` (or use the existing one). Merge it **only with the owner's
OK**.

Safe order: the server first, then the app. The new server is fully compatible with 1.2, and the
AI routes stay hidden until the key is set.

Verify the deploy went live:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://app.streetw.hottorun.com/v1/ai   # 401 = new server live, 404 = still the old one
curl -s https://app.streetw.hottorun.com/health                                   # ok
```

The owner can check the deploy log in Railway for `ai: on — Anthropic, claude-sonnet-5-5 for readers, claude-haiku-4-5-20251001 for background work`. If it says off, the key isn't set.

## 4. App Store Connect: the three credit packs — the owner, with you guiding

App Store Connect › the app › Monetization › In-App Purchases › create three **Consumable**
products:

| Product ID (exact) | Reference name | Display name | Description (suggestion) |
|---|---|---|---|
| `com.kern.functional.streetw.credits.50` | Credits 50 | 50 credits | Credits for Dropwall's AI features |
| `com.kern.functional.streetw.credits.150` | Credits 150 | 150 credits | Credits for Dropwall's AI features |
| `com.kern.functional.streetw.credits.500` | Credits 500 | 500 credits | Credits for Dropwall's AI features |

For each pack:

- set a price (the owner chooses);
- add the English localization;
- add a review screenshot of You › Credits showing the packs (take it in TestFlight, step 7);
- add short review notes: "Consumable credits, held on the user's account on our server, spent on the AI features (Ask Dropwall, scan, fit judging). Requires Sign in with Apple."

**First in-app purchases must be submitted together with an app version**, so attach them on the
1.3 version page in step 8.

## 5. Publish the privacy policy — the owner

Upload `AppStore/privacy-policy.html` to the same public URL as before, replacing the 1.2 page.

Before publishing, the owner must confirm one claim in *AI features* against their Anthropic
agreement. It says Anthropic "does not use it to train its models, and deletes it after the limited
period its commercial terms allow". If their terms differ, edit `PRIVACY_POLICY.md` and regenerate
the HTML (there was a small md→html script on the original machine; any faithful conversion is
fine).

## 6. App Privacy answers — the owner

App Store Connect › App Privacy. **Keep everything already declared**: Device ID, User ID, Name,
Product Interaction (incl. Analytics) and Other Data Types, all linked. **Add**:

| Data type | Linked to the user | Purpose | Tracking |
|---|---|---|---|
| Purchase History | **Yes** | App Functionality | No |
| Photos or Videos | No | App Functionality | No |
| Search History | No | App Functionality | No |
| Other User Content | No | App Functionality | No |

These match `streetw/PrivacyInfo.xcprivacy`; the reasons are in the comments there. If App Store
Connect asks about third-party partners, say yes: Anthropic processes these to answer requests.

## 7. Archive, upload and test on TestFlight

1. In Xcode: scheme `streetw`, destination *Any iOS Device*, Product › Archive.
2. Check the Organizer shows **1.3 (4)**.
3. Distribute › App Store Connect › Upload.
4. Export compliance: same answers as earlier builds.
5. Check `NSCameraUsageDescription` is in the archived app's Info.plist (Organizer › Show in Finder › the `.app` › Info.plist).

On a real phone with the TestFlight build, against production with the real model — **nothing so
far has called the real Anthropic API, so this is the first real test**:

- Sign in with Apple, then go to You › Credits. The balance should be 50, with the three packs priced. A pack with no price means the IAP isn't approved or attached yet; that's normal before review.
- Shop: type "black suit for a wedding no wool", tap **Ask Dropwall · 1 credit**. Check you get a reading, a reply line and chips, and the balance goes to 49. Send a reply: it should say no charge.
- **Show me more**: web results that open the shop's page; costs 3.
- Saved "+" › **Scan a garment** with the real camera: check the cutout and the reading, then each of the three choices.
- A fit › **Ask** › Judge, then Suggest.
- Picks in Shop show a reason marked as worded by AI (may take a refresh).
- Buy the 50 pack with a sandbox account. The balance should go up by 50.

The owner then opens `GET https://app.streetw.hottorun.com/admin/costs` with their admin token
(don't handle the token yourself). There should be rows for each action with real costs.

**If an AI action fails with "couldn't ask" or similar**, ask the owner for the Railway log lines
around it. The likeliest causes are an Anthropic 400 on a tool schema (the strict schemas were
never sent to the real API) or a wrong model id. Fix in `Server/Sources/StreetwServer/Services/`
(`AnthropicProvider` and the per-action schemas). Run `cd Server && swift test`, then **build the
Docker image** (`docker build -f Server/Dockerfile .` from a checkout named `streetw`). Linux
catches Sendable issues the Mac doesn't. Then commit, and merge with the owner's OK.

Known, not blockers:

- The background refresh choosing picks took about 28 s in a debug simulator build, against iOS's roughly 30 s budget. In a release build on a device it should be faster; if the morning picks alert never arrives, that's the first suspect.
- Garments you scanned yourself are not yet used by Shop's picks or Discover's pairing.

## 8. Submit 1.3 for review

On the 1.3 version page in App Store Connect:

- **What's New**: paste `AppStore/WHATS_NEW_1.3.txt`.
- **Build**: 1.3 (4).
- **In-App Purchases and Subscriptions**: add all three credit packs.
- **App Review Information › Notes**: paste the block under *The text to paste* in `AppStore/REVIEW_NOTES.md`. Leave **Sign-in required unticked**. The AI needs sign-in, but the reviewer's own Apple ID works and gets 50 free credits.
- Screenshots: the 1.2 set in `AppStore/screenshots/` is still accurate. A new shot of Ask Dropwall is optional.
- Submit, after a final yes from the owner.

## 9. After approval

- Release (manually or automatically, whichever the owner chose).
- Keep `CREDITS_ALLOW_SANDBOX=true` while TestFlight testers and future reviews buy packs.
- After a few weeks of real use, set the credit prices from `GET /admin/costs` (price from the p90, not the mean; `docs/credits.md`). The values are in `CreditPolicy.credits(for:)` and `CreditPolicy.monthlyAllowance`.
