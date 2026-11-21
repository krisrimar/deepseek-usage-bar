# Changelog

All notable changes to DeepSeek Usage Bar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The number the app reports comes from `CFBundleShortVersionString` in
`app/Info.plist` — that file is the only place to bump. `tests/run.sh` fails if
it and the newest release heading below disagree, so the two cannot drift.

## [Unreleased]

Nothing yet.

## [0.5.0] - 2026-11-21

### Added
- Releases users can install and update from. Each tagged build publishes a
  universal `.app` as a zip and a dmg, each with a SHA-256 beside it, plus an
  `install.sh` that downloads the zip, checks it against that checksum, installs
  it without the quarantine prompt and opens it. The source is public, so the
  release is reproducible with `./scripts/package.sh`.
- **Settings → Updates** checks GitHub for a newer release on launch (at most
  once a day, and silent if GitHub is unreachable) and on demand. Installing is
  never silent: the download is compared with the published checksum, then the
  unpacked bundle is checked for this app's identifier and the expected version
  before a helper waits for the app to quit, swaps the bundle and relaunches it.
  A badge in the popover header says when an update is waiting.
- The app is ad-hoc signed rather than notarized, so `install.sh` is the
  recommended way in: files fetched by curl are not quarantined, which is what
  keeps macOS from refusing the first launch.
- The popover says **why** the current moment is off-peak, not only that it is:
  a working day outside both windows, the weekend (make-up workdays included), or
  a Chinese public holiday, which it names. The same reason is in the menu bar
  item's tooltip and as a `reason:` line in `Copy diagnostics`.

  The three answers are the three ways the peak rule can fail, read back in the
  order the tier itself is decided — weekday, then holiday, then window — so the
  explanation is that decision described rather than a second opinion free to
  disagree with the tier on screen. A holiday falling on a weekend reports as the
  weekend: a make-up workday is a weekend day made into a working day and is
  billed off-peak anyway, so the weekday settles it without the holiday table
  being consulted.

### Changed
- `Peak today:` reads `none` on a day with no peak at all — a weekend, or a
  holiday. Printing the clock's two windows under a line that has just said the
  whole day is off-peak contradicted it.
- `Holidays.holidayRanges` is now derived from `holidayPeriods`, which carries a
  name beside each range. The dates still have exactly one home; the names are
  what the popover needs, and `holidayName(_:)` answers them from the same table
  `isHoliday` reads rather than a second one kept in step by hand.
- `AppModel.tick` reads the clock once for the tier, its reason and the
  countdown. Three separate readings could straddle a transition and leave the
  tier disagreeing with its own explanation.
- Menu bar item selection, the API key and the platform token moved from the
  popover into a Settings window, opened from a gear beside the popover title.
  The popover stays a glanceable panel for tier, balance, spend and today's
  usage instead of also being where every credential is typed.

### Removed
- Automatic API-key discovery. The `sk-` key is now entered in Settings and
  stored in the macOS Keychain; the app no longer reads `$DEEPSEEK_API_KEY` or
  `~/.claude-profiles/deepseek/.claude/settings.json`. A credential the app never
  asked for is one the user did not choose to give it, and the balance is easier
  to account for when the key behind it is the one shown in the app.

### Fixed
- **Spent today** in the menu bar no longer keeps only the last API key's cost
  when several keys ran the same model. The cost endpoint reports one series
  per (API key, model), while the one-day fold is keyed by model, so each
  series overwrote the previous figure — on a day with four keys using
  `deepseek-flash`, the bar read $0.0022 while the chart, which accumulates
  across series, correctly showed $0.19. The fold now adds them.
- The spend chart's x-axis no longer repeats the weekday four times when a
  range holds only a day or two. `AxisMarks` divides the time domain rather than
  the bars, so a one-day "This month" produced four ticks inside that day — four
  copies of "Sun". Labels are now one per chosen bar, at midday.
- **This month** on the 1st no longer multiplies the day's spend by the number
  of hourly buckets. A one-day window comes back from the amount endpoint in
  hourly buckets, while the cost endpoint reports one figure for the day; the
  fold added that figure once per bucket, so today's cost showed roughly 24×
  its real value and disagreed with the menu bar's **Spent today**. Reported
  cost is now applied once per model-day.
- The spend chart no longer fails with `INVALID_PARAM` once a window crosses a
  daylight-saving change. The endpoint requires each bound on a whole hour and
  the span to be a whole number of 86400-second days; a window of local
  midnights satisfies that until the 23- or 25-hour day, after which a 7-day
  window is 7 days and 1 hour and the whole request is refused. The client now
  keeps the end on local midnight and moves the start to the nearest point that
  makes the span whole days, giving up at most one hour at the outer edge of
  the oldest day.

  The same defect took down the one-day usage call on the 25-hour day itself,
  so the app showed no per-model spend at all that day.
- **Peak today** now answers for the viewer's local day. It was reading the UTC
  day, so for the first eight hours of every local day the popover listed the
  previous day's windows — or `none` — beside a tier about the new day. The
  windows are clipped to that day, and a window split by local midnight appears
  on both days it touches.
