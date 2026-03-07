# TFeed

A native iOS app for reading Telegram channels as a unified feed. Log in with your Telegram account, select channels, and read all their posts in a single chronological stream. No messenger UI — just a clean content feed.

## Features

- **Telegram authentication** — phone number, confirmation code, optional 2FA password. Automatic fallback to SMS when Telegram requests Firebase verification (no Firebase SDK required)
- **Channel selection** — pick which Telegram channels to follow
- **Unified chronological feed** — all selected channels merged into one stream
- **Inline media** — photos, videos, GIFs, voice notes rendered directly in the feed
- **Text formatting** — bold, italic, links, inline code, spoilers
- **Wrapped reactions** — emoji reaction chips expand onto multiple rows instead of clipping
- **Exact timestamps** — each post shows both relative time and exact publish time down to seconds
- **Read/unread tracking** — messages are marked as read on scroll, synced back to Telegram via `viewMessages` so your channels show as read in the official app too
- **Unread counter** with scroll-to-bottom action
- **Resume at first unread** — each launch scrolls to the first unread message using Telegram's read state as the source of truth, no local position storage
- **Single channel view** — tap a channel or post button to open that channel around the selected post
- **Channel avatars** — feed cards, channel sheets, and settings use the real Telegram channel photo when available, with an initial-based fallback
- **Bottom refresh for today** — pull past the bottom edge and release to rebuild the feed for the current day across all selected channels, from local midnight to now
- **Bounded upward loading** — older messages are added only during an active upward drag, only when the reader is actually inside the top load buffer, and never more than one small batch per drag
- **No automatic day fallback on first paint** — opening the app or rebuilding today does not silently pull in yesterday or older history until you actually scroll upward for it
- **Pinned current-day floor** — the current-day rebuild keeps a hard lower bound at local midnight and recalculates it after trims/removals, so older dates do not leak back into the visible feed on their own
- **Complete fresh tail on rebuild** — a manual daily rebuild re-fetches the latest per-channel tail so the newest post from a selected channel is not lost from the unified feed
- **Cross-channel older history continuity** — even channels with no visible posts for today still join the older-history stream once you scroll upward into previous periods
- **Chronological older-history merge** — deferred preview posts and freshly fetched older posts are merged into one chronological batch before they enter the feed, so scrolling upward does not jump across weeks just because a quieter channel had an older preview waiting
- **Single-day older-history batches** — each upward pagination step reveals only a small continuous slice from the same calendar day, which avoids jumping from a few hours ago into a much older date before that day is actually exhausted
- **Poll filtering** — Telegram polls are skipped instead of rendering as empty cards
- **Unsupported post filtering** — message types the app can’t render are dropped instead of showing empty cards
- **Live album recovery** — grouped media posts are rebuilt after Telegram edits or deletions so feed cards and channel details stay aligned
- **Edit-safe chronology** — if Telegram edits a message that was already represented in the unified feed, the replacement post stays inside the same history window instead of disappearing from the chronology, and deferred replacements stay deferred
- **Chat-scoped message identity** — message deduplication uses `chatId + messageId`, which prevents posts from different channels with the same Telegram-local message ID from evicting each other
- **Stable viewport** — ordinary scrolling, upward pagination, and manual rebuilds keep the same visible anchor in place instead of snapping to a different day or repeatedly re-arming history loading inside one drag
- **No post-drag viewport jumps** — if an async older-history request finishes after the user stops dragging, the feed does not issue a follow-up programmatic scroll that moves the viewport on its own
- **Live TDLib state sync** — feed and channel screens react to new messages, edits, deletions, channel metadata updates, and read-state updates
- **TDLib callback hardening** — incoming TDLib updates enter the app through a nonisolated callback boundary and then hop back into `TDLibService`, which avoids actor-executor violations on TDLibKit's serial update queue
- **Safe update fan-out** — `UpdateRouter` distributes `AsyncStream` updates without yielding while holding its internal lock, so terminating subscribers don't reenter the router in the middle of delivery
- **Full local reset** — `Clear Local Cache` destroys local TDLib data and selected channels on the device, then returns the app to the login state
- **Full channel discovery** — chat loading walks the whole TDLib main list instead of stopping at the first 100 chats
- **Self-healing channel metadata** — title/photo updates recover through `getChat` when TDLib sends metadata before the local cache is warm
- **Liquid Glass design** — built for iOS 26

## Requirements

- iOS 26+
- Xcode 26+
- Telegram API credentials (`api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org))

## Technologies

- Swift 6
- SwiftUI (iOS 26 / Liquid Glass)
- TDLibKit
- MVVM + `@Observable`
- async/await concurrency
- SwiftData

## Getting Started

1. **Clone the repository**

   ```bash
   git clone https://github.com/Dronnn/telegram-feed.git
   cd telegram-feed
   ```

2. **Add your Telegram API credentials**

   Create the file `TFeed/Core/Constants.swift` with the following content:

   ```swift
   enum Constants {
       static let apiId: Int = YOUR_API_ID
       static let apiHash = "YOUR_API_HASH"
   }
   ```

   Replace `YOUR_API_ID` and `YOUR_API_HASH` with the values from [my.telegram.org](https://my.telegram.org).

3. **Open the project**

   ```bash
   open TFeed.xcodeproj
   ```

4. **Build and run** on a device or simulator (iOS 26+).

## Architecture

The app follows **MVVM** with a service layer:

- **TDLibService** — an actor wrapping TDLib. Handles all Telegram API calls and manages the TDLib client lifecycle.
- **TDLibService** also owns the single `TDLibClientManager`, recreates the client after `authorizationStateClosed`, and keeps a lightweight channel cache updated from TDLib updates.
- **TDLibService** receives TDLibKit updates on the library's serial client queue, decodes them at a nonisolated boundary, and then forwards them back into the actor explicitly.
- **UpdateRouter** — distributes incoming TDLib updates via `AsyncStream` to the rest of the app, without yielding under lock.
- **AppState** — a global `@Observable` object tracking authentication status and shared state.
- **ViewModels** — each screen has a dedicated `@Observable` view model that consumes updates from the router and exposes UI-ready state.
- **Views** — pure SwiftUI views driven entirely by their view models.

## Project Structure

```
TFeed/
├── Core/              # Constants, app entry point, AppState
├── Services/          # TDLibService, UpdateRouter
├── Models/            # Domain models and DTOs
├── ViewModels/        # Observable view models (Auth, Feed, Channel, Settings)
├── Views/             # SwiftUI views and components
├── Storage/           # SwiftData models and persistence
└── Extensions/        # Swift and SwiftUI extensions
```

## License

MIT License

Copyright (c) 2026 Andreas Maier

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
