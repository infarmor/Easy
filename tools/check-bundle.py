"""Resolves every library an app bundle names, without launching it — launching would open a real session.

Three things make this more than a filesystem walk:
* macOS keeps its dylibs in the dyld shared cache, so `/usr/lib/swift/libswift_Concurrency.dylib` is not a
  file and cannot be stat'ed. dyld is asked instead: `dlopen` on the candidate path is exactly the resolution
  performed at launch — yes for a cached library, no for one that does not exist.
* `@executable_path` is the *app's* main executable, not the directory of the file being inspected, so a
  nested framework resolves it against Contents/MacOS rather than against itself.
* A dependency that exists on this Mac but lives in Homebrew or an Xcode toolchain is still a defect: it will
  not be there on the Mac this bundle travels to. Such paths fail regardless of whether they resolve here.
"""
import os
import subprocess
import sys

OPERATING_SYSTEM = ("/usr/lib/", "/System/Library/", "/System/iOSSupport/")
_system_probe = {}


def command_output(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True).stdout


def on_this_mac(path):
    """Whether dyld can produce this library here: a real file, or a hit in the shared cache."""
    if os.path.exists(path):
        return True
    if not path.startswith(OPERATING_SYSTEM):
        return False
    if path not in _system_probe:
        _system_probe[path] = subprocess.run(
            [sys.executable, "-c", "import ctypes,sys; ctypes.CDLL(sys.argv[1])", path],
            capture_output=True).returncode == 0
    return _system_probe[path]


def mach_o_files(app):
    """Every Mach-O under Contents, by real path, so @loader_path resolves where the code actually lives."""
    found = []
    for root, _, names in os.walk(os.path.join(app, "Contents")):
        for name in names:
            path = os.path.realpath(os.path.join(root, name))
            if "(compatibility version" in command_output("otool", "-L", path) and path not in found:
                found.append(path)
    return found


def search_paths(host, executable_dir):
    """LC_RPATH entries of one file, already resolved."""
    paths, want = [], False
    for line in command_output("otool", "-l", host).splitlines():
        entry = line.strip()
        if entry.startswith("cmd LC_RPATH"):
            want = True
        elif want and entry.startswith("path "):
            raw = entry.split()[1]
            if raw.startswith("@"):
                resolved = resolve(host, raw, executable_dir)
                paths.extend(resolved if isinstance(resolved, list) else [resolved])
            else:
                paths.append(raw)
            want = False
    return paths


def resolve(host, reference, executable_dir):
    """Where one @… reference points. A list means every place dyld would look, in rpath order."""
    if reference.startswith("@rpath/"):
        tail = reference[len("@rpath/"):]
        return [os.path.normpath(os.path.join(root, tail)) for root in search_paths(host, executable_dir)]
    if reference.startswith("@executable_path/"):
        return os.path.normpath(os.path.join(executable_dir, reference[len("@executable_path/"):]))
    if reference.startswith("@loader_path/"):
        return os.path.normpath(os.path.join(os.path.dirname(host), reference[len("@loader_path/"):]))
    if reference in ("@executable_path", "@loader_path"):
        return executable_dir if reference == "@executable_path" else os.path.dirname(host)
    return reference


def dependencies(host):
    """The library names in `otool -L`, minus the header line and the file's own install name."""
    listed = [line.strip().split()[0] for line in command_output("otool", "-L", host).splitlines()[1:] if line.strip()]
    identifier = command_output("otool", "-D", host).splitlines()
    own = identifier[1].strip() if len(identifier) > 1 else ""
    return listed[1:] if own and listed and listed[0] == own else listed


def check(app):
    executable_dir = os.path.realpath(os.path.join(app, "Contents", "MacOS"))
    problems = []
    for host in mach_o_files(app):
        for reference in dependencies(host):
            if reference.startswith("@rpath/"):
                candidates = resolve(host, reference, executable_dir)
                if not any(on_this_mac(candidate) for candidate in candidates):
                    problems.append(f"{host}: {reference} lands on none of {candidates}")
            elif reference.startswith("@"):
                target = resolve(host, reference, executable_dir)
                if not on_this_mac(target):
                    problems.append(f"{host}: {reference} → {target} is neither macOS nor in the bundle")
            elif not reference.startswith(OPERATING_SYSTEM):
                problems.append(f"{host}: {reference} is outside macOS and outside the bundle")
    return problems


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check-bundle.py <App.app>", file=sys.stderr)
        sys.exit(2)
    issues = check(sys.argv[1])
    print(f"библиотек проверено: {sum(len(dependencies(host)) for host in mach_o_files(sys.argv[1]))}")
    for issue in issues:
        print("ПРОБЛЕМА:", issue, file=sys.stderr)
    sys.exit(1 if issues else 0)
