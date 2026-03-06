# Plan v4 — Feed Stabilization & Read State

---

## About the Project

**TFeed** is a native iOS app (iOS 26+, Swift 6, SwiftUI) for reading Telegram channels as a unified feed. The user logs in with their Telegram account, selects channels, and reads all their messages in a single chronological stream. No messenger UI — just a clean content feed.

### Tech Stack

- **Swift 6 + SwiftUI**, iOS 26+ (Liquid Glass)
- **TDLibKit** (SPM, `https://github.com/Swiftgram/TDLibKit`) — Swift async/await wrapper over TDLib
- **Architecture**: MVVM + `@Observable`
- **Concurrency**: async/await, no Combine
- **Theme**: system (auto light/dark) with Liquid Glass materials support
- **No push notifications**, no server backend
- **Telegram API credentials**: `api_id` + `api_hash` from my.telegram.org

### Screens & Navigation

```
RootView
├── if !authenticated → AuthView (fullscreen)
├── if authenticated && no channels selected → FeedView (empty state)
└── if authenticated → FeedView (feed)
                          ├── .sheet → ChannelSheetView
                          └── .sheet → SettingsView
```

- **AuthView** — Telegram-style auth (phone → code → 2FA)
- **FeedView** — main screen: chronological feed from all selected channels, settings button, FAB "down" with unread counter
- **ChannelSheetView** — sheet over feed, shows messages from a single channel when user taps the button/link on a card
- **SettingsView** — sheet with channel selection, cache clearing, logout

### Architecture

```
TFeedApp (@main)
  ├── AppState (@Observable) — auth state, selected channels
  ├── TDLibService (actor singleton) — async API for TDLib + update stream
  ├── UpdateRouter — AsyncStream<Update> broadcast
  └── ViewModels (@Observable)
        ├── AuthViewModel
        ├── FeedViewModel
        ├── ChannelViewModel
        └── SettingsViewModel
```

### Project Structure

```
TFeed/
├── TFeedApp.swift
├── RootView.swift
├── Core/
│   ├── AppState.swift
│   └── Constants.swift
├── Services/
│   ├── TDLibService.swift
│   ├── TDLibService+Auth.swift
│   ├── TDLibService+Chats.swift
│   ├── TDLibService+Messages.swift
│   ├── TDLibService+Files.swift
│   └── UpdateRouter.swift
├── Models/
│   ├── FeedItem.swift           — id = FeedItemID(chatId, messageId), Comparable
│   ├── FeedItemID.swift         — Hashable, Codable composite key
│   ├── ChannelInfo.swift        — id, title, avatarFileId
│   ├── MediaInfo.swift          — photo/video/animation/voiceNote/audio/album
│   └── AuthStep.swift           — enum: phoneInput, codeInput, passwordInput
├── ViewModels/
│   ├── AuthViewModel.swift
│   ├── FeedViewModel.swift      — feed merge, pagination, unread tracking
│   ├── ChannelViewModel.swift   — single channel messages
│   └── SettingsViewModel.swift
├── Views/
│   ├── Auth/AuthView.swift
│   ├── Feed/
│   │   ├── FeedView.swift       — main screen: ScrollView + LazyVStack
│   │   ├── FeedCardView.swift   — message card
│   │   └── ReactionsBarView.swift
│   ├── Channel/ChannelSheetView.swift
│   ├── Settings/SettingsView.swift
│   └── Components/
│       ├── TdImageView.swift
│       ├── VideoPlayerView.swift
│       ├── AudioPlayerView.swift
│       ├── FullscreenMediaView.swift
│       ├── MediaContentView.swift
│       └── FormattedTextView.swift
├── Storage/
│   ├── SelectedChannel.swift    — @Model (SwiftData)
│   └── ScrollPositionStore.swift — UserDefaults (lastRead.chatId/messageId)
└── Extensions/
    ├── Date+Relative.swift
    └── Message+MediaType.swift
```

