# KeepMac

KeepMac is a native macOS storage cleaner for developers. It finds project build artifacts, caches and other files for review, and can use Apple Intelligence to explain items.

## Requirements

- Apple silicon Mac running macOS 26 or later
- Apple Command Line Tools to build
- Apple Intelligence availability is required for AI explanations

## Install

Download the DMG from the project's GitHub Releases, open it, and drag KeepMac into Applications. The app is ad-hoc signed and is not notarized; macOS may require you to explicitly allow it in Privacy & Security.

## Build

Run `./build.sh`. The app and DMG are created in `dist/`. Xcode is not required.

KeepMac may request access to folders it scans. Review items before deleting them.

## License

MIT. See [LICENSE](LICENSE).
