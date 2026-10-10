#!/bin/zsh
# Test stands for iGram. They compile the app's own sources next to a test main.swift.
#
#   Harness/run.sh            logic + lifecycle + ui + webapp + scroll
#   Harness/run.sh logic      one of them
#
# Every stand keeps its data under Harness/.work. Before compiling, each copy of the sources is rewritten so
# Credentials, Preferences and MessageArchive point there, and the run stops if any of them could still reach
# the real app folders (~/Library/Application Support, ~/Library/Logs, the sandbox container).
set -u
HERE=${0:A:h}
ROOT=${HERE:h}
WORK=$HERE/.work
TDLIB=$ROOT/vendor/tdlib
mkdir -p $WORK

lottie_dir() {
  local dir=$ROOT/.build/out/Products/Release
  [[ -d $dir/Lottie.framework ]] || dir=${$(find $ROOT/.build -name Lottie.framework -maxdepth 6 -print -quit):h}
  print -r -- $dir
}

# prepare <name> <source folders...>: fresh copy of the sources with every real path redirected.
prepare() {
  local name=$1; shift
  local dir=$WORK/$name
  rm -rf $dir/src && mkdir -p $dir/src
  for folder in "$@"; do cp $ROOT/Sources/SwiftLite/$folder/*.swift $dir/src/; done
  cp $HERE/$name/main.swift $dir/src/main.swift
  python3 - $dir/src "$WORK/$name-data" <<'PY'
import sys, os
src, data = sys.argv[1], sys.argv[2]
def patch(name, old, new):
    path = os.path.join(src, name)
    if not os.path.exists(path): return
    text = open(path).read()
    if old in text:
        open(path, 'w').write(text.replace(old, new))
    elif name == 'AppModel.swift':
        # A patch of the model that finds nothing leaves the stand without the access it was written to
        # get, and the compile error that follows names a symptom, not this.
        sys.exit('ABORT: AppModel.swift no longer contains: ' + old.strip().splitlines()[0])
patch('Credentials.swift', '''let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftLite", isDirectory: true)''', 'let base = URL(fileURLWithPath: "%s/app", isDirectory: true)' % data)
patch('Preferences.swift', 'FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]', 'URL(fileURLWithPath: "%s/logs")' % data)
patch('MessageArchive.swift', 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'URL(fileURLWithPath: "%s/support")' % data)
# Test access to internals. Most of the model's state is already open to its AppModel+… files; these few are not.
patch('AppModel.swift', '    private func apply(_ update: TDNode)', '    func apply(_ update: TDNode)')
# Every request is recorded before the closed-session check, so a stand can assert what a feature really sends.
patch('AppModel.swift', '    @ObservationIgnored var trackedFiles: Set<Int> = []', '    @ObservationIgnored var recordedRequests: [TDNode] = []\n    @ObservationIgnored var trackedFiles: Set<Int> = []')
patch('AppModel.swift', '''    func request(_ payload: TDNode) async throws -> TDNode {
        guard let bridge else { throw TDError.closed }''', '''    func request(_ payload: TDNode) async throws -> TDNode {
        recordedRequests.append(payload)
        guard let bridge else { throw TDError.closed }''')
patch('AppModel.swift', '''    private func start(with credentials: Credentials) {
        guard bridge == nil else { return }
''', '''    var sessionsStarted = 0
    var hasSession: Bool { bridge != nil }
    private func start(with credentials: Credentials) {
        guard bridge == nil else { return }
        sessionsStarted += 1
''')
PY
  (( $? == 0 )) || exit 1
  if grep -l "applicationSupportDirectory\|libraryDirectory\|Library/Containers" $dir/src/*.swift; then
    print "ABORT: $name could reach the real app folders"; exit 1
  fi
  rm -rf $WORK/$name-data && mkdir -p $WORK/$name-data/app
}

compile() {
  local name=$1; shift
  local out
  out=$(swiftc -swift-version 5 $WORK/$name/src/*.swift -I $ROOT/Sources/CTDLib -Xcc -I$TDLIB/include \
    -L $TDLIB/lib -ltdjson -Xlinker -rpath -Xlinker $TDLIB/lib "$@" -o $WORK/$name/$name 2>&1 | grep " error")
  if [[ -n $out ]]; then print -r -- $out; print "$name: build FAILED"; return 1; fi
}

# verdict <name> <dir> <command...>: the stand's own verdict lines, and red if it died before printing them.
# Piping the run through grep hides a crash behind an empty success, which is the one thing a test stand
# must never do.
verdict() {
  local name=$1 dir=$2
  shift 2
  local output code
  output=$(cd $dir && "$@" 2>&1)
  code=$?
  print -r -- "$output" | grep -E "^FAIL|PASSED|FAILED|Fatal|error:" | tail -20
  if (( code != 0 )); then
    print "$name: died with exit $code — $(print -r -- "$output" | tail -1)"
    return 1
  fi
}

run_logic() {
  prepare logic TDLib Store Support && compile logic || return 1
  verdict logic $WORK/logic ./logic
}

run_lifecycle() {
  prepare lifecycle TDLib Store Support || return 1
  # The test expects its keys file at <folder>/root/credentials.json.
  sed -i '' "s#$WORK/lifecycle-data/app#$WORK/lifecycle/root#" $WORK/lifecycle/src/Credentials.swift
  compile lifecycle || return 1
  rm -rf $WORK/lifecycle/root && mkdir $WORK/lifecycle/root
  verdict lifecycle $WORK/lifecycle ./lifecycle $WORK/lifecycle
}

run_ui() {
  local lottie=$(lottie_dir)
  prepare ui TDLib Store Support UI && compile ui -F $lottie -framework Lottie -framework AVKit -framework WebKit \
    -Xlinker -rpath -Xlinker $lottie || return 1
  verdict ui-light $WORK/ui ./ui $WORK/ui/light.png
  verdict ui-dark $WORK/ui ./ui $WORK/ui/dark.png dark
  print "snapshots: $WORK/ui/light.png, $WORK/ui/dark.png"
}

# The transcript in a real window: what scrolling to its top asks for.
run_scroll() {
  local lottie=$(lottie_dir)
  prepare scroll TDLib Store Support UI && compile scroll -F $lottie -framework Lottie -framework AVKit -framework WebKit \
    -Xlinker -rpath -Xlinker $lottie || return 1
  verdict scroll $WORK/scroll ./scroll
}

run_perf() {
  # Support.swift of the UI holds the date and emoji helpers measured here.
  prepare perf TDLib Store Support || return 1
  python3 - $ROOT/Sources/SwiftLite/UI/Support.swift $WORK/perf/src/UISupport.swift <<'PY'
import sys
s = open(sys.argv[1]).read()
dates = s[s.index('private let russian'):s.index('/// Initials on a tinted circle')]
emoji = s[s.index('extension String {'):s.index('/// The colour of accents inside a bubble')]
open(sys.argv[2], 'w').write('import Foundation\n\n' + dates + '\n' + emoji)
PY
  compile perf -O || return 1
  # The timings are the point of this stand, so they are printed whole rather than filtered.
  local output code
  output=$(cd $WORK/perf && ./perf 2>&1)
  code=$?
  print -r -- "$output"
  if (( code != 0 )); then print "perf: died with exit $code"; return 1; fi
}

run_webapp() {
  local lottie=$(lottie_dir)
  prepare webapp TDLib Store Support UI && compile webapp -F $lottie -framework Lottie -framework AVKit -framework WebKit \
    -Xlinker -rpath -Xlinker $lottie || return 1
  # A previous run can still hold the port, and `sleep 1` says nothing about readiness: on a busy machine the
  # page loads against a server that has not bound yet, and events the bridge really sent read back as missing.
  [[ -f $WORK/webapp/server.pid ]] && kill $(cat $WORK/webapp/server.pid) 2>/dev/null
  (cd $HERE/webapp/site && python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 & print $! > $WORK/webapp/server.pid)
  for _ in {1..100}; do
    curl -fs -o /dev/null http://127.0.0.1:8765/index.html && break
    sleep 0.1
  done
  verdict webapp $WORK/webapp ./webapp
  kill $(cat $WORK/webapp/server.pid) 2>/dev/null
}

if (( $# )); then stands=("$@"); else stands=(logic lifecycle ui webapp scroll); fi
rc=0
for stand in $stands; do
  print "== $stand"
  run_$stand || rc=1
done
exit $rc
