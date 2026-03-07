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
- **Bottom refresh for today** — pull past the bottom edge and release to rebuild the feed for the current day across all selected channels
- **Bounded upward loading** — when scrolling upward, older messages are added in small chunks while preserving the current viewport
- **Poll filtering** — Telegram polls are skipped instead of rendering as empty cards
- **Stable viewport** — content insertions above and below the viewport do not shift the visible messages
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
- **UpdateRouter** — distributes incoming TDLib updates via `AsyncStream` to the rest of the app.
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
