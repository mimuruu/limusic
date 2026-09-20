# Limusic Remote

An Android remote control for [Limusic](https://github.com/SimoHypers/limusic), the desktop YouTube
Music client. Play, pause, skip, seek, change volume, browse the queue and search — from your phone,
without getting up.

This app is the companion to the **Phone remote** feature added in this fork (see
`../src-tauri/src/remote.rs` and the Settings → Phone remote tab). It talks to that API over your
local network; both devices just have to be on the same WiFi.

> **Part of a fork.** This directory and the phone-remote API in `../src-tauri/` are additions to
> SimoHypers/limusic, which is GPL-3.0. Upstream does not have this feature.

## How it works

```
Phone (this app)  --HTTP/JSON-->  Limusic desktop  -->  YouTube Music
                  same WiFi        (LAN listener)
```

Nothing goes through the internet and there is no Limusic account involved: the phone sends commands
to your computer, and your computer plays the music.

## Setting it up

**On the computer (once):**

1. Open Limusic → **Settings → Phone remote**.
2. Turn it on. The panel shows an address like `http://192.168.1.5:4317` and the port.
3. Press **New code** to get a 6-digit pairing code. It is valid for 5 minutes and works once.

**On the phone (once):**

1. Install `LimusicRemote.apk`.
2. Enter the address from step 2, then press **Check connection**.
3. Enter the 6-digit code and give this phone a name, then press **Pair**.

After pairing, the token is saved and the app opens straight to the remote. To unpair, use
*Disconnect* in the app, or revoke the device from Limusic's Phone-remote settings.

## What it can do

| Screen | Actions |
| --- | --- |
| **Playing** | Play/pause, next, previous, seek, volume, shuffle, repeat (off/all/one) |
| **Queue** | See what's next, tap to jump to a track, swipe to remove |
| **Search** | Search YouTube Music, tap a result to play it on the desktop |

## Security

The remote listens on your LAN, so a token is what keeps other devices out.

- Pairing needs the 6-digit code shown on the computer. It is single-use and expires after 5 minutes.
- Each phone gets its own token, stored on the computer as a SHA-256 digest — a copy of the
  database yields no usable credential.
- **Paired devices** in Limusic lists every phone; revoking one kills its token immediately.
- The remote cannot read your YouTube session, change settings, or touch your account. It can play
  music, and that is all.
- Cleartext HTTP is allowed only for private network addresses (`network_security_config.xml`).

Leave the remote **off** on networks you don't trust — anyone who reaches the address and has a
paired token can control playback.

## Beyond the home network

The app is built for "same WiFi". Reaching it from outside the house is possible, but it is a
deliberate step, not a toggle — and the options are not equal.

| Approach | Install on phone | Encrypted | Opens your home IP |
| --- | --- | --- | --- |
| **Tailscale** (recommended) | yes, one app | yes | no |
| **Cloudflare tunnel** + a browser page | no | yes | no |
| Port forward | no | **no** | **yes** |

**Why port forwarding is the one to avoid.** It is the easiest to set up, which is exactly the
problem: the API speaks plain HTTP, so the token crosses the network in the clear, and an open port
publishes your home IP to every scanner on the internet. The music being controllable is the least
of it — the same port is a foothold for probing everything else on the network. If you do it anyway,
put it behind a reverse proxy that terminates TLS, and never on a shared or public network.

**Tailscale** makes the two devices act as if they were on one LAN: install it on both, sign in with
the same account, then use the `100.x.y.z` address in the app instead of the `192.168.x.y` one.
Nothing in this app changes — it is still just an address.

## If your WiFi changes

The desktop does not care: the listener binds every interface, so it survives a new IP, a switch to
Ethernet, or a brief disconnection without a restart.

The **phone** does care. It stores the address you typed, and that address stops being right the
moment the computer gets a new one. To fix it: **Disconnect** in the app, then enter the new address
and pair again with a fresh code. Find the new address in Limusic's Phone remote panel.

## Connection problems

| Symptom | Cause |
| --- | --- |
| "Not a Limusic remote" | Wrong address or nonstandard port. Copy it from the settings panel. |
| "Cannot reach the desktop" | Different network (guest WiFi, VPN, mobile data), or a firewall blocking the port. |
| "This phone is no longer paired" | The device was revoked on the computer. Pair again with a new code. |
| Nothing on the Playing tab | Nothing is playing on the desktop yet — play something, or use Search. |

## Building

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```

Requires Flutter 3.47+ and JDK 17. `flutter doctor` should show the Android toolchain as OK.

### Windows notes

Two settings here differ from a stock `flutter create`, both worked around rather than fixed:

- **`kotlin.incremental=false`** in `android/gradle.properties`. Kotlin's incremental cache kept
  failing to close with "Could not close incremental caches" when the project and the caches sat on
  different drives. Disabling it costs a full recompile of two small plugins per build.
- **The desktop build needs Developer Mode on.** The `v8` crate the desktop's BotGuard needs creates
  a symlink whenever its source and cargo output are on different drives, and Windows refuses that
  without it. Keeping `CARGO_HOME` and the `target/` directories on the same drive avoids the
  symlink entirely.

If a build misbehaves after moving directories: `flutter pub get` regenerates
`.dart_tool/package_config.json`, which hard-codes the Flutter SDK path. Deleting `build/` and
`android/.gradle/` clears stale Gradle state. For the desktop, a stale `target/debug/gn_root`
symlink pointing at a path that no longer exists also breaks the build — deleting it (and
`target/debug/build/v8-*`) makes cargo recreate it correctly.

## Layout

| File | Purpose |
| --- | --- |
| `lib/api.dart` | HTTP client for the Limusic remote API, plus the JSON models |
| `lib/store.dart` | Persists the server address and device token |
| `lib/main.dart` | The pairing screen and the remote (playing / queue / search) |

## License

GPL-3.0-or-later, matching Limusic.
