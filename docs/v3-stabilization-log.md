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

---

## Stabilization continuation

Date: 2026-03-07

### Feed interaction hardening

- bottom `pull-to-refresh` is now an explicit release gesture instead of an automatic refresh triggered by ordinary scrolling
- current-day refresh rebuilds the feed from local midnight to now across all selected channels
- viewport restoration keeps the same visible anchor after manual refresh so unread/newer messages stay below the current screen
- upward pagination restores the same top anchor after inserting older messages, which removes visible jumps while browsing older posts
- automatic top trimming was removed from the browsing path to avoid unexpected position shifts

### Content consistency

- today's rebuild explicitly re-checks the latest message in each selected channel so the newest post is not dropped from the unified feed
- real Telegram channel avatars now appear in feed cards, channel sheets, and settings, with initial-based fallback when no photo is available
- public README and planning docs were updated to describe the current shipped behavior rather than older planning assumptions

### Follow-up fixes

- removed the explicit `.top` snap after upward pagination in the main feed so ordinary scroll completion no longer repositions the visible message
- strengthened the current-day rebuild to merge the fresh per-channel tail, not just a single latest message, which reduces cases where channel details show a newer post than the unified feed
