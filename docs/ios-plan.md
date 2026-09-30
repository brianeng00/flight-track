# FlightTrack iOS plan (personal use, Flighty-style Live Activity)

## Context

- **Goal:** a personal iOS app that tracks one flight at a time. The headline feature is a Flighty-style Live Activity on the lock screen and Dynamic Island. Flighty-style alerts, plus a FlightAware-depth detail screen.
- **Decisions so far:**
  - **Path C:** start on a free Apple account, upgrade to the $99/yr program later for real push.
  - **Hardware:** Mac + iPhone 16 Pro (has Dynamic Island).
  - **Flights:** mostly US domestic, so the 8 hour Live Activity cap rarely matters. No auto-restart in v1.
  - **Code location:** this repo, new `ios/` folder. The React web app stays untouched.
  - **Flight entry:** type flight number + date.
  - **Data source:** reuse OpenSky if possible, otherwise AeroDataBox free.
- **Why the data is a hybrid:** OpenSky (what the web app uses) is ADS-B positions only. It *"does not provide commercial flight data such as airport schedules, delays"*, and its flights endpoint is *"updated by a batch process at night"*. So it can't do gates, delays or scheduled times. Plan:
  - **AeroDataBox free (Basic):** schedule, status, gates, baggage. 600 units/mo; flight status is Tier 2 = 2 units per call.
  - **OpenSky (free, existing credentials):** live position and track while airborne. Costs zero AeroDataBox units.

## Hard constraints (verified against Apple docs earlier)

- **Free account:** no Push Notifications, no Time Sensitive Notifications. Background modes and App Groups ARE allowed. Profiles expire after 7 days, so you reinstall from Xcode weekly.
- **Live Activity limits:** 8h active / 12h max on the lock screen; 4 KB total data; no network access; must be *started* while the app is in the foreground.
- **Free-mode consequence:** the app itself must stay alive in the background to poll and update. Mechanism: continuous background location ("keep-alive"). **Biggest risk. Spike it first (M1).**

## Architecture

```
ios/
  project.yml                 XcodeGen spec (text, so it can be authored/reviewed here; you run `xcodegen` on Mac)
  Config/Secrets.example.xcconfig   API keys template (real Secrets.xcconfig gitignored)
  Packages/FlightCore/        Pure-Swift package, NO Apple-only frameworks -> `swift test` runs on Linux + Mac
    Models/        Flight, FlightLeg, Airport, Aircraft, FlightPhase, FlightSnapshot
    Providers/     AeroDataBoxClient, OpenSkyClient (OAuth2 client-credentials), FlightDataProvider protocol
    Engine/        PollScheduler (adaptive cadence + unit budget), SnapshotDiffer (old vs new -> [FlightEvent]),
                   PhaseResolver, InboundAircraftCheck
    Geo/           haversine, deadReckon, greatCircle points, progress-along-route
    Format/        times in airport-local tz, delay text, units
  App/                        SwiftUI app target
    Screens/       AddFlight, FlightList, FlightDetail (map, times, aircraft, inbound, charts)
    Services/      TrackingCoordinator, KeepAliveLocation, LiveActivityManager, LocalNotifier,
                   BackgroundRefresh, MapSnapshotRenderer, Store (JSON in App Group)
  Shared/FlightActivityAttributes.swift   compiled into App + Widget (ActivityKit type)
  Widget/                     Live Activity UI: LockScreenView, DynamicIsland (compact/minimal/expanded)
  fixtures/                   recorded API responses + timeline scenarios (reused later by the server)
.github/workflows/ios.yml     Linux: swift test FlightCore. macOS: xcodegen + xcodebuild (simulator, unsigned)
```

**Code to port from the web app (logic only, TS to Swift):**
- `deadReckon()`: `src/lib/deadReckon.ts`. Fills in plane position between OpenSky polls.
- `haversineDistance`, `metersToFeet`, `msToKnots`: `src/lib/geo.ts`.
- `parseStateVector` / `deriveStatus` plus the OAuth token flow: `src/lib/opensky.ts`, `src/types.ts` (`RawStateVector` index map).

