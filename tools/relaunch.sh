#!/bin/zsh
# Quits Easy the normal way (it saves the draft and closes TDLib), waits until it is really gone, opens the
# freshly built bundle and checks it stays up. `open` on an app that is still quitting brings nothing back.
set -u
ROOT=${0:A:h:h}
APP="$ROOT/build/Easy.app"
PATTERN="Easy.app/Contents/MacOS/SwiftLite"

osascript -e 'tell application id "ru.anemia.swiftlite" to quit' >/dev/null 2>&1
for _ in {1..300}; do
  pgrep -f "$PATTERN" >/dev/null || break
  sleep 0.1
done
if pgrep -f "$PATTERN" >/dev/null; then
  print "Easy не закрылся за 30 с — оставляю как есть"
  exit 1
fi

open "$APP"
for _ in {1..50}; do
  pgrep -f "$PATTERN" >/dev/null && break
  sleep 0.2
done
sleep 3
if PID=$(pgrep -f "$PATTERN"); then
  osascript -e 'tell application id "ru.anemia.swiftlite" to activate' >/dev/null 2>&1
  print "Easy запущен: $PID"
else
  print "Easy не запустился"
  exit 1
fi
