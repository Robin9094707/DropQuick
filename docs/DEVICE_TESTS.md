# Physical-device acceptance tests

Not performed by CI. Record the iPhone/iOS build, Android model/Play Services version and Windows version for each test.

1. Sign app and Share Extension with matching App Groups. Import PDF, photo, video, URL and text via the iOS share sheet, then open DropQuick. Verify file contents, original names, multiple attachments and no duplicates.
2. Same LAN: open Android Quick Share Receive, Everyone for ten minutes; choose a small text file in DropQuick. Verify discovery, PIN equality, accept/reject, byte-identical content. Repeat using QR activation.
3. Send a zero-byte file, multi-file batch, 200 MB video, Unicode names and two files with the same name from separate folders. Check progress, cancellation, disk usage and Android content hashes.
4. Turn on iOS visibility. Send from Android. Test accept, reject, 60-second expiry, truncated transfer, partial-file cleanup, duplicates and incoming URL stored as text without opening.
5. Leave the app and wait ten minutes separately: no further incoming advertisements. Reopen, re-enable visibility and repeat reception.
6. Browser on Windows: same LAN, scan/type URL, download original files, upload two files below 50 MB. Verify hashes. Stop sharing: link must fail. Repeat foreground → background and ten-minute expiry.
7. Browser robustness: wrong token, invalid Content-Length, encoded traversal filename, HTML in filename, oversized body, slow/stalled request. Never save outside the receive directory.
8. Disable local-network permission, use isolated guest Wi-Fi, disconnect Wi-Fi and retry. Errors should be recoverable. Native Windows Nearby Sharing is NOT an acceptance target for this version.
9. Try Google Quick Share for Windows as a separate, unverified interoperability target. Do not confuse it with Windows Nearby Sharing.