## How tracking works (free mode)

1. **Add a flight:** AeroDataBox lookup (flight number + date), you pick the leg, it's saved to the App Group store.
2. **Before the window:** `BGAppRefreshTask` gives opportunistic refreshes. Opening the app also refreshes. A local notification at **T-3h** says "Start live tracking UA123".
3. **Tap the notification, or add a flight inside 3h:** the app is in the foreground, so it starts the Live Activity and turns on the keep-alive (low-accuracy background location).
4. **Poll loop (in-process, adaptive, budgeted):**

| Window | AeroDataBox (2 units/call) | OpenSky |
|---|---|---|
| T-3h to gate-out | every 20 min | none |
| Airborne | every 45 min (ETA, arrival gate) | every 60 s, `icao24` from AeroDataBox `modeS` |
| Landed to baggage belt | every 10 min, stop at belt or +45 min | none |

   **Budget:** about 25 calls = 50 units per flight, so **about 10 flights/mo on free**. The scheduler hard-stops at a reserve so a mid-trip poll never fails.

5. **Change detection:** each snapshot goes through `SnapshotDiffer` to produce events. Then:
   - Live Activity update (`staleDate` = now + 30 min, so a dead keep-alive shows "outdated" instead of lying).
   - Local notification for each alert-worthy event.
6. **In the air without Wi-Fi:** `ProgressView(timerInterval:)` / `Text(timerInterval:)` keep the progress bar and countdowns moving with no updates. **Bonus:** the phone's GPS works in airplane mode, and the keep-alive is already reading it. Where you get a fix, it corrects progress-along-route locally.
7. **End:** 30 min after the baggage belt (or arrival + 60 min), end the Live Activity and stop the keep-alive. Battery goes back to normal.

## Live Activity design (v1, refine with your Flighty screenshots)

- **Lock screen:**
  - **Top row:** `UA 123` + status pill (On time green / Delayed 25m amber / Canceled red).
  - **Middle:** `DEP` code, time (old time struck through if changed), T/Gate, then a route arc over a pre-rendered map snapshot with the plane at progress %, then `ARR` code, time, gate.
  - **Bottom line changes with the phase:**
    - "Departs in 1h 12m · Gate C14"
    - "Boarding soon (est.)"
    - "Taxiing"
    - "Lands in 1h 42m · 36,000 ft · 480 kt"
    - "Landed · Taxiing to B7"
    - "Baggage belt 7"
- **Dynamic Island:**
  - **Compact:** plane glyph + countdown on the left, gate/ETA on the right.
  - **Minimal:** progress ring.
  - **Expanded:** route row + progress bar + one key stat.
- **Map arc:** `MKMapSnapshotter` renders the route image once, at start (app in foreground), and saves it to the App Group. The widget loads it from disk, then draws the arc + plane with SwiftUI `Canvas` using about 16 normalized route points in attributes (fits 4 KB). **Fallback if it looks bad:** a plain drawn arc.
- **Phases:** `scheduled, boarding, departedGate, airborne, landed, arrivedGate, canceled, diverted`.

## Alerts (local notifications in v1)

- Departure/arrival gate assigned or changed
- Delay of 15 min or more, or delay changed by 10 min or more; time moved earlier
- Cancellation; diversion
- Boarding soon (est. departure minus 35 min, labeled estimated)
- Gate-out, takeoff, landing, at gate, baggage belt
- **Inbound plane late:** the aircraft's previous leg (AeroDataBox by registration) has an ETA later than our departure minus 35 min turnaround
- **Free-mode caveat:** no Time Sensitive level, so alerts won't break through Focus until the paid upgrade.

## Status

