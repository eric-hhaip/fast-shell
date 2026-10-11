# Fast Shell

**English** | [简体中文](README.zh-CN.md)

> A lightweight remote-ops workbench for macOS — **SSH terminal + SFTP file manager + server monitoring** in a single window.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B.svg)](https://flutter.dev)

Built with Flutter 3.47 (macOS desktop) · dartssh2 (SSH / SFTP) · xterm.dart (terminal rendering) · cryptography (AES-256-GCM local encryption)

---

## Download

Grab the latest `Fast-Shell-<version>-macos.zip` from
[Releases](https://github.com/Eric-hhaip/fast-shell/releases), unzip it, and drag `Fast Shell.app`
into your Applications folder.

If Gatekeeper blocks the first launch (the build is self-signed and not notarized by Apple):

```bash
xattr -dr com.apple.quarantine "/Applications/Fast Shell.app"
```

> Requires macOS 12+ on Apple Silicon or Intel.

---

## Screenshots

**Main window** — terminal, SFTP browser and server monitoring side by side, so daily ops happen in one window:

![Main window: SSH terminal + SFTP + server monitoring](docs/screenshots/main-window.png)

**New connection**:

![New connection dialog](docs/screenshots/connection-editor.png)

---

## Why this exists

Day-to-day ops usually means bouncing between a terminal app, a file transfer app, and a third window
where you SSH in just to run `top`. Fast Shell folds all three into one native macOS window: connect to a
host and you get the terminal on the left, files in the middle, and monitoring one click away. All
connection details are encrypted locally and never leave your machine.

---

## Features

### 1. Connection management
- Create, edit and delete connections: name, category, host, port, username, notes
- Authentication: password or private key (pick a key file, or paste the key contents; passphrase supported)
- **Host key verification**: the SHA256 fingerprint is shown on first connect and stored once you trust it;
  any later change raises a red warning, guarding against man-in-the-middle attacks
- Category management: the built-in "Default" cannot be deleted; other categories can be added or removed,
  and connections inside a deleted category fall back to "Default"
- Collapsible categories, keyword search, right-click menu (open / edit / duplicate / copy `ssh` command /
  clear host key / delete)
- Quick connect: type `user@host:port` in the search box or hit `⌘T` to open a throwaway session
- Recent connections: jump back to frequently used hosts from the welcome screen

### 2. Terminal
- Multiple concurrent sessions in tabs, each tab showing the connection name and live status
- 256-colour / true-colour rendering, 10,000 lines of scrollback, automatic `pty-req` on resize
- Function key bar: `Esc` / `Tab` / `Ctrl+C` / `Ctrl+D` / arrow keys
- Disconnect notice with one-click reconnect, live font size adjustment
- **Logs are never truncated**: the terminal renders a character grid (xterm) and only paints the visible
  region, so arbitrarily long output never drags the UI down

### 3. Server monitoring (`⌘⇧M`)
- Host overview: hostname / kernel / distro / uptime / load
- CPU total and per-core curves, memory and swap, disk usage bars per mount point, live network throughput
- Top processes by CPU (PID / user / command / usage)
- **Docker container management**: list (name / image / state / memory / network I/O) with start, stop,
  restart, delete and log viewing
- Full-screen container logs with follow-scroll — also never truncated
- **Prefetches the first sample in the background** right after connecting, so opening the panel shows data
  immediately instead of waiting out a cold start
- Polling pauses automatically when the app goes to the background and resumes on return, so it never burns
  CPU behind your back

### 4. SFTP file transfer (`⌘⇧F`)
- **Directory tree**: the whole filesystem as a lazily expanded tree on the left (click to jump, current
  directory highlighted, collapsible)
- **View / edit file contents**: click a file to see it (UTF-8, 1 MB limit with an explicit truncation
  notice, binary files flagged). Edits can be saved back to the remote host, with a confirmation prompt if
  you leave unsaved changes
- Directory browsing: breadcrumb path, parent directory, home directory, toggle for dotfiles
- Upload: multi-select files, whole folders, or **drag and drop onto the panel**; right-click a directory to
  "upload file here" as well
- Download: files land in `~/Downloads` by default (the one location the sandbox guarantees write access to,
  saving a panel round-trip). Right-click offers "Download to…", which probes the chosen directory with a
  real write before using it and falls back to `~/Downloads` with a notice if it is not writable
- Downloads use a temp file plus an atomic rename: a cancelled or failed transfer leaves no half-written
  file and never clobbers an existing file of the same name
- Right-click menu: view contents / edit file / download to `~/Downloads` / download to… / rename / new
  folder / copy path / delete (directories deleted recursively)
- Transfer queue: progress bars, live speed, two parallel tasks, cancellable (a cancel cleans up the partial
  file), with the failure reason shown
- Transfer records **never disappear on their own**: clear them per row; failed rows keep their red error
  message, successful rows offer "Reveal in Finder"
- Streaming UTF-8 decoding, so multi-byte characters are never mangled by TCP segmentation

### 5. Security and privacy
- Connection details (including passwords and private keys) are encrypted at rest with **AES-256-GCM**
- The encryption key is derived via HKDF from a random master key file (mode 600) plus the machine hardware
  UUID — copying the config to another machine makes it undecryptable
- Everything stays local. No network uploads, no telemetry, no accounts

---

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘ N` | New connection |
| `⌘ T` | Quick connect |
| `⌘ R` | Reconnect current session |
| `⌘ ⇧ M` | Toggle server monitoring |
| `⌘ ⇧ F` | Toggle file panel |
| `⌘ K` | Clear terminal display and scrollback |
| `⌘ C` / `⌘ V` | Copy selection / paste into terminal |
| `⌘ +` / `⌘ -` | Increase / decrease terminal font size |
| `⌘ W` | Close current tab |
| `⌘ ,` | Settings |

---

## Build and run

### Requirements
- macOS 12+ (Apple Silicon or Intel)
- Flutter 3.47+ (Dart SDK `^3.13.5`)
- Xcode Command Line Tools

### Steps

```bash
git clone https://github.com/Eric-hhaip/fast-shell.git
cd fast-shell

flutter pub get

# Development run (hot reload)
flutter run -d macos

# Pure-Dart self-check (84 assertions, no GUI required)
dart run tool/verify.dart

# Static analysis
flutter analyze

# Release build (the recommended path: strips symbols and inspects the bundle)
tool/build_release.sh
# equivalent to:
# flutter build macos --release --split-debug-info=build/symbols
# output: build/macos/Build/Products/Release/Fast Shell.app
```

### Gatekeeper blocks the first launch

A locally self-signed `.app` is not notarized by Apple:

```bash
xattr -dr com.apple.quarantine "build/macos/Build/Products/Release/Fast Shell.app"
```

### Rendering backend

Starting with Flutter 3.47, macOS defaults to the **Impeller** renderer. This project hit diagonal streaking
artifacts under it, so Impeller is explicitly disabled in `macos/Runner/Info.plist` to fall back to Skia:

```xml
<key>FLTEnableImpeller</key>
<false/>
```

If Impeller works fine on your machine, remove that key to get better compositing performance.

### Sandbox configuration

The required capabilities are already declared in `macos/Runner/*.entitlements`. Read this before changing them:

| Entitlement | Purpose |
| --- | --- |
| `com.apple.security.network.client` | Outbound SSH connections (required) |
| `com.apple.security.files.user-selected.read-write` | Uploading / downloading files the user picks in a panel |
| `com.apple.security.files.downloads.read-write` | Default download directory (**the safety net for downloads — do not remove**) |
| `com.apple.security.files.home-relative-path.read-only: ~/.ssh/` | Reading private keys without a manual file picker |

> **Note**: on macOS `file_picker` only returns a path string and does **not** retain a security-scoped
> bookmark for the returned directory. Inside the sandbox, writing into a user-selected directory can
> therefore be refused by the system. That is why downloads default to `~/Downloads` and why a custom
> location is write-probed first.

### Publishing a release

Installers are distributed through GitHub Releases (mirrored to CNB). One command does everything —
tag, build, package, create the release, upload the asset:

```bash
GITHUB_TOKEN=<pat> tool/publish_github.sh 1.1.0
# with release notes kept under version control in docs/releases/:
GITHUB_TOKEN=<pat> tool/publish_github.sh 1.1.0 --notes docs/releases/v1.1.0.md
# re-upload without rebuilding:
GITHUB_TOKEN=<pat> tool/publish_github.sh 1.1.0 --skip-build
# update the description only, leaving the build and asset untouched:
GITHUB_TOKEN=<pat> tool/publish_github.sh 1.1.0 --notes-only --notes docs/releases/v1.1.0.md
```

Create the token at <https://github.com/settings/tokens> — a classic PAT with the `repo` scope, or a
fine-grained PAT limited to this repository with **Contents: Read and write**.

The script pushes the code first. If the git protocol to `github.com` is blocked on your network, it
automatically falls back to `tool/push_github_api.py`, which replays the local history through the REST
API (blob → tree → commit → ref) and reproduces byte-identical commit SHAs.

`tool/publish_release.sh` publishes the same artifact to the CNB mirror (`CNB_TOKEN` with
`repo-release:rw`). Its asset upload is a three-step protocol — request a pre-signed COS URL, `PUT` the
file straight to object storage, then call the returned `verify_url` to confirm; skip that last step and
the asset stays in an "uploaded but invisible" limbo.

---

## Where data lives

| What | Path |
| --- | --- |
| Encrypted config (connections + settings) | `~/Library/Containers/com.hhaip.hhaipShell/Data/Library/Application Support/com.hhaip.hhaipShell/vault.enc` |
| Master key (mode 0600) | `vault.key` in the same directory |

> Deleting `vault.key` makes existing connection configs undecryptable (the app backs the damaged file up as
> `vault.enc.corrupt-*` and resets).

---

## Code structure

```
lib/
├── main.dart                    # Entry point: runApp first, then async vault init (shorter blank screen)
├── models/
│   ├── app_settings.dart        # App settings (font size, category list, ...)
│   ├── connection.dart          # Connection model + serialization
│   ├── remote_entry.dart        # Remote directory entry
│   └── transfer_task.dart       # Transfer task (progress / speed / state)
├── services/
│   ├── vault.dart               # AES-256-GCM local vault (HKDF + machine UUID)
│   ├── ssh_session.dart         # SSH session + SFTP channel wrapper + streaming UTF-8 decoding
│   ├── monitor_service.dart     # Remote metric collection (CPU/memory/disk/network/process/containers)
│   ├── local_io.dart            # Downloads directory / write probe / reveal in Finder / error translation
│   ├── log_text.dart            # Pure log-text helpers (sanitize / line count), independently testable
│   └── remote_path.dart         # Remote path utilities
├── state/
│   ├── app_store.dart           # Global state: connections / tabs / transfers / SFTP / settings
│   └── monitor_state.dart       # Per-tab monitoring state: polling / curves / containers / logs
└── ui/
    ├── home_page.dart           # Main frame: sidebar + tab strip + workspace + global shortcuts
    ├── sidebar.dart             # Connection list (search / categories / context menu)
    ├── connection_editor.dart   # Connection editor dialog (with category management)
    ├── terminal_panel.dart      # Terminal view + toolbar + function key bar
    ├── monitor_panel.dart       # Server monitoring + Docker containers + full-screen logs
    ├── sftp_panel.dart          # File panel (tree / view / edit / upload / download)
    ├── transfer_bar.dart        # Transfer queue
    ├── settings_dialog.dart     # Settings
    ├── quick_connect.dart       # Quick-connect parsing
    ├── theme.dart               # Colours / theme / terminal palette
    └── widgets/common.dart      # Shared widgets and dialogs
tool/
├── verify.dart                  # Pure-Dart self-check (84 assertions), CI-friendly
├── build_release.sh             # Standard release build (strip symbols + inspect bundle)
├── publish_github.sh            # Publish to GitHub Releases (push + release + upload asset)
├── push_github_api.py           # Mirror git history to GitHub over the REST API (no git push)
├── publish_release.sh           # Publish to the CNB mirror (package + create release + upload asset)
├── sftp_smoke.dart              # SFTP smoke script
└── gen_logo.py                  # App icon generator (pure-Python SDF antialiasing)
```

---

## Performance notes

The project goes out of its way to stay smooth when left running for days:

- **The terminal does not render line-by-line `SelectableText`** — it uses xterm's character grid, painting
  only the visible region, so scrollback depth has no effect on frame rate
- **Monitoring curves** are hand-drawn with `CustomPainter` and a precise `shouldRepaint`, avoiding needless
  repaints every frame
- **Log refresh is data-driven**: the terminal notifies on change and refreshes a small region at a 250 ms
  throttle instead of rebuilding the whole page
- **Repaint isolation**: the terminal, log pane and curves each sit inside their own `RepaintBoundary`
- **Polling pauses in the background**: all remote sampling stops while the app is unfocused or minimised
- **Tabs are disposed after the frame**: the UI is notified first, then `dispose` runs after the render
  frame, preventing the render tree from being torn down mid-frame (which caused leftover artifacts)
- **Lean bundles**: unused font dependencies removed, `--split-debug-info` strips debug info, and the release
  script lists the bundle contents and checks that no `*.dart` / `*.dSYM` / `tool` / `test` slipped in

---

## Branding

- Product name: **Fast Shell**
- Icon: generated by `tool/gen_logo.py` (pure-Python SDF antialiasing), written into
  `macos/Runner/Assets.xcassets/AppIcon.appiconset/`; the in-app copy lives at `assets/logo.png`

---

## Known limitations

- macOS desktop only for now (a Windows build needs `flutter create --platforms=windows` plus window config)
- No SSH Agent (`SSH_AUTH_SOCK`) support, no ProxyJump bastion hosts, no port-forwarding panel
- Uploads and downloads stream in 256 KB chunks with byte-based progress; no resume support yet
- In-place file editing is capped at 1 MB (it tells you instead of silently truncating)
- Metric collection relies on common remote commands (`/proc`, `df`, `ps`, `docker`), so exotic distros may
  report some metrics as empty

---

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Please make sure these pass before submitting:

```bash
dart run tool/verify.dart   # all 84 assertions green
flutter analyze             # no warnings or above
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © hhaip
