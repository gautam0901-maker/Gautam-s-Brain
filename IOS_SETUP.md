# Glint — iOS launch checklist

Everything in the **code** is done. These are the steps only **you** can do
(Apple Developer portal + Firebase console), because they involve your
accounts and keys. Android is unaffected and keeps working.

After finishing these, commit + rebuild via Codemagic → TestFlight.

---

## 1. Firebase iOS app  ← do this first (fixes Google sign-in + Firestore + cloud sync)

The Settings sign-in failing on iPhone is because there's no iOS Firebase config.

1. Firebase console → your project (`focus-c6659`) → **Add app → iOS**.
2. Bundle ID: use a real one and **remember it** — e.g. `com.gautam.glint`.
   It must match the bundle ID you set in step 6.
3. Download **`GoogleService-Info.plist`** → drop it into `ios/Runner/`.
4. Open that file, find **`REVERSED_CLIENT_ID`** (looks like
   `com.googleusercontent.apps.1234-abcd`).
5. In `ios/Runner/Info.plist`, replace `REVERSED_CLIENT_ID_GOES_HERE` with it.
   (Or paste me the value and I'll set it.)

## 2. Enable Auth providers (Firebase console → Authentication → Sign-in method)

Turn ON the ones you want:
- **Email/Password** ✅ (for email login)
- **Google** ✅
- **Apple** ✅ (required on iOS — see step 3)
- **Phone** ✅ (also needs APNs, step 5)

## 3. Sign in with Apple (Apple Developer portal)

1. **Certificates, Identifiers & Profiles → Identifiers →** your App ID →
   check **Sign in with Apple** → Save.
2. In Firebase → Authentication → **Apple** provider → enable.
3. The app already has `ios/Runner/Runner.entitlements` with the Apple
   capability. In Xcode/Codemagic the **Sign in with Apple** + **Push
   Notifications** capabilities must be added to the Runner target so that
   entitlements file is linked. (Codemagic: enable in the code-signing step,
   or add via Xcode if you get Mac access once.)

## 4. App icon / name

Already generated — the Glint logo + "Glint" name are committed. Just rebuild.

## 5. APNs — only needed for Phone login (and future push)

Local daily-nudge notifications work WITHOUT this. But **phone OTP login on
iOS** uses silent APNs push, so if you want phone login:
1. Apple Developer → **Keys** → create an **APNs Auth Key** (.p8). Note the
   Key ID + your Team ID.
2. Firebase → Project settings → **Cloud Messaging** → upload the .p8.

## 6. Bundle ID

Set the iOS bundle ID to the same value as step 1 (`com.gautam.glint`) in
your Codemagic build config / Xcode project. It currently uses the Xcode
variable, which must resolve to your real ID.

## 7. Rebuild

Commit everything, push, and let Codemagic build → TestFlight.

---

## What now works on iOS once the above is done
- ✅ Google / Apple / Email / Phone sign-in (new Login screen)
- ✅ "Understanding You" onboarding after login
- ✅ Glint logo + name (no more Flutter logo)
- ✅ Portrait lock on iPhone, rotation on iPad
- ✅ Live Listen (TTS) — fixed audio session
- ✅ Daily notifications — fixed iOS init (needs the in-app permission prompt)
- ✅ Firestore, cloud sync, highlights, comments (after step 1)
