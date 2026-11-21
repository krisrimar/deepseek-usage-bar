# DeepSeek Usage Bar

A macOS menu bar app for DeepSeek. The dot shows peak or off-peak rates right
now; the title can also show balance, time left and today's spend, and the
popover adds a spend chart and per-model usage. macOS 13 or later.

## Credentials

Both are entered in **Settings** and stored in the macOS Keychain:

- **`sk-…` API key** — `api.deepseek.com` → API keys. Reads the balance.
- **Platform `userToken`** — `platform.deepseek.com` → DevTools → Local Storage.
  Reads usage and spend.

They are different credentials, and neither works in place of the other.

## Install

```sh
curl -fsSL https://github.com/krisrimar/deepseek-usage-bar/releases/latest/download/install.sh | sh
```

Updates live in **Settings → Updates**.