### Data Flow

```
TDLib (C++, background thread)
    │  JSON -> TDLibKit decodes to Swift types
    ▼
TDLibService (actor singleton)
    │
    ├── AsyncStream<Update>  ->  ViewModels subscribe & filter
    │
    └── async func calls     <-  ViewModels call directly
                                    │
                                    ▼
                              @Observable properties
                                    │
                                    ▼
                              SwiftUI Views (auto re-render)
```

### Current State (before v4)

All phases 1–7 and v3 stabilization are complete. The app builds, auth works, feed displays, media loads, ChannelSheet opens. However, there are serious UX problems: the feed jerks/jumps during scrolling and loading, ChannelSheet jumps around when opening, there is no real read/unread message tracking.

---

## Problems v4 Solves

1. **Message buffer is per-channel (30 per channel), not 30 total across all channels.** `FeedViewModel.loadInitialMessages()` loads up to 30 messages *per selected channel*. Required: exactly 30 messages total across all channels above the current position.

2. **ChannelSheet scrolls to `.top`, not to screen center.** In `ChannelSheetView` line 183, `requestScroll(to:anchor:.top)` is used. Per spec: the target message must be in the center of the screen.

3. **No real read/unread tracking.** `unreadCount` is simply `items.count - currentIndex - 1`, a pure UI position counter. No `viewMessages` calls, no read state storage, no checkmarks on messages.

4. **Jerking/jumping during scroll.** `Task.yield()` before and after `proxy.scrollTo()` doesn't always prevent visual jumps. When loading older messages, `normalizeItems()` re-sorts the entire array, which can cause LazyVStack re-rendering and content offset shifts.

5. **No "first message of today" logic on first launch.** Currently just loads the latest N messages per channel.

---

## Implementation Steps

---

### Step 1: Eliminate Jerking and Jumping During Loading

- [x] 1.1: Investigate and document all sources of visual jerks in current code

**Current state:** When scrolling up and loading older messages, the feed jerks. Visually: currently visible messages shift abruptly, content jumps, the user loses orientation. Causes:
- `normalizeItems()` re-sorts the entire array and can change element order
- `proxy.scrollTo()` with `Task.yield()` doesn't guarantee stability
- LazyVStack recalculates sizes when elements are added above

**Required behavior:**

During any message loading (above, below, real-time new messages) **nothing should jerk** on screen. What the user currently sees must stay in place. New messages appear off-screen (above or below) and become visible only when the user scrolls to them.

- [x] 1.2: Implement stable scroll anchoring via `.scrollPosition(id:anchor:)` from iOS 17+

Use scroll binding to a specific element. When elements are added above, ScrollView must automatically preserve the current element's position. Do not use `proxy.scrollTo()` to maintain position during loading — rely on the `scrollPosition` binding tied to the ID of the currently visible element. ScrollView will hold position by itself as long as the element ID doesn't change.

- [x] 1.3: Implement stable element insertion without full array re-sorting

Do not re-sort the entire array when adding new elements. Instead of `items = normalizeItems(items + newItems)` — insert new elements at the correct position (binary search by date) without full re-sort. Use `withAnimation(.none)` or no animation when inserting elements off-screen.

- [x] 1.4: Guarantee element `id` stability during normalization

Verify that element `id`s don't change during normalization. If `normalizeItems()` merges albums and changes the `id` of a visible element — this causes a jump. Must guarantee ID stability.

- [x] 1.5: Test all scenarios for absence of jerks

Test scenarios:
- Slow scroll up (one message at a time) — smooth loading without jerks
- Fast scroll up (quick swipe) — batch loading, no jerks
- New message arrives in real-time while user reads old ones — feed doesn't jump, only the counter updates
- App opens with saved position — message is in place, no initial jump

