# Protocol research — 1 November 2026

Primary sources used:

- https://github.com/grishka/NearDrop — Swift send/receive implementation, Unlicense. Vendored at commit `add655c6c5a40b9ba03c0329b598f2817185f5a9`; this is a downstream iOS app, not an upstream contribution.
- https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md — service `_FC9F5ED42C8A._tcp`, endpoint metadata, Nearby Connections frames, UKEY2, SecureMessage, payload transport, QR activation. A copy is included here.
- https://github.com/Medformatik/CrossDrop — another experimental iOS/LAN implementation and a useful independent description of Apple advertising limitations.
- https://github.com/google/nearby — Google's source code is available, but Nearby Connections APIs do not by themselves expose a public universal Quick Share service. The sharing-specific introduction/consent/authentication layer still matters.
- https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:) — only local-name and service-UUID keys are accepted for app advertising; arbitrary BLE manufacturer/service-data payloads cannot simply be emitted.
- https://developer.apple.com/documentation/wifiaware — Wi-Fi Aware exists on newer iOS; it requires its own service/pairing contract and is not evidence of compatibility with stock Android Quick Share.
- https://www.android.com/intl/de_de/quick-share/with-iphone/ — AirDrop interoperability on supported Android hardware; use the system sharing UI for this route.
- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cdp/f5a15c56-ac3a-48f9-8c51-07b2eadbe9b4 — Microsoft CDP specification. It is separate from Google Quick Share.
- https://github.com/nearby-sharing/android — GPL-3.0 .NET/Android CDP/NearShare implementation. Not vendored. Porting its transport/session/security/application layers into Swift is outstanding; no pretend Windows sender is exposed in the UI.

## iOS-specific changes to the vendored protocol

Replaced macOS Host/AppKit/downloads with app naming and sandboxed storage. Added visibility stop/restart, serial consent handling, request expiry, bounds and payload checks, file-name validation, duplicate destination checks, no automatic URL execution, file completion callbacks, and local UI/history integration. Protobuf-generated code is retained unmodified. Protocol transport remains unofficial and requires physical-device validation.

## Why the Windows fallback is explicit

Windows native Nearby Sharing requires a working CDP discovery, authentication, session/channel and NearShare transfer implementation. Sharing a Bonjour name or HTTP server does not implement CDP. DropQuick therefore says "Browserfreigabe" for this path. The browser portal is useful without a Windows installation, but does not satisfy native Windows Nearby Sharing discovery.


1.0.1 references: Apple TN3179 documents NWBrowser waiting with DNS -65570 and explains that the simulator does not implement iOS Local Network privacy. Chromium Fast Initiation constants identify FE2C with service-data model ID FC128E plus metadata: https://github.com/chromium/chromium/blob/9269d4ed0dde3bcd3837f75a50a2944674555186/chrome/browser/nearby_sharing/fast_initiation/constants.h . BLE hints do not supply a TCP endpoint. The app does not advertise custom BLE data.
