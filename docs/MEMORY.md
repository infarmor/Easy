# Checking memory

Easy's main promise is a small memory footprint. This page explains how to measure it, how to check that it
stays flat over a long session, and what each memory profile changes.

## What to measure

Use the **physical footprint**: the number Activity Monitor shows in its Memory column, and the number macOS
uses when it decides who to squeeze. Resident size (RSS) also counts shared frameworks, so it overstates.

```bash
footprint -p Easy
```

For a breakdown by region (decoded images show up in `CG image` and `IOSurface`, TDLib in `MALLOC_*`):

```bash
vmmap --summary $(pgrep -x Easy)
```

## Checking a long session

Memory that is only high is fine. Memory that keeps climbing is a leak. To tell them apart:

1. Quit Easy, start it, and wait until the chat list stops loading (about a minute). Write down the footprint.
2. Use it normally: open busy chats, scroll back through photos and stickers, switch accounts.
3. Measure again after an hour, and again after several hours. Expect it to rise at first, while the caches
   fill, and then level off. Steady growth on every measurement is a leak.
4. Switch to another app and wait. After the background delay of the current profile (see below), the decoded
   pictures are let go and the footprint should drop back close to the number from step 1.
5. If it does not drop, look for objects that never go away:

   ```bash
   leaks Easy
   heap Easy --sortBySize | head -40
   ```

A quick way to sample over time:

```bash
while true; do echo "$(date +%H:%M) $(footprint -p Easy | awk '/phys_footprint:/ {print $2, $3}')"; sleep 600; done
```

## Memory profiles

Settings → Storage → Memory profile. The default is Balanced.

| | Standard | Balanced | Economical |
| --- | --- | --- | --- |
| Decoded pictures in memory | 96 MB, 600 images | 64 MB, 400 images | 32 MB, 200 images |
| Lottie animations kept | 40 | 20 | 8 |
| Messages per chat kept to restore deleted ones | 60 | 40 | 20 |
| Pictures dropped after being in the background | 5 minutes | 200 seconds | 45 seconds |
| Downloaded files pruned by TDLib | no extra pruning | older than 7 days | older than 1 day |
| Animated stickers and emoji | on | on | off |

The values live in `Sources/SwiftLite/Support/MemoryProfile.swift` and `Sources/SwiftLite/UI/MediaCache.swift`.
Chat history stored on disk is never touched by any profile.

## Timing the hot paths

`Harness/run.sh perf` times the busy code paths (3000 chats arriving, bursts of new messages, a long open
chat) without a Telegram account. It is not pass/fail: run it before and after a change and compare the numbers.
`PERF_MESSAGES=5000` makes the open chat longer, and `PERF_LONG=1` repeats the unread-counter test 4000 times.
