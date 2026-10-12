# TDLib

Easy is built against TDLib 1.8.67, which is not kept in this repository.

- `vendor/td` is a checkout of https://github.com/tdlib/td at revision `42e6a5259551178d1dab54a22ad96d14bd906e20`.
- `vendor/tdlib` is that source built with CMake: Release, arm64, macOS 15 deployment target, static OpenSSL,
  LTO off. `Package.swift` and `build.sh` pick it up from there.
