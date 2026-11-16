# SongSort — Plan

A personal iPhone app that works like Tinder for your Spotify library. It shows one song at a time, plays it from about the middle in the Spotify app, and you swipe right to keep or left to reject.

**Status:** Phase 1 — **complete** (built, 102 tests passing, Simulator walkthrough done; the 📱 items wait for your iPhone checklist in the README) · Phase 2 — not started · Phase 3 — waiting for your Discover decision (§4)

---

## 1. Scope

| In scope | Out of scope |
|---|---|
| One user (you), iPhone in portrait, iOS 17+ | Android, iPad layouts, App Store release, more users |
| Sort Liked Songs, sort a playlist you can edit, Discover | Statistics, charts, sharing, social features |
| Adding and removing tracks in Liked Songs and playlists, creating the "Rejected – …" playlists | Any other playlist editing (rename, reorder, cover art, delete) |

---

## 2. What Spotify allows a newly registered app (checked 16 Nov 2026)

Sources: [Nov 2024 Web API changes](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api) · [Feb 2026 developer access update](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security) · [Feb 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026) and [migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) · [Mar](https://developer.spotify.com/documentation/web-api/references/changes/march-2026), [May](https://developer.spotify.com/documentation/web-api/references/changes/may-2026) and [Jul 2026](https://developer.spotify.com/documentation/web-api/references/changes/july-2026) changelogs · [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) · [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) · [iOS SDK guide](https://developer.spotify.com/documentation/ios/getting-started) · [iOS SDK changelog](https://github.com/spotify/ios-sdk/blob/master/CHANGELOG.md)

### 2.1 Account and app limits
- A new app starts in **Development Mode**, and individuals can't get out of it. Extended Quota is now only for registered businesses with 250k+ monthly users.
- Development Mode needs the **app owner to have Premium** (you do). Up to **5 allowlisted users**, which is plenty for one person.
- A **per-developer-account quota** applies on top of the normal 30-second rate limit. Spotify doesn't publish the numbers. Going over returns `429` with `"reason": "QUOTA_EXCEEDED"`. So the app has to be frugal: batch writes, never poll, back off on 429.

### 2.2 Not available to a new app
| Gone | Since | Impact |
|---|---|---|
| Recommendations, Related Artists, Audio Features/Analysis, available genre seeds | Nov 2024 | No "songs like this" engine. Affects Discover only |
| 30-second preview clips | Nov 2024 | Playback must go through the Spotify app (that's what you want anyway) |
| Spotify-owned editorial and algorithmic playlists, featured and category playlists | Nov 2024 | Can't mine Spotify's genre playlists for Discover |
| Batch fetches (`GET /tracks?ids=`, `/artists?ids=`, …) | Feb 2026 | One request per item; avoid needing them |
| Artist top tracks, new releases, browse categories, `/markets` | Feb 2026 | Affects Discover |
| Other users' profiles and playlists; **contents of playlists you don't own or collaborate on** | Feb 2026 | Can't read public genre playlists for Discover |
| Type-specific save/remove endpoints (`PUT/DELETE /me/tracks`, …) | Feb 2026 | Replaced by `PUT/DELETE /me/library` (URIs, **max 40 per call**) |
| `/playlists/{id}/tracks` | Feb 2026 | Renamed to `/playlists/{id}/items`; JSON field `track` → `item` |
| `popularity` (tracks, albums, artists), `linked_from`, `available_markets`, `label`; user `country`/`email`/`product` | Feb 2026 | Can't rank Discover by popularity. Can't check Premium from the API |
| Search returns more than 10 results per call | Feb 2026 | `limit` max 10 (default 5), `offset` max 1000 |
| Artist `genres` | Deprecated (still documented) | May be empty or stale. Can't rely on it alone |

### 2.3 What we use
| Need | Endpoint / SDK | Notes |
|---|---|---|
| Login | Authorization Code + **PKCE**, `ASWebAuthenticationSession` | No client secret in the app. Redirect `songsort://callback` (custom schemes are what Spotify's own iOS guide uses; `http://localhost` is banned). Refresh token in the Keychain |
| Who am I | `GET /me` | `id`, `display_name` |
| Liked Songs | `GET /me/tracks` (50 per page) | Newest first |
| Remove from / re-add to Liked Songs | `DELETE` / `PUT /me/library?uris=` (≤ 40) | **No way to set "date added" any more**, see Undo |
| Is a playlist still in my library? | `GET /me/library/contains?uris=spotify:playlist:…` | Detects a deleted "Rejected" playlist |
| My playlists | `GET /me/playlists` (50 per page) | `owner.id`, `collaborative`, `items.total` |
| Create the Rejected playlist | `POST /me/playlists` | Private, with a description |
| Playlist contents / add / remove | `GET` (50) / `POST` (100) / `DELETE` (100) `/playlists/{id}/items` | Only playlists you own or collaborate on |
| Taste signals (Phase 3) | `GET /me/top/{artists,tracks}`, `/me/player/recently-played`, `/me/following`, Liked Songs | All still available |
| Catalog (Phase 3) | `GET /search` with `genre:`/`artist:`/`year:` filters (10 per call), `/artists/{id}`, `/artists/{id}/albums`, `/albums/{id}/tracks` | Single-item endpoints only |
| **Playback** | **Spotify iOS SDK 5.0.1, App Remote** (Swift Package `github.com/spotify/ios-sdk`) | Controls the Spotify app on the phone: play, seek, pause, resume, player-state events. Premium = on-demand playback. **No "play at position"**, so we play and then seek straight away. The Spotify app must be installed. It can't run in the Simulator. Web API player endpoints (`PUT /me/player/play` with `position_ms`) stay available as a fallback |

---

## 3. How each feature works within those limits

### 3.1 Login and staying logged in
- "Log in with Spotify" opens Spotify's consent page in a secure in-app browser (it shares Safari's Spotify session, so you're often already signed in). The app exchanges the code using PKCE and stores the access and refresh tokens in the Keychain.
- Each request uses a valid token, refreshed shortly before expiry. If a request gets `401`, the app refreshes once and retries. If the refresh token is rejected (`invalid_grant`), the app shows **"Your Spotify login expired — Log in again"**. Swipes and pending changes are kept.
- Scopes: `user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-private playlist-modify-public app-remote-control user-read-playback-state user-modify-playback-state user-top-read user-read-recently-played`. All scopes for all three phases are requested now, so you don't have to log in again later.
- Configuration (Client ID, bundle ID, Apple team) lives in `Config/Local.xcconfig`, which isn't committed. If the Client ID is missing, the login screen says so.

### 3.2 The swipe card and playback
- The card shows cover art (unmodified, as Spotify's policy requires), title, all artists, album, release year (from `release_date`) and length (m:ss).
- When a card becomes current, the app sends App Remote `play(uri)` and then immediately `seek(duration / 2)`. The next two cards are already rendered behind the current one, and their cover art is prefetched, so there's never a loading screen between cards. Spotify writes happen in the background (§3.4).
- Controls: play/pause, **↺ from the middle**, **+15 s**, and a draggable progress bar. Position comes from App Remote player-state events and is interpolated between them.
- Connection: when the sorter opens, the app connects silently if Spotify is already running. If it isn't, the card shows **"▶ Start playback"**. Tapping it calls `authorizeAndPlayURI`, which opens Spotify for a moment and returns automatically. After that, every new card plays on its own. Leaving the sorter pauses playback.
- If a song doesn't start within a few seconds (unavailable in your country, Spotify offline, another device took over), the card says so. You can still keep or reject it.

### 3.3 Sorting a source (Liked Songs in Phase 1, playlists in Phase 2)
- **Queue** = source tracks, in the chosen order, minus songs already sorted in this run of that source. Duplicates, local files and podcast episodes are skipped. Orders: *Newest first* (Spotify's order, the default), *Oldest first*, or *Shuffle*. Shuffle uses a stored seed, so it's stable across launches.
- **Ledger:** every decision is stored on the phone straight away (song, keep/reject, time). Songs in the ledger never come back. Resuming is automatic: reopening the source rebuilds the queue and continues at the first unsorted song.
- **Counter** `n / total`: total = sorted songs + songs still in the queue. n = the current song's number. Rejected songs leave the source but still count, so the total stays stable during a run.
- **Start over** (with confirmation) clears that source's ledger. Songs already moved to "Rejected – …" stay there.
- **Keep** changes nothing in Spotify.
- **Reject** (Liked Songs):
  1. Find the Rejected playlist: first the stored ID, if `/me/library/contains` shows you still have it; then an owned playlist with the exact name; otherwise create a private one. This happens on the first reject, so sorting without rejecting creates nothing.
  2. Add the song to it, unless it's already there (the app checks the playlist's contents), so no duplicates.
  3. Only then remove it from Liked Songs (`DELETE /me/library`). If step 2 fails, step 3 never runs, so a song can't be lost.
- **Naming:** `Rejected – <source>` with an en dash, e.g. **"Rejected – Liked Songs"** or **"Rejected – Road Trip"**. Names are trimmed and capped at 100 characters. The mapping from source to playlist ID is stored, so renaming a source doesn't create a second Rejected playlist.

### 3.4 Sync engine (how Spotify changes are applied)
- Each reject becomes small write operations in a persistent **outbox**. Ledger and outbox are saved together in one file, so a crash can't leave a "rejected" mark without its pending change.
- Writes are held for **10 seconds**, then sent in batches. Consecutive rejects become one "add" call (≤ 100) and one "remove" call (≤ 40). Writes for the same song always keep their order. The outbox is sent immediately when you leave the sorter or the app goes to the background.
- **Offline / 5xx / `429`:** retry with backoff (honours `Retry-After`). `QUOTA_EXCEEDED` gets a long backoff and a message. **Login expired:** paused until you log in again. **Other errors** (403/404/400): the write is marked failed, shown with **Retry**, and blocks later writes for that song.
- The Home screen and the sorter show *"3 changes waiting to sync — offline"*, *"All changes saved to Spotify"*, and so on. Pending writes survive quitting the app.

### 3.5 Undo
- Undo pops the most recent decision for the source (up to 100 back, including from earlier sessions). The card returns and plays again.
- **Keep:** undo just forgets the decision.
- **Reject:** writes that haven't been sent yet are cancelled, so Spotify is never touched. Writes already sent are reversed: the song is re-added to Liked Songs, and removed from the Rejected playlist only if the app added it there.
- ⚠️ **Limitation:** Spotify's current API can't set a song's "date added". If you undo a reject *after* it was sent (after about 10 s), the song comes back at the top of Liked Songs with today's date. An undo within the 10-second hold keeps the original position. The old `PUT /me/tracks` with timestamps isn't available to new apps.

### 3.6 Sort a playlist (Phase 2)
- The picker lists playlists you can edit (owned by you, or collaborative), excluding SongSort's own "Rejected – …" playlists.
- Reject = add to "Rejected – <playlist name>", then remove from the playlist. Spotify removes **all copies** of that song from the playlist.
- Undo = remove from Rejected (if the app added it), then re-insert the song at its original position.
- Changes to the playlist are detected with `snapshot_id`.

### 3.7 Errors and messages (all phases)
| Situation | What you see |
|---|---|
| Spotify app not installed | "Spotify isn't installed" + App Store button. Sorting still works, without sound |
| Spotify not running / App Remote disconnected | "▶ Start playback" (opens Spotify for a moment) |
| Song didn't start | "Spotify didn't start this song" + Retry |
| Offline | Banner "You're offline — swipes are saved and will sync later". Loading a source offline shows an error with Retry |
| Login expired | Full-width banner + "Log in again". Nothing is lost |
| Rate limited / quota | "Spotify asked us to slow down — retrying in 30 s" / "Spotify's daily limit for your developer account was reached" |
| Spotify write failed | "1 change couldn't be saved to Spotify: <reason>" + Retry |

### 3.8 One-handed use
Everything you use while sorting sits in the bottom half: progress bar, playback buttons, then **Reject · Undo · Keep** as large buttons. You can swipe anywhere on the card, and haptics confirm each decision. The top bar only holds Close, the counter and a menu. The app is portrait only.

---

## 4. Discover — DECISION NEEDED before Phase 3

**The honest picture:** Discover was built on Recommendations, Related Artists, audio features, genre seeds and Spotify's genre playlists. A new app can use none of them. It also can't see popularity or read public playlists, and search returns 10 results per call. What's left: your top artists and tracks, recently played, followed artists, Liked Songs, search with a `genre:` filter, and an artist's albums and tracks. Artist genres still exist but are deprecated and may be empty. **No option will match the old "songs like this" quality.** These are the realistic ones:

| | **A. Genre search, filtered by your taste** | **B. Unheard songs from artists you already like** | **C. Mix of A + B** *(recommended)* | **D. Drop or postpone Discover** |
|---|---|---|---|---|
| How | For each genre: `search?type=track&q=genre:"<genre>"`, paged 10 at a time (also by year range for variety). Drop songs you've saved or rejected. Score by overlap with your top artists' genres, artists you already like, and your usual release years. Discard low scores | Your top, followed and liked artists whose genres match your picks → their albums and singles → tracks you haven't saved. Ordered by how much you play the artist, newest releases first, at most one song per album per round | B's songs first, then A's new artists, mixed about 60/40. Each card is labelled "From an artist you like" or "New in <genre>" | Ship Phases 1–2 only |
| New artists | ✅ yes | ❌ no | ✅ some | — |
| Taste match | ⚠️ coarse; leans popular | ✅ strong | ✅/⚠️ | — |
| Depends on deprecated artist genres | partly (scoring) | yes (matching artists to your picks) | partly | — |
| API cost | High (10 results per call) | Medium | High | — |
| "Ran out of good matches" | When pages stop producing songs above the score bar | When matching artists are exhausted | When both pools are exhausted | — |

Notes for every option:
- The genre picker is built from your top artists' genres (if Spotify still returns them) plus a built-in list of common Spotify genre names. No API returns the official genre list any more.
- Keep adds the song to Liked Songs, or to a playlist chosen in Discover settings. Reject is stored so the song never comes back.
- Phase 3 starts with a short check on your account: how many of your top artists still have genres. If most are empty, B can't match genres, and A/C fall back to search only.

**Please choose A, B, C or D** (or ask for a variation).

---

## 5. Architecture
- **`SongSortCore`** (local Swift package; all logic, no UI, runs its tests on the Mac with `swift test`): models, Spotify Web API client (with a stub transport for tests), PKCE and token refresh, library loader, queue builder, ledger, sort session, outbox and sync engine, Rejected-playlist resolver, an in-memory Spotify backend (used by tests and the demo mode), and JSON persistence.
- **`SongSort`** (SwiftUI app, iOS 17+): login (`ASWebAuthenticationSession`), Keychain token store, App Remote playback, network monitor, image prefetching, screens.
- **Demo mode** (Debug builds only, launch argument `-SongSortDemo YES`): fake library and simulated player, so every screen can be walked through in the Simulator, where neither Spotify login (needs your password) nor the Spotify app is available.

---

## 6. Acceptance criteria

Legend: `[x]` = verified, `[ ]` = not yet. P1/P2/P3 = phase. "📱" = can only be verified on your iPhone with Spotify (step numbers refer to the README checklist). "T" = automated test, "S" = seen in the Simulator.

### Login and setup
- [ ] P1 First launch shows "Log in with Spotify". After approving, Home shows your Spotify name 📱 *(login screen S; approval needs your account, checklist 1)*
- [ ] P1 Relaunching the app (even after a reboot) goes straight to Home, with no second login 📱 *(Keychain storage and refresh T; checklist 2)*
- [x] P1 Expired or revoked login shows "Your Spotify login expired" with "Log in again". Pending changes are kept *(T + S)*
- [x] P1 Missing Client ID shows a clear setup message instead of a broken login *(S)*
- [ ] P1 Settings → Log out returns to the login screen and deletes the tokens (sort progress is kept) 📱 *(token deletion T; the button only exists when logged in for real, checklist 13)*
- [x] P1 README covers dashboard registration (redirect URI, bundle ID, APIs, user allowlist), local config, and running on the iPhone

### Swipe card
- [x] P1 Card shows cover art, title, artist(s), album, release year, track length *(S; artwork and year decoding T)*
- [ ] P1 The song starts on its own at about the middle (±5 s) when the card appears 📱 *(S with the simulated player; real App Remote, checklist 4)*
- [x] P1 Swipe right or tap Keep keeps. Swipe left or tap Reject rejects. A short drag snaps back *(S)*
- [ ] P1 The next card appears instantly (no spinner) and its song starts within about 1 s on a normal connection 📱 *(no spinner S; timing, checklist 5)*
- [x] P1 Undo brings back the last card and reverses its Spotify changes; repeated undo goes further back *(T + S)*
- [ ] P1 Pause/resume, replay from the middle, +15 s and the draggable progress bar work 📱 *(all S with the simulated player; checklist 9)*
- [x] P1 Counter shows "n / total", e.g. "37 / 412" *(T + S)*

### Sort Liked Songs
- [x] P1 Reject adds the song to "Rejected – Liked Songs" (created if missing, reused if present), then removes it from Liked Songs. Nothing is deleted outright *(T against the Feb 2026 endpoint shapes; confirm in Spotify, checklist 6)*
- [x] P1 A song already in "Rejected – Liked Songs" isn't added twice. It's still removed from Liked Songs, and undo leaves it in Rejected *(T)*
- [x] P1 Keep changes nothing in Spotify *(T)*
- [x] P1 Sorted songs don't come back in later sessions. Quitting halfway and reopening resumes at the next unsorted song, with the same counter *(T + S)*
- [x] P1 "Start over" re-sorts the source from scratch (after confirmation) *(T + S)*
- [x] P1 An empty library shows "Nothing to sort" (no playlist created). Sorting everything shows a "Done" screen *(T + S)*
- [x] P1 Pending Spotify changes survive quitting the app and are sent on the next launch. Home shows how many are waiting *(T + S)*

### Sort a playlist
- [ ] P2 The picker lists only playlists you can edit, without SongSort's Rejected playlists
- [ ] P2 Reject moves the song to "Rejected – <playlist>"; undo puts it back at its old position
- [ ] P2 Same resume, undo, start-over and counter behaviour as Liked Songs

### Discover (after your §4 decision)
- [ ] P3 Pick one or more genres
- [ ] P3 Suggestions are songs not in Liked Songs that fit the genres and your taste (per the chosen option)
- [ ] P3 Keep adds to Liked Songs or to the playlist set in Discover settings. A rejected song never shows again
- [ ] P3 A genre that runs out shows "No more good matches for <genre>" instead of weaker songs

### General
- [x] P1 Clear messages for: Spotify not installed, Spotify not running/not playing, login expired, offline, rate limit/quota, failed write. No silent failures *(all S except "Spotify didn't start this song", which needs the real Spotify app)*
- [x] P1 Usable one-handed: all sorting controls in the bottom half, portrait, every current iPhone size *(S on iPhone 17 at 6.3″ and iPhone SE at 4.7″)*

### Engineering
- [x] P1 Automated tests: queue order, skipping sorted songs, resume, undo, Rejected playlist naming and creation (including an empty library and a song already in Rejected), sync ordering and batching, API request shapes, PKCE *(102 tests)*
- [x] P1 All tests pass. The app builds with no warnings from our code *(macOS `swift test` and iOS Simulator; Debug Simulator and Release device builds without warnings)*

---

## 7. Build phases

**Phase 1 — Login + Sort Liked Songs** ✅ *complete, waiting for your iPhone check*
1. Project scaffold: Xcode project, `SongSortCore` package, config files, Spotify iOS SDK via SPM
2. Core: models, API client, PKCE and tokens, library loader, queue, ledger, session, outbox and sync engine, Rejected resolver, persistence, in-memory backend
3. App: login, Home, sorter (card stack, gestures, playback controls, undo, counter, banners), Settings, App Remote player, demo mode
4. Tests; Simulator walkthrough of every screen that doesn't need live playback; README with setup and an iPhone checklist
5. Re-check §6 P1 criteria and mark them

**Phase 2 — Sort a playlist:** editable-playlist picker, playlist source (snapshot handling, all-copies removal, re-insert on undo), per-playlist Rejected playlists, tests.

**Phase 3 — Discover:** account check (genre coverage); the chosen option; genre picker; Discover settings (keep target); "out of good matches" logic; tests.

**Phase 4 — Hardening** (if needed after your phone testing): library caching for very large libraries, playback tweaks (e.g. switch to Web API `position_ms` if the play-then-seek blip is audible), polish.

---

## 8. Verification
- **Automated** (`swift test` in `SongSortCore`): everything in §6 "Engineering".
- **Simulator:** build the app, run it in normal mode (login screen and config states) and demo mode (Home, sorter, swipes, undo, counter, resume after relaunch, start over, empty library, done screen, error banners).
- **iPhone checklist** (README): login, auto-play near the middle, keep/reject, the "Rejected – Liked Songs" playlist in Spotify, undo, quit and resume, offline behaviour.

### Phase 1 results (16 Nov 2026)
- `swift test` in `SongSortCore`: **102 tests in 10 suites pass**. The same suite passes on the iOS 27.2 Simulator (`xcodebuild test -scheme SongSortCore`).
- Builds: Debug for the Simulator and Release for a generic iOS device (unsigned), **no compiler warnings**. The Spotify iOS SDK 5.0.1 resolved via SPM and links for both.
- Simulator walkthrough (iPhone 17 / iOS 27.2, dark mode; iPhone SE / iOS 18, light mode):
  - Login screen with missing Client ID
  - Home: not started, in progress ("9 of 36 sorted · 4 rejected", "Resume · 10 / 36"), and after Start over
  - Sorter: card, auto-play from the middle (simulated), swipe and tap keep/reject, short-drag snap-back, undo (including an already-synced reject), order menu, scrubbing, Middle, +15 s, pause
  - Resume after quitting; Start over with confirmation; Settings; "All 3 songs sorted"; "Nothing to sort"
  - Error messages: Spotify not running, Spotify not installed, offline (banner and failed load), login expired, quota reached, failed write with Retry
- Notes:
  - `xcodebuild test` on the app scheme can't see the local package's tests, so the tests run with `swift test`, or by opening `SongSortCore/Package.swift` in Xcode.
  - During the walkthrough, one tap was followed by five extra decisions within four seconds. I couldn't reproduce it in isolated single-tap and single-swipe tests (each made exactly one decision), and nothing fires while idle. Possibly input from the live Simulator panel. Worth watching for on the phone.

## 9. Risks
| Risk | Mitigation |
|---|---|
| You might hear a split second of the song's start before the seek lands | Seek fires right after play is accepted. If it's audible, Phase 4 switches to Web API `position_ms` for the start |
| App Remote drops when Spotify is suspended in the background | Reconnect on foreground. One tap on "Start playback" if Spotify was killed |
| Undisclosed Development Mode quota | Batching, no polling, `QUOTA_EXCEEDED` handling. Very large libraries (5k+ songs) cost 100+ page requests per load; caching in Phase 4 if needed |
| Undo can't restore "date added" after a reject is sent | 10-second hold before sending; documented above |
| Spotify changes the API again | All calls in one client with request-shape tests, so changes are easy to find and fix |
