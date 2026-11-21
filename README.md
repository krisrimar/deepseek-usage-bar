# DeepSeek Usage Bar

A macOS menu bar app showing DeepSeek balance, per-model usage, and — the point
of the thing — whether you are currently paying **peak or off-peak rates**.

Off-peak is exactly half price, so the single most useful thing to know before
sending a large request is which tier you are in right now.

```
 ● 2h14m        green dot = off-peak, orange = peak
```

The dot is not configurable — it is the point of the app. The text beside it
is, from the **Menu bar** checkboxes in Settings (the gear beside the popover
title):

| | |
|---|---|
| Balance | total remaining, topped up plus granted |
| Time left | until the current peak or off-peak period ends |
| Spent today | today's spend across every model |

Any combination, joined with `·` in that order, e.g. `● $12.34 · 2h14m · $0.28`.
Unchecking all three leaves the dot alone. An item with nothing to show yet is
skipped rather than rendered as a dash; if that leaves nothing at all the
countdown stands in, since it is clock arithmetic and cannot be unavailable.

All three at once makes for a wide title (`$12.34 · 32h12m · $0.28`) — and on a
menu bar that is already full, macOS will push the item into its overflow
chevron rather than shrink it. One or two read more comfortably.

Modelled on [ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar), but
the two services bill differently, so it is not a port.

## Install

**Recommended, from Terminal:**

```sh
curl -fsSL https://github.com/krisrimar/deepseek-usage-bar/releases/latest/download/install.sh | sh
```

`install.sh` downloads the latest universal `.app`, checks it against the
release's SHA-256, puts it in `/Applications` (or `~/Applications` when
`/Applications` is not writable), clears the quarantine flag and opens it.
Nothing needs `sudo`. The script is attached to every release, so you can read
it before running it.