**Files to modify:**
- `TFeed/Views/Feed/FeedView.swift` — rework scroll mechanics
- `TFeed/ViewModels/FeedViewModel.swift` — stable insertion without re-sorting
- `TFeed/Models/FeedItem.swift` — guarantee ID stability

---

### Step 2: Buffer of 30 Messages Above (Total Across All Channels)

- [x] 2.1: Extract buffer size into a constant

The number 30 must be extracted into a constant (e.g., `static let upwardBufferSize = 30`) so it can easily be changed to 10 or 15.

- [x] 2.2: Implement threshold-based loading instead of edge-based

**Current state:** `loadOlder()` loads up to 30 messages *per channel* when scrolling to the first element. So if 10 channels are selected, up to 300 messages get loaded. Loading triggers only when reaching the very first element in the list.

**Required behavior:**

Above the currently visible message there must always be exactly ~30 messages from all channels *combined*. Not 30 per channel, but 30 total. Logic:

1. When the user scrolls up and starts reading older messages, the buffer above shrinks. Example: there were 30, scrolled up by 1 message — 29 remain above.

2. At this point, load 1 more message above (from all channels) so the buffer is back to 30.

3. If the user quickly scrolled up by 5 messages — 25 remain above — load 5 more messages.

4. Loading triggers **not when reaching the first element**, but **when the number of elements above the current position changes**. A threshold is needed: if the count of elements above current < 30, trigger loading.

- [x] 2.3: Implement loading from all channels combined

For loading: request messages older than the oldest loaded message from all channels. Collect responses into a single array, sort, take the needed count (30 - current buffer).

- [x] 2.4: No jerks during loading (see Step 1)

The currently visible message stays in place. New messages are added above, but the screen doesn't scroll or jump.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — complete rework of `loadOlder()`, new buffer calculation
- `TFeed/Views/Feed/FeedView.swift` — change loading trigger (not "reached first element" but "buffer < 30")

---

### Step 3: Trim Messages Above When Scrolling Down

- [ ] 3.1: Implement automatic trimming of top messages

**Current state:** Messages are not removed from the array when scrolling down. The `items` array grows indefinitely.

**Required behavior:**

When the user scrolls down, new messages appear below (either loaded or arriving in real-time). Simultaneously, messages above must be removed so the buffer above stays at ~30:

1. The primary reading direction is scrolling down (from old to new).

2. As the user scrolls down, each newly visible message becomes the current one, and its ID is saved.

3. If the count of messages above the current one exceeds 30 (e.g., 31), the topmost (oldest) message is removed from the `items` array.

4. This must not cause jerks, because the removed message is already off-screen (far above, the user has already scrolled past it).

5. Thus, the `items` array contains: ~30 messages above current + current + all messages below current (down to the newest).

- [ ] 3.2: Debounced scroll position saving

Always remember which message the user stopped at. This message's ID is written to `ScrollPositionStore` on each scroll position change (debounced, to avoid writing on every pixel).

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — top message trimming method
- `TFeed/Views/Feed/FeedView.swift` — trigger trimming on `scrollPosition` change

---

### Step 4: Rework Initial Feed Loading (First Launch)

- [ ] 4.1: Implement "first message of today" logic

**Current state:** On first launch (no saved `savedMessageId`), the latest 30 messages *per channel* are loaded and displayed chronologically. Scroll position is at the newest message (`.bottom`).

**Required behavior:**

When the user opens the app *for the first time* (no saved message ID in `ScrollPositionStore`, i.e., `ScrollPositionStore.load()` returns `nil`):

1. Determine the **first message of today** from all selected channels. "Today" means the start of the current day in the user's local timezone. Load recent messages from each selected channel and find the earliest one with date (`message.date` — UNIX timestamp) >= start of today.

2. If there are no messages from today in any channel — show the latest available message from all channels (the most recent) and scroll to it.

3. The first message of today becomes the **anchor point** — the point the screen scrolls to. It should be visible on screen (in the upper part or center).

