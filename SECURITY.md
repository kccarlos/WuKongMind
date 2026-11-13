# Security Policy

WukongMind is a personal, self-use open-source browser for iOS and iPadOS, built from source and not distributed on the App Store.

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities. Report them privately through GitHub Security Advisories:

- <https://github.com/kccarlos/WuKongMind/security/advisories/new> (**Security** › **Report a vulnerability**)

Include steps to reproduce and the concrete impact. Reports are reviewed and fixed on the `main` branch on a best-effort basis.

## Threat model and scope

Before reporting, review the [Risk Statement in README.md](README.md#risk-statement). By design, the browser agent runs unrestricted JavaScript (`run_js`) inside the active `WKWebView` session with no confirmation prompts by default. Untrusted page text steering the model (prompt injection) is an inherent risk of that design rather than a bug on its own — do not sign in to banking, payment, or primary email accounts in WukongMind.

**In scope (documented safety boundaries):**

- Bypassing isolated-world bridge separation (`WKScriptMessageHandlerWithReply` in an isolated `WKContentWorld`) so a web page script can invoke native tools or spoof tool results
- Leaking provider API keys from Keychain into page JavaScript contexts, conversations, tool outputs, or logs
- Triggering unintended actions through external `wukongmind://` deep links or share hand-offs, or leaking cookies across origins in native HTTP helpers
- Weaknesses in optional CloudKit payload encryption or repository build/release scripts

**Out of scope:** Vulnerabilities in third-party websites, AI model providers, or iOS/WebKit itself.
