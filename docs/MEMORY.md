# Checking memory over a long session

The figure in the README (about 171 MB) is one reading on one Mac. What matters more is that memory levels off:
a client that is open all day should end the day near where it settled in the first hour, not keep climbing.
This is how to check that on your own Mac.

## What to read

Read the **physical footprint**: the "Memory" column of Activity Monitor and the `Physical footprint` line of
`vmmap -summary`. The resident size (`RSS` in `ps`) counts pages shared with other processes and reads higher.

`tools/memory-sample.sh` writes both once a minute, as CSV, while Easy runs:

```bash
tools/memory-sample.sh 60 session.csv
```

## A session to measure

1. Start Easy with the accounts you use every day and wait until the chat list has loaded. The first few
   minutes are TDLib catching up, so start the sampler after that.
2. Use it the way you normally would for a few hours: open busy groups and channels, scroll far back through
   histories with photos and videos, open sticker and emoji panels, play a voice message, open a mini app.
3. Leave it in the background (another app in front) for longer than the profile's wait before pictures are
   let go: 5 minutes for Standard, 200 seconds for Balanced, 45 seconds for Economical.
4. Bring it back and go on using it. Repeat 2 and 3 a few times, ideally across a whole day.

## What to expect

- Memory rises while you open chats and scroll, then stays within a band. The decoded-picture cache has a
  fixed budget (96, 64 or 32 MB depending on the profile), so a lot of media does not mean an ever larger app.
- After the background wait the footprint drops, since every decoded picture and animation is released. The
  memory allocator does not always give pages back to the system at once, so the drop can be smaller than
  the cache's size.
- Each chat keeps at most 60, 40 or 20 recent messages for restoring deleted ones, so following many busy
  channels raises the band, but only up to that limit per chat.

A **steady climb over hours** that does not come down in the background is the sign of a leak. To find it:

```bash
leaks SwiftLite
```

lists memory that nothing points to any more. For memory that is still held but should not be (a cache
without a limit, a closure keeping a view alive), record the session with Instruments → Allocations, mark
generations before and after opening and closing the same chat a few times, and look at what each generation
leaves behind.

## Profiles

Settings → Storage → Memory profile. The README lists every budget each profile sets. Changing it applies at
once: the picture caches resize (Economical also empties them), and each account's TDLib gets the new options
and prunes downloaded files older than the profile's limit.