- The off-peak reason reads the weekday in Beijing, like the holiday table it is
  decided beside. Where the UTC and Beijing dates differ it could call a
  Saturday "a working day" while the countdown beside it said peak could not
  return until Monday, or call Monday morning "the weekend".
- A rejected or cleared credential no longer leaves the last reply on screen.
  The platform token is dropped on a 401, but **Today by model** and the menu
  bar's **Spent today** kept the figures fetched with it forever, because a
  refresh with no token never runs and so never replaces them. Changing or
  clearing either credential now clears the data that belonged to it, and the
  no-token state appears as it does on first launch.
- A 401/403 from the balance endpoint names the **API key** rather than telling
  the user to paste a platform token, which is the other credential; the dead
  key and the balance it produced are cleared instead of being retried every
  five minutes.
- Hovering the right half of a spend-chart bar no longer selects the following
  day. The hit test snapped to the nearest bar *start*; it now takes the bar
  whose day contains the cursor.
- In a zone whose UTC offset is not a whole hour — or on a spring-forward day —
  the one-day usage request reached outside the local day it asked for, so
  tomorrow's first half hour could be counted in today's totals. The server
  window still has to be whole UTC hours and whole days; buckets outside the
  requested local day are now dropped when the reply is folded.
- The countdown no longer blanks for days during Spring Festival. The transition
  scan horizon was shorter than the 10-day-15-hour off-peak run a 9-day holiday
  block produces when it follows a weekend, so the scan returned `nil` and the
  countdown read `--`.
- The countdown is scanned once and cached until it arrives instead of being
  recomputed minute by minute on the main thread every second, and holiday
  lookups reuse one `DateFormatter`. During a holiday the old code stalled the
  main thread for roughly 170 ms every second.
- **Paste** in Settings clears the text field after saving, so a later **Save**
  or Return cannot overwrite the pasted credential with whatever stale text was
  still in the box.

## [0.4.0] - 2026-09-25

### Added
- The popover says when the app's own Chinese holiday table has run out, instead
  of quietly reporting peak. A holiday missing from the table reads as a working
  day, so the tier is never guessed *downward* — the app keeps reporting what the
  weekday and the window say and flags that a later holiday may be wrong. The
  same line is in `Copy diagnostics`, which reports the table's coverage even
  when healthy, so a pasted block says which table the build carries.

  **This build's table ends with 2026**, so it will light up from about
  24 December 2026 for anyone still on it: the countdown reads 8 days ahead and
  needs the next year's dates before the year turns, not after.

### Changed
- The holiday table moved out of `PeakSchedule.swift` into `Holidays.swift`, and
  `holidayRanges2026` became `holidayRanges`. The table now holds a rolling two
  years — this one and the next — and is grouped by year so the annual edit,
  when the State Council publishes, is one block in and one block out. Two, not
  one, because the countdown scans 8 days ahead and so already needs January's
  data during the last week of December.
- `PeakSchedule.transitionScanDays` names the countdown's 8-day horizon, which
  the staleness check compares against, so the two cannot drift apart.

## [0.3.0] - 2026-09-23

### Added
- A spend chart in the popover: one bar per day over the **last 7 days**, the
  **last 30 days**, or **this month**, with the window's total above it.
  Hovering a bar reports that day's spend, requests, and — where any part of it
  came from the rate table rather than from DeepSeek — that it is a lower bound.
- The chosen window is remembered across launches, and `Copy diagnostics`
  reports it along with the window's length and total.

### Changed
- The chart's window is fetched separately from the one-day call, and only
  while the popover is open. The two want opposite things from the same
  endpoint: asking for exactly one day is what makes DeepSeek return *hourly*
  buckets, which is the only way peak and off-peak spend can be told apart, and
  a week or a month comes back *daily*, which is what makes a trend affordable
  to fetch. One request cannot produce both.
- A day whose cost came back with no tokens, or tokens with no cost, no longer
  counts as an estimate when the missing figure prices to zero.

## [0.2.0] - 2026-09-20

### Added
- The popover header shows the running version, selectable so it can be quoted
  into a bug report.
- `Copy diagnostics` now reports the version, so a pasted block identifies the
  build that produced it.
- `./app/build.sh` prints the version it built and the `ditto` line to install
  it.

### Changed
- This changelog, kept from here on.

## [0.1.0] - 2026-09-19

Initial working release.

### Added
- Menu bar item: a dot for the current rate tier (green off-peak, orange peak)
  followed by any of balance, time to the next tier change, and spend today.
- Peak schedule computed in UTC and rendered in the local zone, with the 2026
  Chinese public holidays and the weekend make-up workdays (调休) that DeepSeek
  still bills off-peak.
- Balance from `api.deepseek.com/user/balance`, with the API key found from the
  Keychain, `$DEEPSEEK_API_KEY`, or the Claude Code profile.
- Per-model requests, tokens, and cost from the private platform dashboard
  endpoints, with peak/off-peak spend split exactly, from the hourly buckets a
  one-day window returns.
- Platform token held in the macOS Keychain, with the 40002/40003-inside-a-200
  refusal treated as a retired credential and cleared.