| # | Milestone | State |
|---|---|---|
| M0 | Accounts, keys, Xcode setup | **Your turn:** see `ios/README.md` > One-time setup |
| M1 | Spikes: keep-alive endurance + real data coverage | **Code ready, needs your phone:** Settings > Simulate a flight > Real time, and `swift run flightcheck` |
| M2 | FlightCore models, providers, engine, tests | Done, CI green on Linux + macOS |
| M3 | App shell: add flight, list, detail | Done (needs an on-device check) |
| M4 | Live Activity: lock screen + Dynamic Island | Done (needs an on-device check) |
| M5 | Free-mode runtime: keep-alive, alerts, BG refresh, reminders, budget guard | Done (proven only after M1) |
| M6 | Detail v2: map track, charts, inbound plane | Done in first pass |
| M7 | Paid account: server + APNs push | Not started (after M1 results) |

## Milestones

| # | What | Who | Done when |
|---|---|---|---|
| M0 | Xcode 26, `brew install xcodegen`, Apple ID in Xcode, RapidAPI account + AeroDataBox Basic key, OpenSky creds (existing) | You | Keys in `Secrets.xcconfig` |
| M1 | **Spikes:** (a) keep-alive survives 4h locked in your pocket with the Live Activity updating; (b) `flightcheck` CLI prints a normalized AeroDataBox + OpenSky snapshot for 3 real flights, confirming gate/terminal/baggage/`modeS`/revised times exist | Me code, you run on Mac | Go/no-go on free mode and on AeroDataBox fields |
| M2 | FlightCore models, providers, PollScheduler, SnapshotDiffer, geo port + fixture-driven tests | Me | `swift test` green (Linux + CI) |
| M3 | App shell: add flight, list, detail v1 (times, gates, status, aircraft) | Me | Builds; you add a real flight |
| M4 | Live Activity: lock screen + Dynamic Island, phases, timers, stale date, map snapshot | Me | Visible on your 16 Pro, correct per phase (debug "simulate timeline" screen) |
| M5 | Free-mode runtime: keep-alive, local alerts, BG refresh, T-3h reminder, auto-stop, budget guard | Me | End-to-end on a real flight |
| M6 | Detail v2: MapKit track, altitude/speed chart (Swift Charts from OpenSky track), inbound plane | Me | FlightAware-like screen |
| M7 | Paid upgrade: `server/` on Cloudflare Workers (cron poll, same rules, APNs .p8), Live Activity push token + push-to-start, Time Sensitive, remove keep-alive | Me, after you pay $99 | Locked-phone updates with the app force-quit |

**Keeping M7 cheap:** the `fixtures/` timeline scenarios become shared golden tests. The TS server must emit the same events as Swift `SnapshotDiffer`.

## Risks and unknowns (being upfront)

- **Keep-alive reliability and battery:** untested. iOS may still suspend or kill the app. M1 spike decides.
- **AeroDataBox field coverage** (boarding status, baggage, revised times for regional carriers): not verified. My sandbox can't reach aerodatabox.com. M1 checks on your Mac.
- **OpenSky tracks endpoint** is labeled experimental in its docs; coverage over the Gulf/ocean is thin. Fallback: dead reckoning + AeroDataBox ETA.
- **Budget:** about 10 flights/mo. If that's tight, the next step is an AeroDataBox paid tier or AeroAPI.
- **Reinstall every 7 days** on the free account. Set a reminder before trips.
- **No automatic Live Activity start:** it needs the foreground (a tap on the T-3h notification) until push-to-start in M7.

## Verification

- **Linux (here) + CI:** `cd ios/Packages/FlightCore && swift test`. Covers geo port parity (Swift outputs match the TS `deadReckon`/`haversineDistance` on a shared table of known inputs), PollScheduler budget math, and SnapshotDiffer across fixture timelines: on-time, delayed, gate change, cancel, diversion, inbound late.
- **CI macOS job:** `xcodegen && xcodebuild -scheme FlightTrack -destination 'generic/platform=iOS Simulator' build` (unsigned) catches compile errors in the App/Widget code, which I can't build on Linux.
- **On your Mac/iPhone:**
  1. Debug "simulate timeline" screen replays a fixture scenario and drives the Live Activity + alerts in about 2 minutes.
  2. Xcode Live Activity previews for each phase.
  3. Real flight dry run: track someone else's flight today, phone locked, check the lock screen every 30 min.
- **Web app untouched:** `npm run lint && npm run test:run` still pass.
