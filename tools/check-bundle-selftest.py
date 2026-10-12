"""Proves tools/check-bundle.py can go red: each mutation must be reported, and a mutation that did not
land counts as a failure too. Run: python3 tools/check-bundle-selftest.py
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SOURCE = os.path.join(REPO, "build", "Easy.app")
SCRATCH = "/tmp/check-bundle-selftest.app"
MAIN = os.path.join("Contents", "MacOS", "SwiftLite")
LOTTIE = os.path.join("Contents", "Frameworks", "Lottie.framework", "Versions", "A", "Lottie")

MUTATIONS = [
    ("a bundled library renamed away", MAIN, "@rpath/libtdjson.dylib", "@rpath/absent.dylib"),
    ("a dependency pointing at Homebrew", MAIN, "@rpath/Lottie.framework/Versions/A/Lottie",
     "/opt/homebrew/lib/libLottie.dylib"),
    ("a system Swift library renamed away", LOTTIE, "@rpath/libswift_Concurrency.dylib",
     "@rpath/libswift_NotThere.dylib"),
    ("a bundled framework deleted", MAIN, "@rpath/Lottie.framework/Versions/A/Lottie",
     "@rpath/Lottie.framework/Versions/A/Absent"),
]


def run(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True)


def main():
    if not os.path.isdir(SOURCE):
        print("no build/Easy.app — run ./build.sh first", file=sys.stderr)
        return 1
    failures = 0
    for label, binary, old, new in MUTATIONS:
        shutil.rmtree(SCRATCH, ignore_errors=True)
        shutil.copytree(SOURCE, SCRATCH, symlinks=True)
        target = os.path.join(SCRATCH, binary)
        if run("install_name_tool", "-change", old, new, target).returncode != 0:
            print(f"SKIP  {label}: could not mutate")
            failures += 1
            continue
        listed = run("otool", "-L", target).stdout
        if new not in listed:
            print(f"SKIP  {label}: the mutation did not land")
            failures += 1
            continue
        result = run(sys.executable, os.path.join(HERE, "check-bundle.py"), SCRATCH)
        if result.returncode == 0:
            print(f"GREEN {label}: the checker missed it")
            failures += 1
        else:
            first = [line for line in result.stderr.splitlines() if line.startswith("ПРОБЛЕМА:")]
            print(f"RED   {label}: {first[0][11:][:100] if first else 'exit ' + str(result.returncode)}")
    shutil.rmtree(SCRATCH, ignore_errors=True)
    print(f"из {len(MUTATIONS)} мутаций поймано: {len(MUTATIONS) - failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