- [ ] 4.2: Load buffer of old messages (20-30 from yesterday)

**Above this message**, load 20–30 messages from *all channels combined* from the previous day (or earlier days if there aren't enough from yesterday). Method: request messages older than the anchor point from all channels, collect into a single array, sort by date, take the last 30.

- [ ] 4.3: Load today's messages below the anchor point

**Below the anchor point**, load all messages from today across all channels (there may be few or none at the time of first launch).

Result: the user sees the first message of today, can scroll up to see 20–30 yesterday's messages, can scroll down to see the rest of today's messages.

- [ ] 4.4: Verify placeholder when no channels are selected

**If no channels are selected** — a placeholder "Select channels to read" is shown (already implemented, needs verification). Test scenarios:
1. First launch, no channels selected → placeholder.
2. Had channels, user deselected all in settings → placeholder.
3. Placeholder should disappear when the user selects at least one channel.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — `load()` method, new initial loading logic
- `TFeed/Views/Feed/FeedView.swift` — pass anchor point for scroll

---

### Step 5: Rework Initial Feed Loading (Subsequent Launch)

- [ ] 5.1: Implement loading a window around the saved message

**Current state:** On subsequent launch, `ScrollPositionStore.load()` returns a saved `FeedItemID` (chatId + messageId). The app tries to load the latest 30 messages per channel and scroll to the saved message.

**Required behavior:**

When the user opens the app again (saved `savedMessageId` exists):

1. Load messages from each channel **around** the saved timestamp (date of the saved message). Method: determine the saved message's date, load messages from each channel around that date ± some window.

2. Collect all loaded messages into a single sorted array.

3. Find the saved message in this array (by `chatId` + `messageId`). If found — scroll to it. If not (channel was deselected, or message was deleted) — scroll to the nearest one by time.

- [ ] 5.2: Ensure 30-message buffer above the saved position

**Above the saved message** there must be 30 messages from all channels combined. If after initial loading there are fewer than 30 — load more.

- [ ] 5.3: Load all new messages below the saved position

**Below the saved message** — all messages that appeared after it (up to now). These are new, unread messages.

- [ ] 5.4: Scroll to the saved message without jerks

Scroll positions on the saved message (center of screen or upper part). No jumps, no flickering, no show-top-first-then-scroll behavior.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — `load()` method, restore logic
- `TFeed/Storage/ScrollPositionStore.swift` — may need to also store the timestamp

---

### Step 6: Real-Time New Message Monitoring

- [ ] 6.1: Adapt `applyIncomingMessage()` to the new buffer model

**Current state:** `FeedViewModel.startListening()` listens to `updateNewMessage` via `UpdateRouter` and adds new messages to the `items` array. If the user is at the bottom (`isAtBottom`) — scrolls to the new message. Otherwise — increments `unreadCount`.

**Required behavior:**

The basic logic already works, but needs adaptation to the new model:

1. New messages arrive from selected channels and are added to the **very bottom** of the feed (they are the newest chronologically).

2. When the user is at the very bottom of the feed — the new message appears but the **feed does NOT auto-scroll**. It stays in place, no jerks occur. The new message appears below, and the unread counter updates. The user must scroll down to the new message manually.

3. If the user is above (reading old messages) — the new message is added to the array, but the **feed does NOT scroll**. Instead, the unread counter on the down-arrow button updates.

4. The feed always stays chronological. A new message is never inserted between existing ones — always at the end (it's the newest).

5. When a new message is added to the end — no jerks. The user doesn't see it (it's off-screen, below) until they scroll down.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — adapt `applyIncomingMessage()` to the new buffer model

---

### Step 7: Button/Link on Each Message to Open ChannelSheet

- [ ] 7.1: Verify and fix the button on each card

**Current state:** `FeedCardView` has a link (text button) with the channel name that opens `ChannelSheetView` when tapped.

**Required behavior:**

1. Each message (each `FeedCardView` card) must have a small button at the bottom. Currently implemented as a text link — this is acceptable for now, will be replaced with a different UI element later.

2. Tapping this button slides up a screen (`ChannelSheetView`) from the bottom — a sheet showing messages from **only the one specific channel** that sent this message.

3. The button passes two parameters to `ChannelSheetView`: channel info (`ChannelInfo`) and the ID of the tapped message (`FeedItemID`).

4. Verify the current implementation correctly passes both parameters. If not — fix it.

**Files to modify:**
- `TFeed/Views/Feed/FeedCardView.swift` — verify button and passed parameters
- `TFeed/Views/Feed/FeedView.swift` — verify `.sheet(item:)` and `selectedMessageId` passing

---

### Step 8: Rework ChannelSheet — Target Message in Center

- [ ] 8.1: Change anchor from `.top` to `.center`

**Current state:** `ChannelSheetView` loads a window of ~50 messages around the target via `fetchWindow()` on open. Then tries to scroll to the target message with anchor `.top`. In practice this is unstable: on opening, the screen shows the top of the list, then starts jerking, jumping, loading, and ultimately the target message is impossible to find.

**Required behavior:**

1. The user taps a message in the feed → a sheet slides up from the bottom.

2. This sheet shows messages from **only one channel**.

3. **The target message (the one tapped) must be in the CENTER of the screen.** Not at the top, not at the bottom — in the center. Use anchor `.center` with `scrollTo()`.

4. **Below the target message** — all newer messages from this channel (chronologically).

5. **Above the target message** — all older messages from this channel. Load ~30 older messages (same as the main screen buffer), plus infinite loading on scroll up (Step 9).

- [ ] 8.2: Eliminate jerks when opening ChannelSheet

**No jerks or jumping when opening the sheet.** User taps — sheet slides up — target message is immediately in the center — everything is stable. To achieve this:
- Load messages BEFORE showing content (while loading — show a loading indicator)
- When messages are loaded — show the list already scrolled to the target message
- Do not show the list empty and then scroll — show it in the correct position from the start

- [ ] 8.3: Guarantee chronological order in ChannelSheet

Messages are displayed chronologically: old at top, new at bottom — same as in the main feed.

**Files to modify:**
- `TFeed/Views/Channel/ChannelSheetView.swift` — anchor `.center`, loading state, stable initial position
- `TFeed/ViewModels/ChannelViewModel.swift` — load window around target message

---

### Step 9: Infinite Upward Scroll in ChannelSheet

- [ ] 9.1: Implement threshold-based loading in ChannelSheet

**Current state:** `ChannelViewModel.loadOlder()` loads 30 messages when reaching the first element. `ChannelViewModel.loadNewer()` — when reaching the last. Bidirectional scroll is implemented but jerky.

**Required behavior:**

ChannelSheet uses the same buffer logic as the main feed:

1. **Scrolling up (to older messages)** — infinite loading. Above the currently visible message there must always be ~30 messages from this channel. Logic identical to Step 2:
   - Scrolled up by 3 messages → 27 remain above → loaded 3 more → back to 30.
   - Fast swipe up by 10 → 20 remain above → loaded 10 more → back to 30.
   - Loading triggers by threshold (buffer < 30), not when reaching the first element.

2. **Scrolling down (to newer messages)** — finite: reach the newest message in the channel and stop. If no newer messages — `hasReachedNewest = true`.

3. **No jerks during loading.** Same requirement as for the main feed (Step 1). The currently visible message stays in place, new messages appear off-screen.

4. In ChannelSheet the buffer is messages from ONE channel (unlike the main feed where it's from all channels).

**Files to modify:**
- `TFeed/ViewModels/ChannelViewModel.swift` — rework `loadOlder()`, threshold-based loading
- `TFeed/Views/Channel/ChannelSheetView.swift` — trigger loading by threshold, not by first/last element

---

### Step 10: Read/Unread Message System with Telegram Sync

- [ ] 10.1: Add `viewMessages` API to TDLibService

Add method `TDLibService.viewMessages(chatId:messageIds:)` to report read messages to Telegram. When a message is marked as read in TFeed, this method is called, and Telegram marks it as read on the server too. This means: the user later opens regular Telegram and sees these channels are already read — no need to scroll through every channel just to mark them as read.

- [ ] 10.2: Implement read state determination via `lastReadInboxMessageId`

For each channel, TDLib stores `lastReadInboxMessageId` in the `Chat` object. All messages with `messageId <= lastReadInboxMessageId` are considered read. Use this info to determine the initial read state on loading.

- [ ] 10.3: Implement automatic marking as read on scroll

When a message is considered read:
- In the main feed: when the user has scrolled past the message downward (it went above the visible area or was visible long enough).
- In ChannelSheet: when the user scrolls down through channel messages — they are marked as read.
- Debounce: mark a message as read when it has been on screen for >= 1 second, or batch-send on scroll position change.

- [ ] 10.4: Add read state visual indicator to each card

Each message (FeedCardView and ChannelSheet card) displays a small checkmark or other read indicator:
- Read: muted appearance or checkmark.
- Unread: no checkmark or bright indicator.
- The indicator must update in real-time during scrolling.

- [ ] 10.5: Add `isRead` to the FeedItem model

Possibly add a computed or stored `isRead` property to `FeedItem`, based on comparing `messageId` with `lastReadInboxMessageId` for the given `chatId`.

**Files to modify:**
- `TFeed/Services/TDLibService+Messages.swift` — add `viewMessages(chatId:messageIds:)` method
- `TFeed/ViewModels/FeedViewModel.swift` — logic for marking as read on scroll
- `TFeed/ViewModels/ChannelViewModel.swift` — same for ChannelSheet
- `TFeed/Views/Feed/FeedCardView.swift` — read state visual indicator
- `TFeed/Views/Channel/ChannelSheetView.swift` — read state visual indicator
- `TFeed/Models/FeedItem.swift` — `isRead` property

---

### Step 11: Unread Counter on the Down-Arrow Button

- [ ] 11.1: Rework `unreadCount` calculation based on real read state

**Current state:** Button with `chevron.down` and a number in the bottom-right corner. Number = count of elements below the current scroll position. Button hides when `isAtBottom == true`.

**Required behavior:**

1. The down-arrow button is in the bottom-right corner of the main screen.

2. It displays the **number of unread messages**. Not simply "how many elements are below the current position", but the real count of messages marked as unread (based on `lastReadInboxMessageId` and `viewMessages`).

3. **Only messages BELOW the currently visible message are counted.** Everything above (older) is not counted at all. If the user scrolled up and there are unread messages there — they don't count. Only what's below the currently visible message counts.

4. Tapping the button scrolls to the newest (bottom) message with animation.

5. The button hides when the user is at the very bottom of the feed and there are no unread messages.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — rework `unreadCount` based on real read state
- `TFeed/Views/Feed/FeedView.swift` — button UI (already implemented, verify)

---

### Step 12: Read State Sync Between Main Feed and ChannelSheet

- [ ] 12.1: Implement read state transfer from ChannelSheet to FeedViewModel

**Current state:** No sync exists. ChannelSheet is a separate ViewModel that doesn't affect FeedViewModel.

**Required behavior:**

1. The user sees a message from channel X on the main screen. Taps the button → ChannelSheet opens with channel X messages.

2. In ChannelSheet, the user scrolls down and reads new messages. On scroll, these messages are marked as read (both in TFeed and in Telegram via `viewMessages`).

3. The user closes ChannelSheet and returns to the main screen.

4. **On the main screen:**
   - Scroll stays on the same message where it was before opening ChannelSheet. **Nothing moves.** No scrolling on the main screen should happen. The counter just changed.
   - The unread counter on the down-arrow button updates — subtracts messages read in ChannelSheet.
   - If messages from channel X that were read in ChannelSheet are visible in the feed — their visual indicator (checkmark) updates to "read".

- [ ] 12.2: Implement UI update without scroll on return from ChannelSheet

On ChannelSheet close, call a `FeedViewModel` method that recalculates read state based on updated Telegram data (or pass the list of read messageIds from ChannelViewModel to FeedViewModel). Scroll does NOT change.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — read state update method without scroll
- `TFeed/ViewModels/ChannelViewModel.swift` — pass read message info
- `TFeed/Views/Feed/FeedView.swift` — call update on sheet close

---

### Step 13: Feed Is Always Chronological, Nothing Disappears

- [ ] 13.1: Verify and guarantee chronological order

**Required behavior:**

1. **The feed is always chronological.** Messages are sorted by their send date and time. The order they were sent in is the order they appear. This applies to both the main feed (all channels) and ChannelSheet (single channel).

2. **No messages disappear from the feed.** Once a message is loaded — it stays in the feed in its place. It doesn't vanish when read, doesn't move, doesn't hide. Read and unread messages appear in the same feed interleaved, strictly chronologically. The feed is always chronological. No messages disappear from the feed; it's always a chronology by date and time. As they appeared, that's how they should be in the feed.

3. **When the user returns to the main screen after ChannelSheet** and starts scrolling down — they encounter messages they may have already seen in ChannelSheet. These messages are still present in the feed. They are simply marked as read (with a checkmark). Nothing is removed or skipped from the feed.

4. **The only exception — top buffer trimming** (Step 3): the oldest messages beyond the 30-item buffer are removed from the array to save memory. But the user can scroll back to them (they will be re-loaded).

5. Verify that `normalizeItems()` doesn't delete or duplicate messages. Each message with a unique `messageId` in a specific `chatId` must appear in the feed exactly once (exception — albums that are merged into a single card, but all their `representedMessageIds` are accounted for).

In the all-channels feed, on the main screen, and in the single-channel detail view — everything appears chronologically.

**Files to modify:**
- `TFeed/ViewModels/FeedViewModel.swift` — verify `normalizeItems()`, guarantee chronological order
- Test all scenarios

---

## Implementation Order

Recommended sequence (each step depends on previous ones):

1. **Step 1** — Eliminate jerks (foundation for everything else)
2. **Step 2** — Buffer of 30 messages above (total)
3. **Step 3** — Trim above when scrolling down
4. **Step 4** — Initial loading (first launch)
5. **Step 5** — Initial loading (subsequent launch)
6. **Step 6** — New message monitoring (adaptation)
7. **Step 7** — Button on message (verify)
8. **Step 8** — ChannelSheet — target message in center
9. **Step 9** — Infinite scroll in ChannelSheet
10. **Step 10** — Read/unread system + Telegram sync
11. **Step 11** — Unread counter
12. **Step 12** — Sync between feed and ChannelSheet
13. **Step 13** — Chronological order (verify)

---

## Key Project Files

| File | Role |
|------|------|
| `TFeed/ViewModels/FeedViewModel.swift` | Main feed business logic |
| `TFeed/Views/Feed/FeedView.swift` | Main feed UI |
| `TFeed/Views/Feed/FeedCardView.swift` | Message card |
| `TFeed/ViewModels/ChannelViewModel.swift` | ChannelSheet logic |
| `TFeed/Views/Channel/ChannelSheetView.swift` | ChannelSheet UI |
| `TFeed/Services/TDLibService+Messages.swift` | Telegram API calls |
| `TFeed/Storage/ScrollPositionStore.swift` | Scroll position persistence |
| `TFeed/Models/FeedItem.swift` | Message model |
| `TFeed/Models/FeedItemID.swift` | Message ID (chatId + messageId) |
| `TFeed/Services/UpdateRouter.swift` | Real-time TDLib updates |