**By hand:** download `DeepSeekUsageBar-macos-universal.dmg` from the
[latest release](https://github.com/krisrimar/deepseek-usage-bar/releases/latest),
open it and drag the app to Applications. The builds are ad-hoc signed rather
than notarized, so a copy downloaded through a browser carries the quarantine
flag: the first launch needs right-click → Open, or clear it yourself:

```sh
xattr -dr com.apple.quarantine /Applications/DeepSeekUsageBar.app
```

macOS 13 or later, Apple silicon or Intel (the build is universal).

## Updating

**Settings → Updates** asks GitHub for a newer release on launch — at most once
a day, and silently if GitHub cannot be reached. When one is available, a badge
appears in the popover header. **Install** downloads it, checks it against the
published SHA-256 and the bundle identity inside it, then swaps the app and
relaunches. Nothing is installed without that click, and the automatic check can
be turned off in the same section.

Because the builds are ad-hoc signed, macOS may ask once after an update whether
the new build may read the credentials the old one saved in your Keychain.
Allow it — the credentials are the same, only the signature on the binary
changed.

## Spend over time

Below the balance the popover charts **one bar per day**, over whichever of
three windows is selected:

| | |
|---|---|
| 7 days | the last week, including today |
| 30 days | the last month, including today |
| This month | from the 1st up to and including today |

The figure above the chart is the window's total. Hovering a bar reports that
day's own spend, its request count, and marks a "≥" when any part of it had to
be worked out from the rate table rather than taken from DeepSeek's own
figure. The bar under the cursor is picked out from the rest; with nothing
hovered the line reads as a summary — busiest day and average per day.

The average divides by **every** day in the window, not only the days with
traffic, so one busy afternoon cannot stand in for a quiet fortnight.

**The bars are not split by rate tier, and that is deliberate.** A daily bucket
spans both peak and off-peak hours and belongs to neither, so there is no
honest split to show — the same reason the app declines to split them below.
The tier split needs hourly buckets, which only a one-day window returns. That
is why the popover makes two calls to the same endpoint rather than one: a
one-day window for the tier attribution, and a wide one for the trend.

The window is fetched only while the popover is open, and is reused for a
minute afterwards, so opening and closing it repeatedly does not re-fetch.

## Peak / off-peak

DeepSeek bills peak rates only during two windows on genuine Chinese working
days. Everything else is off-peak.

**Peak: Mon–Fri, `01:00–04:00` and `06:00–10:00` UTC** (= `09:00–12:00` and
`14:00–18:00` Beijing), excluding Chinese public holidays. Weekends are
entirely off-peak, **including official make-up workdays** (调休) — those are
weekend days turned into workdays, and DeepSeek bills them off-peak anyway.

In Vienna that is:

| | CEST (summer) | CET (winter) |
|---|---|---|
| Peak | 03:00–06:00, 08:00–12:00 | 02:00–05:00, 07:00–11:00 |

The app computes in UTC and renders in your local zone, so DST takes care of
itself. Source: [DeepSeek pricing docs](https://api-docs.deepseek.com/quick_start/pricing).

> **Note:** 8 AM–12 PM Vienna is *peak*, not off-peak. If you were timing work
> to avoid peak rates, that window was the wrong one.

The popover does not only say which tier you are in, it says which rule put you
there — because the three ways to be off-peak differ in what they mean for what
comes next:

| | |
|---|---|
| `Half price — a working day, outside both peak windows.` | an ordinary day; only the hour is off-peak |
| `Half price — weekends are off-peak all day, make-up workdays included.` | the whole day, and peak cannot return before Monday |
| `Half price — Mid-Autumn Festival, a Chinese public holiday.` | the whole day, with the holiday named |

It sits under the tier and beside the countdown, so the countdown never has to
be read backwards to answer "why". The same reason appears in the menu bar
item's tooltip, and as a `reason:` line in `Copy diagnostics`.

**A holiday that falls on a weekend is reported as the weekend, not the
holiday** — not merely precedence, but because a make-up workday is a weekend
day made into a working day and DeepSeek bills it off-peak anyway, so the
weekday settles it without the holiday table being consulted at all. The three
answers are the three ways the peak rule can fail, read back in the order the
tier itself is decided — weekday, then holiday, then window — so the
explanation is that decision described rather than a second opinion free to
disagree with it.

On a day with no peak at all — a weekend, or a holiday — the `Peak today:` line
reads `none`. Listing the clock's two windows under a line that has just said
the whole day is off-peak would contradict it.

Chinese public holidays live in `Holidays.swift` (`holidayPeriods`), grouped by
year and holding a rolling **two** years — this one and the next. Refresh when
the State Council publishes the next schedule, usually the preceding November:
add the new year's block, drop the oldest. Two years rather than one because the
countdown reads ahead into the following year during the last week of December.

If the table runs out the app says so, in the popover and in `Copy diagnostics`,
rather than going quiet. It keeps reporting the tier from the weekday and the
window: a holiday missing from the table reads as a working day, which
overstates cost rather than understating it — and that is the direction worth
failing in.

## Two credentials, and they are not interchangeable

| Data | Endpoint | Credential |
|---|---|---|
| Balance | `api.deepseek.com/user/balance` | `sk-…` API key (official) |
| Per-model usage | `platform.deepseek.com/api/v0/usage/*` | platform `userToken` (private) |

Your `sk-` key **cannot** authenticate the dashboard endpoints. Enter it in
Settings (the gear beside the popover title) under **API key**, where it is
stored in the **macOS Keychain** and sent only to `api.deepseek.com` to read the
balance. The app does not read a key from the environment, from
`~/.claude-profiles`, or from anywhere else: the only key it uses is the one you
type into it.

For per-model usage, paste a platform token in the same window:

> platform.deepseek.com → DevTools (`Cmd+Opt+I`) → **Application** →
> **Local Storage** → copy the value of `userToken`

It is stored in the **macOS Keychain**, not a plist. It is a session credential
minted at sign-in, so it can stop being accepted at any time, and there is no
way to mint a replacement programmatically — re-logging in and copying it again
is the only recovery.

DeepSeek reports that as `40003 INVALID_TOKEN` **inside an HTTP 200**, never as
a 401: the console's own status enum has no separate "expired" code, so expiry
and a wrong value are indistinguishable. The app treats 40002/40003 as a refused
credential, drops the stored token, and asks you to paste a fresh one.

## Build and run

```bash
./app/build.sh          # for this machine
./app/build.sh --universal
open app/build/DeepSeekUsageBar.app
```

Requires the Xcode Command Line Tools. Uncomment nothing — see the toolchain
note at the top of `app/build.sh` for why SwiftPM is not used here and why the
UI state lives on `AppModel` rather than in `@State`.

## Install

`app/build/` is a scratch directory that `build.sh` wipes on every run, so the
bundle is meant to be copied somewhere permanent:

```bash
./app/build.sh
ditto app/build/DeepSeekUsageBar.app /Applications/DeepSeekUsageBar.app
open /Applications/DeepSeekUsageBar.app
```

`ditto` rather than `cp -R`: it preserves the bundle's metadata intact.

The bundle is ad-hoc signed, and because it is built locally it carries no
quarantine attribute, so Gatekeeper launches it without complaint. `CODESIGN_IDENTITY`
matters only when handing the `.app` to someone else.

This belongs in your login items — a usage monitor you have to remember to
start is not much of a monitor. Add it under **System Settings → General →
Login Items**, or:

```bash
osascript -e 'tell application "System Events" to make login item at end
  with properties {path:"/Applications/DeepSeekUsageBar.app", hidden:false}'
```

Preferences live in the `com.krisrimar.deepseek-usage-bar` defaults domain keyed
by bundle ID, so they survive a reinstall and a menu bar selection made from a
`app/build/` run carries over to the installed copy.

## Versioning

**`app/Info.plist` is the single source of truth.** `CFBundleShortVersionString`
is the version, `CFBundleVersion` the build number. The app reads both back from
its own bundle at runtime (`Version.swift`) rather than keeping a Swift constant
— a second copy is a second thing to bump, and the two drift.

The version surfaces in three places, all derived from that one key:

- the popover header, beside the title
- the `Copy diagnostics` block, so a bug report identifies its build
- `./app/build.sh` output, which also prints the `ditto` line to install

To release, bump `CFBundleShortVersionString` and `CFBundleVersion` in
`app/Info.plist`, add a matching heading to `CHANGELOG.md`, and rebuild.
`tests/run.sh` fails if the plist and the changelog's newest release heading
disagree, so the two cannot separate. The check is deliberately on the *newest*
release heading: `## [Unreleased]` carries no number and is skipped.

Outside an `.app` — the bare `app/build/DeepSeekUsageBar`, or the test binaries
— there is no Info.plist to read, and the app reports itself as `dev` rather
than as a version that looks real but is not.

## Tests

```bash
./tests/run.sh
```

A version/changelog agreement check runs first — it is instant, and a mismatch
should stop the run before the compiles start. Then six suites, 228 assertions:
the peak boundaries (every window edge to the
minute), weekend rules, all seven 2026 holidays and every bound of every range,
the make-up workdays, the table's coverage and when it has run out, that a
holiday is judged by Beijing's date rather than the viewer's, why each off-peak
moment is off-peak and that a weekend outranks a holiday falling on it, whether
a day has any peak at all and that a peak moment always implies one, DST
rendering in both directions, next-transition logic across a weekend, the
pricing maths, token normalisation, peak/off-peak attribution from hourly
buckets, menu bar composition and its stored-selection migration, the chart's
windows (the 1st of a month, a 31-day month, a week across the DST change),
folding a multi-day response onto one bar per day with the quiet days kept, and
a decode against a real captured response when one is present.

## Status

| | |
|---|---|
| Peak/off-peak indicator | **Working** — pure clock arithmetic, and it names the rule that decided the tier: the hour, the weekend, or which holiday. The shipped holiday table is flagged in-app once it runs out |
| Balance | **Working** — verified against the live API |
| Per-model usage and cost | **Working** — verified against the live API |
| Peak vs off-peak spend split | **Working** — exact, from hourly buckets |
| Spend chart — 7 days / 30 days / this month | **Working** — daily totals, not split by tier |

## The dashboard API

Observed 2026-09 from a real capture. Two endpoints, both needing the platform
userToken:

```
GET /api/v0/usage/by_api_key/amount?start=<unix>&end=<unix>&tz=<seconds>
GET /api/v0/usage/by_api_key/cost?start=<unix>&end=<unix>&tz=<seconds>
```

`tz` is the UTC offset in **seconds** (`7200` for CEST), not hours — it is
echoed back as the `x-client-timezone-offset` header, and the dashboard uses it
to decide which local day a bucket belongs to.

Both wrap their payload in `{code, msg, data: {biz_code, biz_msg, biz_data}}`.
`amount` returns `biz_data.series[]` of `{api_key, model, buckets[{time,
usage{REQUEST, PROMPT_CACHE_HIT_TOKEN, PROMPT_CACHE_MISS_TOKEN,
RESPONSE_TOKEN}}]}`; `cost` returns `biz_data.data[]` of `{currency,
series[...]}` with `buckets[{time, cost}]`. Cost figures are strings.

**Both bounds must sit on a whole hour and the span must be a whole number of
days** (a multiple of 86400 seconds), or the API refuses the request. The
refusal is easy to misread: HTTP 200, `code: 0`, with `biz_code: 1` and
`biz_msg: "INVALID_PARAM"` inside. Rolling windows (`now-1h .. now`) are
refused, and so is anything longer than 31 days.

Local `midnight .. midnight` normally satisfies both rules, which is what the
captured session showed — but not when the window straddles a daylight-saving
change. That day is 23 or 25 hours long, so a week that contains it spans 7
days and an hour, and the request is refused even though both ends are real
local midnights. `DeepSeekClient.serverWindow` keeps the end on local midnight
and moves the start to the nearest moment that makes the span whole days, which
costs at most one hour at the outer edge of the window's oldest day. That is
what makes the chart survive late October and late March.

**The bucket width scales with the window you ask for**, and the server reports
the width it chose in a `bucket` field (seconds):

| Window | bucket | Granularity |
|---|---|---|
| 19 days | `86400` | daily |
| 1 day | **`3600`** | **hourly** |

That is the finding the whole design turns on. Asking for exactly one day
returns hour-by-hour buckets, and each bucket's timestamp says which rate tier
it was billed at — so peak and off-peak spend can be separated exactly, rather
than estimated. The app requests `midnight today .. midnight tomorrow` for that
reason, and reads `bucket` back rather than assuming it.

Every range the chart can ask for is wider than a day, so those come back daily
too — but the chart does not rely on that. It folds buckets onto **local** days
whatever width they arrive at, so an hourly reply to a short window would still
land one bar per day rather than stacking twenty-four onto one date.

A daily bucket spans both tiers and belongs to neither, so the app declines to
split those rather than inventing a figure, and shows DeepSeek's own reported
cost instead. That is why the chart's bars are a single colour: there is no
tier attribution to colour them by.

`x-client-platform: web`, `x-client-version`, `x-client-bundle-id`,
`x-client-locale`, `Origin` and `Referer: https://platform.deepseek.com` are
all load-bearing; the dashboard rejects requests that do not look like its own
frontend.

## What the capture revealed about model names

Worth knowing, because it explains a puzzle this project started with. Requests
per day, by model:

| | Sep 1–9 | Sep 10 onward |
|---|---|---|
| `deepseek-v4-flash` | 229, 140, 87, 340, 350, 9, 36, 2 | 0 |
| `deepseek-flash` | 0 | 287, 59, 764, 1398, 469, 158, 2067, 413, 471, 2307 |

The switch is abrupt and lands exactly on Sep 10 — and the model catalog lists
`deepseek-v4.1-flash-expires-on-0910`. So the `deepseek-v4-flash` alias the
Claude Code profile still sends has been resolving server-side to
`deepseek-flash` since that date. The API echoes model names back verbatim, so
nothing in the transcripts would ever have shown this.

**`deepseek-v4-pro` is separate and real** — 402 requests across Sep 13–19,
clustered on days of heavy use, alongside the flash traffic. Nothing in the
Claude Code config names it. The client cannot explain it; the per-model panel
is how you watch it.

## Known limitations

- **Peak/off-peak cost cannot be split within a day** while the API returns
  daily buckets, since a day contains both tiers. The app sidesteps this by
  showing DeepSeek's own reported cost rather than deriving one — that figure
  is authoritative regardless of granularity.
- **The chart's bars are not split by tier either**, for the same reason.
  Splitting them would need one request per day — thirty calls for a month —
  which is not a trade worth making for a menu bar popover.
- The dashboard endpoints are private and may change without notice. Their
  parsing is confined to `DeepSeekClient.swift` so a schema change is a
  one-file fix.
- `probe/probe.sh` remains useful for re-checking endpoint shapes later, e.g.
  to test whether a narrower window yields hourly buckets.
