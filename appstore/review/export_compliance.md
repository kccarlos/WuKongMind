# Export Compliance

App Store Connect › Build Export Compliance (also declared in `WukongMind/Info.plist`).

- **Does your app use encryption?** Standard Apple OS encryption only (exempt).
- **Uses non-exempt encryption (`ITSAppUsesNonExemptEncryption`):** `No` (`false` in `WukongMind/Info.plist`).
- **Basis:** The app uses only standard system HTTPS/TLS (`URLSession` and `WKWebView`), Apple CloudKit, iOS Keychain, and Apple CryptoKit hashing. No custom or proprietary cryptography is implemented or bundled.
