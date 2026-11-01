DropQuick 1.0.1 fixes device discovery and visibility reporting.

- Real CoreBluetooth scanning with the iOS Bluetooth permission prompt; detects Quick Share Fast Initiation service-data beacons, not arbitrary Fast Pair accessories. BLE hints trigger a fresh LAN search, not fake send targets.
- Native NWListener Bonjour service advertisement with registration callbacks. The UI only confirms visibility after Bonjour registration succeeds.
- Local Network policy-denied / waiting diagnostics, settings shortcut, explicit search retry and foreground restart.
- Bluetooth and advertisement/permission states visible in app. Files still transfer over the same local Wi-Fi; iOS cannot emit the arbitrary Android wake-up advertisements. Open Android Quick Share Receive or use QR activation.

Unsigned IPA: re-sign for your iPhone. Preserve matching App Groups for app + Share Extension. Bluetooth permissions and Android interoperability require physical devices; simulator tests cannot prove those.
