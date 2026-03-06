## Plan v3 Stabilization Log

Date: 2026-03-06

### Closed scope

- `Bug 4`: footer post reference opens `ChannelSheetView` in-app instead of falling back to Telegram
- `Bug 5`: `ChannelSheetView` loads a full channel window, restores the exact target message, paginates up and down
- `Bug 6`: feed restores the exact reading position, keeps unread messages below the current item, shows the down FAB with counter, keeps position when channels are enabled or disabled, loads 30 messages per selected channel on first open, paginates older history upward
- `Bug 7`: selected channels receive new messages in real time through `updateNewMessage`

### Additional stabilization

- grouped Telegram media albums into a single feed/channel card instead of rendering every photo as a separate post
- restored in-app handling for Telegram post links embedded inside message text
- kept scroll position persistence continuous during active usage, not only on scene backgrounding

### Implementation notes

- feed restore now backfills each selected channel down to the restored timestamp so the unread segment below the saved message stays contiguous
- realtime updates are buffered during reload and applied after the feed model is ready
- album cards keep all represented message IDs, which allows exact target matching even when multiple Telegram messages are rendered as one card
- programmatic scroll in feed and channel sheet now resolves through explicit target tracking to avoid fallback jumps to the wrong item

### Verification

- build: `xcodebuild -project TFeed.xcodeproj -scheme TFeed -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- result: build succeeded
- note: Xcode emitted only the standard AppIntents metadata warning because the app does not link `AppIntents.framework`

### Release hygiene

- keep unrelated local changes out of the release commit
- stage only product source and product documentation related to this stabilization pass
