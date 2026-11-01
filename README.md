# DropQuick for iPhone & iPad

Native SwiftUI / iOS 26+ app with real Liquid Glass controls. Share files with Android's existing Quick Share over the same local network. No Android companion app, phone number, account or cloud service is used. **Initial experimental iOS port; physical Android interoperability has not yet been validated.**

## What is implemented

- Quick Share LAN discovery, UKEY2 handshake, AES-256-CBC + HMAC-SHA256 transport, send and receive, PIN display and explicit receive consent. Adapted from [NearDrop](https://github.com/grishka/NearDrop), Unlicense.
- Everyone visibility for ten minutes; advertisement stops when the app enters background. App must stay open for transfers.
- Android QR activation using `https://quickshare.google/qrcode#key=…` when ordinary discovery doesn't find a receiver. On Android also open Quick Share → Receive and set Everyone visibility. Same LAN is required.
- Native files picker, streaming photo/video import, text notes, previews, system share/AirDrop sheet, local transfer history with retained file copies.
- A real iOS Share Extension: copies attachments, discovers Quick Share receivers and sends directly inside the share sheet, including PIN and QR activation. Files are also staged in the shared outbox for the main app. No private extension-to-app launch tricks.
- Explicit, ten-minute browser fallback for Windows/Android without installing anything: download selected files or upload files up to 50 MB each. This is local **HTTP, not encrypted**. Use only on a trusted LAN. The random link authorizes access; anyone with it can download/upload. Imported uploads are never executed or opened automatically.

## Compatibility — read before installing

| Target | Transport / status |
| --- | --- |
| Android / Samsung Google Quick Share | Implemented unofficial LAN protocol; same Wi-Fi and receiver visibility/Receive screen, QR activation may be needed. Not yet physical-device tested. |
| Windows Google Quick Share | Same unofficial protocol may interoperate; not verified. |
| Windows built-in Nearby Sharing | **Not implemented.** It uses MS-CDP/NearShare, a different protocol. Browser fallback is separately labelled. |
| Windows/Android browser | No installation; explicit local HTTP portal, same Wi-Fi. |
| Apple / AirDrop-compatible Android | iOS system sharing sheet; actual compatibility belongs to the OS and Android model. No private AirDrop API. |
| Bluetooth-only / Wi-Fi Direct | Not implemented. iOS does not expose the necessary arbitrary advertising / generic Wi-Fi Direct interfaces for this protocol. |

Guest Wi-Fi client isolation, VPNs, firewalls and Android firmware can affect discovery. Wi-Fi Aware is not a drop-in Quick Share transport. No contacts-only Google account impersonation, no automatic trusted-device acceptance, and no always-on background reception.

## Download an IPA

[GitHub Actions](https://github.com/Robin9094707/DropQuick/actions/workflows/ios.yml) builds and tests the app on macOS/Xcode 26 and uploads `DropQuick-1.0.0-unsigned-IPA`. Open a successful run → Artifacts. Version tags also attach the IPA to a GitHub Release.

The IPA is **unsigned**, for re-signing/sideloading, not direct installation by tapping it. A device-valid signature/provisioning profile is required. Preserve the Share Extension and assign the **same App Group entitlement** to both targets; otherwise share-extension imports/history cannot reach the main app; direct sending from the extension still works. App Groups require appropriate Apple provisioning. In-app file/photo selection still works if the re-signer cannot provision App Groups. No Apple certificate or account credentials are included in the repository.

## Build locally

Requires macOS, Xcode 26+, Homebrew XcodeGen.

```sh
brew install xcodegen
xcodegen generate
open DropQuick.xcodeproj
```

Choose your signing team for both app and extension and enable App Groups. The identifier is `group.eu.simplexsmp.dropquick`; adjust both targets and `StoragePaths.groupID` together if your team uses another group. The generated project is intentionally not checked in; `project.yml` is the source of truth.

CI runs XCTest mini tests for endpoint metadata, malformed packets, path traversal, HKDF RFC5869, PINs, history and HTML escaping, then makes a Release device build. These tests **do not prove Android/Windows interoperability**. See [device test checklist](docs/DEVICE_TESTS.md).

## Data

Files and history remain in the app / shared container. History is capped at 500 entries. Removing a history entry leaves retained files intact; uninstalling removes app-local data. Browser access expires after ten minutes or when the app goes to background. Never expose the portal to the Internet. No telemetry or remote backend.

See [research and platform constraints](docs/RESEARCH.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
