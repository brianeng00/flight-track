# FlightTrack for iOS

Personal flight tracker with a Flighty-style Live Activity on the Lock Screen and Dynamic Island, Flighty-style alerts, and a FlightAware-depth detail screen. Built for a **free Apple account** first, with a clean path to real push notifications later.

## How it works (free account mode)

```
AeroDataBox (schedule, gates, delays, baggage)  ─┐
OpenSky (live position, flown track)            ─┼─>  FlightEngine (on your phone)  ─>  Live Activity + local alerts
Your phone's GPS (on board, no Wi-Fi needed)    ─┘
```

- **No server.** A free Apple account can't use push notifications, so the app itself polls and updates.
- **Keep-alive.** From 3 hours before departure until your bags arrive, the app keeps a background location session running (blue pill in the status bar). That's what lets it keep polling while your phone is locked.
- **In the air.** Countdowns and the progress bar tick on their own with no updates. Your phone's GPS works in airplane mode, so where it gets a fix it moves the plane too.
- **Budget.** The free AeroDataBox plan is 600 units a month at 2 per status check, which is about 10 flights. The app keeps 40 units in reserve so a flight in progress never goes dark.

## One-time setup (about 20 minutes)

1. **Xcode.** Install Xcode 16 or newer from the Mac App Store, then install XcodeGen:
   ```bash
   brew install xcodegen
   ```
2. **Apple ID in Xcode.** Xcode > Settings > Accounts > + > Apple ID. Your "Personal Team" appears. Note the **Team ID**.
3. **AeroDataBox key (free).** Sign up for AeroDataBox's **Basic** plan on [api.market](https://api.market/store/aedbx/aerodatabox) or [RapidAPI](https://rapidapi.com/aedbx-aedbx/api/aerodatabox/pricing), then copy your API key.
4. **Secrets file.**
   ```bash
   cd ios
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   Fill in `FT_TEAM_ID`, a unique `FT_BUNDLE_ID` (e.g. `com.yourname.flighttrack`), and **one** AeroDataBox key. The OpenSky values are optional (reuse `VITE_OPENSKY_*` from the web app's `.env`). `Secrets.xcconfig` is gitignored; never commit it.
5. **Generate and open the project.**
   ```bash
   xcodegen && open FlightTrack.xcodeproj
   ```
6. **Run on your iPhone.** Plug it in, pick it as the run destination, press Run.
   - First time only: on the phone, Settings > General > VPN & Device Management > trust your developer certificate.
   - Settings > Privacy & Security > Developer Mode: on (iOS asks once).
7. **Allow** notifications and location ("While Using") when the app asks.

## The 7-day rule (free account)

Free-account installs stop launching 7 days after you install. The app shows a banner 2 days out and sends a reminder the day before. To renew, plug in and press Run again; your flights are kept.

**Before any trip, reinstall the day before you fly.**

## Try it without a real flight

Settings > **Simulate a flight** plays FT 101 AUS → ORD through the real engine, Live Activity and notifications: late inbound plane, gate change, 25 minute delay, boarding, takeoff, landing, bags. Lock your phone and watch.

- **Fast** is about 4 minutes; **Medium** is about 15.
- **Real time** runs about 6 hours. It's the keep-alive endurance test (below).

## Milestone 1: prove free mode works on your phone

These two checks decide whether free mode is good enough before we build anything more.

**A. Keep-alive endurance.** Start **Simulate a flight > Real time**, lock the phone, and carry it as usual for 4+ hours. Then open Settings > **Keep-alive check**:
- Longest gap about 30 seconds: iOS kept the app alive, so free mode works.
- Gaps of many minutes while locked: iOS suspended it. Free mode isn't reliable on your phone, and it's time for the $99 account + push (M7).

**B. Real data coverage.** From your Mac, run the data check against 3 real flights you might take:
```bash
cd ios/Packages/FlightCore
ADB_APIMARKET_KEY=your_key swift run flightcheck UA1234 2026-10-05
# or ADB_RAPIDAPI_KEY=... ; add --raw to save the JSON as a test fixture
```
It prints a checklist (gates, terminal, baggage belt, Mode-S, tail number, live marker). Each lookup costs 2 units.

## What's where

| Path | What |
|---|---|
| `Packages/FlightCore` | Everything testable: models, AeroDataBox/OpenSky clients, geo math, polling rules, change detection, Live Activity state. Foundation only, so `swift test` runs on Linux CI too. |
| `App/` | SwiftUI app: `AppModel` (the loop), keep-alive, notifications, Live Activity manager, screens. |
| `Widget/` | Live Activity UI: lock screen card and Dynamic Island, with previews for every phase. |
| `Shared/` | Code compiled into both: ActivityKit attributes, App Group paths, route arc drawing. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and gitignored. |

## Tests

```bash
cd ios/Packages/FlightCore && swift test
```

CI (`.github/workflows/ios.yml`) runs FlightCore tests on Linux and macOS, plays the demo flight through the engine, and builds the app and widget for the iOS Simulator.

## Alert rules (defaults in `AlertRules`)

- **Departure delay:** alert at 15+ minutes, then again when it moves 10+ minutes; also when it's back on time or moved earlier.
- **Arrival ETA in flight:** alert when it moves 15+ minutes.
- **Gates:** departure and arrival gate assigned or changed; baggage belt assigned or changed.
- **Milestones:** boarding, pushback, takeoff, landing, at gate. After a gap in polling, only the newest milestone fires (no stale "pushed back" after "took off").
- **"Where's my plane":** the aircraft's previous leg landing too late for a 35 minute turnaround.
- **Cancel, reinstate, divert.**
- **Boarding soon (est.):** 35 minutes before departure when the airline hasn't reported boarding. Labeled as an estimate.

## Known limits (free mode)

- **Starting the Live Activity needs the app in front.** Tap the "Start live tracking" notification at T-3h, or open the app. Push-to-start comes with the paid account.
- **No Time Sensitive alerts**, so alerts won't break through Focus modes.
- **Battery:** the keep-alive costs extra during the tracking window only.
- **AeroDataBox coverage** varies by airport. Some airports have schedule-only data, with no gates or live times. Milestone 1B shows what you get.
