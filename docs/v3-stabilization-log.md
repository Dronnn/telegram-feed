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
- replaced the old pseudo cache clear with a real TDLib local-data reset (`destroy`), which also clears locally selected channels and forces a clean re-login
- switched TDLib chat discovery away from the initial `100`-chat cap by loading the full main chat list before building channel lists
- extended TDLib update handling beyond `updateNewMessage`: feed/channel models now react to edits, deletions, read-inbox updates, and channel title/photo changes
- tightened message filtering so unsupported TDLib message content no longer renders as empty cards
- kept older-history loading behind an explicit upward user scroll so the feed no longer pulls in yesterday/older posts on first paint or immediately after a manual rebuild
- preserved older-history participation for selected channels that have no visible posts today, so they still join the unified chronology once the user scrolls upward into previous periods
- rebuilt grouped media cards after live Telegram edits/deletions instead of dropping the whole album card until the next reload
- hardened file downloads with synchronous TDLib completion plus timeout/cancel fallback, and made late title/photo updates self-heal through `getChat` when local channel metadata is still cold

### TDLib runtime hardening

- moved TDLib update callback creation behind a nonisolated boundary so the library's serial update queue no longer directly enters actor-isolated `TDLibService` code
- kept the hop back into `TDLibService` explicit through `Task { await ... }`, which matches the queue contract documented by `TDLibKit`
- changed `UpdateRouter` delivery to snapshot continuations first, yield outside the internal lock, and prune terminated subscribers afterward
- re-verified the app with both the normal simulator build and `SWIFT_STRICT_CONCURRENCY=complete`

### Feed UX history-window hardening

- made upward pagination strictly gesture-gated: older history can load only while the user is actively dragging upward, and the gesture arms only one fetch before it must be repeated
- introduced a separate current-day floor for the unified feed and recalculate the visible lower bound after trims, removals, and channel changes, which prevents old dates from reappearing in the today-only window on their own
- kept edited or re-fetched messages inside the unified chronology if that message was already represented in the visible/deferred history window
- tightened the upward trigger from `<= 10` hidden items to `< 10`, so the feed does not immediately chain another history fetch right after restoring the preview buffer
- removed the last programmatic `.top` restore from main-feed upward pagination and made the one-fetch-per-drag gate depend on a real successful older-history load
- merged deferred older-preview items and freshly fetched older batches into one chronological selection step, which prevents upward scrolling from leaping into week-old preview posts out of order
- corrected message deduplication to use `chatId + messageId` across feed and channel models, so posts from different channels can no longer suppress each other when Telegram reuses the same per-chat message ID
- restored the same top visible feed item after each successful upward pagination batch, so inserting older cards above the viewport no longer throws the reader into a much older day
- re-verified the feed behavior with another full static audit focused on chronology, upward pagination gates, and day-boundary preservation
