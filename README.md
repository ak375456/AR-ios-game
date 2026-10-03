# Drive AR

## Start here: context for AI agents

This is the project onboarding document. Read this section before changing the
app, then read the relevant subsystem documentation and source files below.
Reviewed against the local source on **1 October 2026**. Source code remains
the authority when this document and the implementation disagree; update this
README when behavior or architecture changes.

**Owner priority: UI/UX is my priority.** Preserve the quality of the garage,
the clarity of the AR flow, responsive controls, and readable overlays. Treat
visual and interaction regressions as real defects, even when the code builds.

### Project location and setup

The app/project folder is `vr/` inside the workspace. Paths and commands in
this README are relative to that project folder, which contains this file,
`vr.xcodeproj`, `Tools/`, and the inner `vr/` source/resource directory.

- Product/display name: **Drive AR**. Xcode project, target, and scheme: `vr`.
- App icon: the supplied yellow drifting car artwork in
  `vr/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, resized to an opaque
  1024 × 1024 PNG. iOS applies the icon shape and appearance treatments.
- Native Swift iPhone app; iOS deployment target **18.0**, portrait only,
  device family `1`. Bundle identifier: `Lexur-Co.vr`.
- The project records Xcode creation/upgrade version **26.6**. Use a compatible
  Xcode with the iOS SDK and RealityKit APIs used by the source.
- Swift language setting is `5.0`, with approachable concurrency and default
  actor isolation set to `MainActor`. Respect explicit `nonisolated` delegate
  methods and their hops back to the main actor.
- One application target, Debug/Release configurations, no package dependencies
  or XCTest target. Verification programs are standalone files in `Tools/`.
- Source/resources use Xcode's file-system-synchronized `vr` group. Inspect
  build membership when adding files; do not add duplicate manual entries.
- Info.plist is generated from project settings plus `Config/FontInfo.plist`,
  which supplies the `UIAppFonts` array. Camera/Photos descriptions remain in
  build settings. Keep the small font fragment out of the synchronized source group.
- Runtime is offline; there is no backend, login, analytics, or network layer.
  Bundled USDZ assets are sufficient to run the app; rebuilding them is separate.

Open `vr.xcodeproj`, select scheme `vr`, and run on an ARKit-capable iPhone
running iOS 18 or later. Device installation needs a suitable signing team;
keep local signing changes separate from feature work. Simulator builds can
check compilation/layout, but real AR tracking, occlusion, multi-touch driving,
haptics, and capture require device verification.

From the project folder, a compilation check without signing is:

```bash
xcodebuild -project vr.xcodeproj -scheme vr -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/drive-ar-build \
  CODE_SIGNING_ALLOWED=NO build
```

Unsigned device and simulator builds passed during the progression implementation.
See [verification and remaining device checks](Docs/Verification.md) for the
exact scope. A successful build is not evidence of AR tracking or driving feel.

### Experience and current feature set

1. **Garage:** a navy/cyan miniature pit garage with a rotating car preview,
   Garage / Missions / Collection dock, wallet and career stars, a workshop,
   earned paint, and a fixed racing-yellow DRIVE button. Mini Hatch starts owned, factory finish, level 1
   in all five parts. The other 27 cars require the previous car, stars and coins.
   Locked cars can be inspected, including stock and maximum potential.
2. **Availability:** PLAY validates ownership and snapshots the owned car, paint
   and parts into a fresh AR experience. World-tracking support and camera
   permission are checked. Garage preview never grants a car or paint.
   Unsupported and denied states have explanatory actions.
3. **Placement:** move the phone to find horizontal floor, aim the reticle, and
   tap to place. The car faces along the phone's ground-projected viewing
   direction. Guidance covers tracking, dark scenes, placement problems, and
   lost anchors.
4. **Driving:** steering, accelerator, brake/reverse, handbrake, drift feedback,
   and instruments. Automatic and assisted manual transmissions are available;
   manual adds +/− shift controls. Reset returns to the placement and restores
   knocked props. Reposition picks up the car while retaining an existing course.
   One top-left pause button opens three mission cards, with fixed Resume and
   Garage actions. All missions opens Career/Daily/Mastery inside the same sheet.
   A small labelled Reset button sits beside pause while driving (no confirmation).
   Every pause page has one fixed row above Resume: Move car, Build/Edit course
   and Clean view. Tools holds capture and the optional Real objects editor. Clean
   view hides the instruments, Reset and menu, leaving an eye button to restore
   them. No mission HUD.
   Recording stop and essential tracking/countdown feedback remain available.
   Control settings live in the garage, not over the driving controls.
   **Road coins** (`vr/Progression/RoadCoins.swift`): during free drive with an
   owned car, up to four coins stand on detected floor near the car and in view,
   never on props. The spawn clock runs only while moving (2.5–4.5 s). Coins are
   1 (bronze, ~55%), 2 (silver, ~26%), 5 (gold, stars + floor glow, ~12%) or
   10 (cyan, stars + floor glow, ~7%). Faces are unlit textures drawn once at
   launch, so the value reads in dim rooms. Rare coins land closer and last 22 s
   instead of 14 s. Bad-luck protection guarantees a 5+ within 12 coins and a 10
   within 25. Pickups credit immediately but share one "Road coins" ledger row
   per drive. The HUD counter (`Controls/RoadCoinCounter.swift`, top right,
   hidden in Clean view) tallies this drive. `Support/CoinSound.swift` plays
   `Resources/CoinPickup.caf` (trimmed from the supplied MP3) through an ambient
   session that respects the silent switch. Rare coins chime twice.
5. **Course editor:** cones, barriers, tyres, slalom, selection, drag, two-finger
   twist, 15-degree rotations, duplicate, delete, clear, and undo. Limit: 24
   props; undo history: 40 snapshots. Green/red ghosts show valid/invalid
   placement with an explanation. Editing stops driving and hides controls/dials.
6. **Occluder editor:** hand-place invisible boxes around real objects; adjust
   dimensions/height/yaw and drag them. These hide virtual content and never
   obstruct the vehicle. Room-mesh and people occlusion are capability-gated.
7. **Capture:** scene-only photos from RealityKit and gameplay video from
   ReplayKit, saved with Photos add-only access. Video includes screen controls;
   microphone is disabled. Editing aids are hidden for captures.
8. **Settings:** rearrange/resize controls, tyre-effect quality, custom smoke
   colors and presets, analog/digital instruments, transmission, km/h or mph,
   haptics, occluder-tool visibility, and room-mesh rendering.
9. **Progression:** 120 career missions in ten chapters, 75 daily variants
   (three selected per day), six mastery milestones for every car, and endlessly
   refreshed driving contracts. Daily login grants 10 coins automatically.
   Every mission counts during ordinary driving, without selection or claiming.
   Each chapter keeps five driving basics (distance, moving time, crash-free
   time, pedal stops, reversing) plus seven everyday techniques: road-coin
   pickups, coin value, 10-coins, coin streaks, top speed, full circles,
   U-turns, handbrake turns, non-stop runs, brake-free runs, manual upshifts and
   gears (chapter 4 on), a photo of the car, and driving different cars.
   Detection lives in `DrivingEvaluator.everydayTechniques`; coins, photos and
   car collection arrive through `ProgressionModel.record`. Mastery is three
   drives, a photo, a class technique and 90% of the car's stock top speed.
   No race finish, hidden bay, generated gate, special cone arrangement, or
   drift is required. Gear goals and car collection stay off pause cards
   unless they can progress (Manual selected / garage goal). Missions live in
   the garage tab **and on pause**, never in the driving HUD. Three pause cards
   remain stable through the drive, including completed checks; Resume fills
   completed slots with unfinished goals, preferring different actions.
   Rewards credit immediately.

### Architecture and ownership

| Responsibility | Source of truth / entry point |
| --- | --- |
| Root route and shared selection/settings | `vr/ContentView.swift` |
| App launch and memory-warning paint-cache purge | `vr/vrApp.swift` |
| Durable progression, owned selection and session receipts | `vr/Progression/ProgressionModel.swift` |
| Atomic save, economy validation, calendar policy | `vr/Progression/ProgressionStore.swift` |
| Stable car slots, costs, upgrade curves and ratings | `vr/Progression/ProgressionCatalog.swift` |
| Authored career/daily/mastery content | `vr/Progression/MissionCatalog.swift` |
| Pure fixed-step maneuver evaluation and layout geometry | `vr/Progression/DrivingEvaluator.swift` |
| Temporary course, countdown, interruption handling | `vr/Progression/ChallengeCoordinator.swift` |
| Missions, workshop, paints, rewards and safe goal placement | Other files in `vr/Progression/` |
| Garage layout, palette, preview | `vr/Home/HomeView.swift`, `GarageStudio.swift`, `CarPreviewView.swift` |
| Availability and experience lifecycle | `vr/Controls/DriveContainerView.swift`, `vr/AR/ARExperienceModel.swift` |
| UI state, guidance, and user intents | `vr/AR/ARExperienceModel.swift` |
| AR session, anchors, gestures, placement, frame loop | `vr/AR/ARDriveController.swift` |
| Vehicle state and fixed-step integration | `vr/Car/VehicleDynamics.swift` |
| Engine, gear selection, RPM, torque demand | `vr/Car/Drivetrain.swift` |
| Class reference handling and transmission tuning | `vr/Car/VehicleTuning.swift` |
| Model loading, scale, geometry, wheel pivots, pose | `vr/Car/CarRig.swift` |
| Car metadata and generated roster | `vr/Car/CarCatalog.swift`, `CarCatalogGenerated.swift` |
| Paint definitions, hue rewrite, cached textures | `vr/Car/CarPaint.swift`, `PaintShop.swift` |
| Touch input and persisted control configuration | `vr/Car/DrivingInput.swift`, `vr/Controls/ControlPad.swift`, `ControlLayout.swift` |
| Driving overlay and instrument presentation | `vr/Controls/DriveScreen.swift`, `DrivingControlsView.swift`, `InstrumentCluster.swift` |
| Course layout, editing, entities, physics handoff | `vr/Course/CourseBuilder.swift` |
| Course dimensions, geometry, contacts, floor, slalom | Other files in `vr/Course/` |
| Room/people/manual occlusion | `vr/AR/SceneOcclusion.swift`, `ManualOccluders.swift` |
| Smoke, skid ribbons, procedural textures | `vr/Effects/` |
| Snapshot, recording, Photos save, status | `vr/Capture/SceneCapture.swift` |
| Reusable UI chrome, editors, errors | Other files in `vr/Controls/` |
| Configuration, haptics, unified logging | `vr/Support/` |

The frame path is: control touches → `DrivingInput` → `VehicleDynamics` and
`Drivetrain` → per-step `CourseContacts` → RealityKit prop impulses → vehicle
instruments, interpolated `CarRig` pose, and tyre effects. The post-contact
fixed-step callback also sends stage-local samples to `DrivingEvaluator`, then
`ProgressionModel`; ordinary progress is published at 8 Hz and flushed every
2 seconds, while economic changes commit immediately. Views send intents
through the experience model. Keep rendering and AR session behavior out of
SwiftUI layout code.

### Rules to preserve when editing

- **One vehicle state:** only the dynamics/contact solver changes simulated
  position, heading, velocity, and yaw. Body lean is cosmetic. Do not introduce
  a second physics body that independently drives the car.
- **Timing and coordinates:** physics runs at 180 Hz with interpolation and a
  0.1-second maximum catch-up. All physics uses rendered SI units, in the
  stage's ground plane: `SIMD2(x, z)`, heading zero faces +Z, positive yaw turns
  toward +X. Trace steering signs through the touch layer before changing them.
- **Scale:** cars represent 1:10 vehicles. Only displayed speed is multiplied
  by ten; wheel/engine angular speed already has the correct scale. Unit changes
  and instrument-style changes must not alter simulation behavior.
- **Shared stage:** car and course share one AR anchor. Reset restores the run;
  reposition retains the course and requires compatible empty floor. Restart,
  lost stage anchor, and exit remove the stage/course. Manual boxes have their
  own anchors and drag re-anchors once on release.
- **Tracking:** excessive motion/insufficient features can warn while driving
  remains usable. Relocalizing, interruption, initialization, and failure stop
  driving and release input. Do not make every brief tracking warning stall it.
- **Lifecycle:** inactive stops the car, background pauses AR and stops video,
  resume attempts relocalization, exit tears down entities/effects/subscriptions.
  Async model/effect loads use generation checks to reject stale results.
- **Touch ownership:** UIKit handles simultaneous driving touches. It only
  claims control hit regions; other touches reach placement/editor gestures.
  Disabling input releases held pedals and queued shifts. Shift requests are
  counters, consumed once, rather than repeatedly sampled Boolean flags.
- **Observation cost:** raw driving input is deliberately not observable.
  Instruments quantize/filter readings and publish changes only when needed.
  Do not route 180 Hz physics state through broad SwiftUI observation.
- **Assets:** preserve canonical upright/+Z model orientation, paint-tagged
  prims, wheel naming, measured dimensions, and square-frame wheel pivots.
  Read the detailed model traps below before changing loading or conversion.
- **Memory:** preserve the six-car paint cache, cached UIImage wrappers,
  preview cleanup, bounded smoke texture cache (12 colors), and emitter cleanup.
  Smoke color changes are debounced; retired particles finish their fade.
- **Occlusion:** capability checks query ARKit; avoid hard-coded device lists.
  Toggling mesh visibility updates the renderer without rerunning the session.
  Occluders and real room geometry are not course collision obstacles.
- **Capture:** restore hidden aids after photos, finish course editing before
  video, handle asynchronous recording failure, and remove temporary videos
  after save/failure. Capture feedback currently calls haptics directly even
  when the general haptics setting is off; do not assume it is globally gated.

### UI/UX working guidance

Keep the garage palette in `GaragePalette`, shared AR chrome in
`ControlChrome.swift`, and reusable button behavior in the existing styles.
The garage stage absorbs spare vertical space; preserve visible car framing
and reachable PLAY on small screens. Garage and mission details scroll at large
Dynamic Type sizes; the compact driving chip caps at xxxLarge and opens a full
scrolling sheet. Assess readability and reachability when changing dense rows.
Keep loading/failure feedback for previews and recoverable AR errors.

Control layout uses safe-area fractions and clamped frames, with scale
multipliers 0.75–1.45. The instrument panel follows the steering/pedal layout
rather than assuming fixed control positions. Test moved and resized controls,
manual-only shift buttons, small displays, safe areas, and simultaneous touches.
Retain accessibility labels, selected paint/car feedback, guidance hierarchy,
and concise wording that explains the next useful action.

Default settings are full effects, classic one-color smoke, haptics on,
automatic transmission, km/h, **compact digital instruments** (saved analogue preferences are preserved), occluder tool visible,
and room scan enabled where available. Two smoke colors assign one to each
rear tyre; three colors mingle in both trails. Changing colors must preserve
existing particles' natural fade and avoid increasing total density per wheel.

### Persistence and scope

`Application Support/DriveAR/career-v1.json` and `career-v1.backup.json` store
versioned progression. The atomic primary replacement is the economy commit
boundary; a valid backup is retained. A bad/newer save fails closed without
silently replacing it. Unknown owned IDs are preserved, but cannot be driven
until a matching catalog entry exists. Unknown mission IDs do not grant stars.

Legacy `garage.selectedCar` and `garage.selectedPaint` preferences are retained
but no longer read by the player flow. `GarageModel.swift` is legacy sandbox
code, not an ownership authority. An install without a progression save gets
the same starter career as a fresh install; old browsing does not create
entitlements. There is no first-launch tutorial alert; the garage opens directly.
The legacy `introduced`, `active` and `pinned` save fields remain decodable for
compatibility. Pins never gate background scoring or display completed goals.
Existing controls and accessibility preferences remain available.

`UserDefaults` still stores `controls.layout`, `controls.effects`, `controls.smokeStyle`, `controls.haptics`,
`occluders.tool`, `occluders.roomScan`, `drive.transmission`, `drive.speedUnit`,
and `drive.instrumentStyle`. Layout and smoke style use JSON-encoded data;
other values use strings/Booleans. Preserve keys and decoding defaults, or
provide migration when changing them. Settings Reset resets layout only.

Courses, manual occluders, AR mapping, and simulation state are session-local;
there is no saved course library or cross-launch AR-world persistence.

### In-app purchases

Three one-time (non-consumable) App Store products, defined in
`vr/Store/PurchaseStore.swift` as `PaidUnlock`. Product IDs must match App Store
Connect exactly and can never be reused: `drivear.doublecoins` ($1.99),
`drivear.allcars` ($4.99) and `drivear.maxupgrades` ($4.99).

- `PurchaseStore` (StoreKit 2) loads prices, buys through SwiftUI's `\.purchase`,
  restores with `AppStore.sync()`, and listens to `Transaction.updates` for Ask to
  Buy approvals, refunds and purchases on other devices. Only verified receipts
  unlock anything; there is no server and no receipt is sent anywhere.
- **Double Coins** and **Max Upgrades** are never saved: `ProgressionModel` holds
  them as `doubleCoins` / `maxUpgrades`, set from receipts at launch. Double Coins
  multiplies every credit (mission, chapter, daily set, login bonus, road coins)
  but never goal counts. Max Upgrades makes `parts(_:)` return `.maximum`, leaving
  coin-bought levels untouched underneath.
- **All Cars** is written into `owned` with an `iap.car.<id>` receipt per granted
  car, so every ownership rule works unchanged. Only an explicitly revoked receipt
  (a refund) calls `revokeAllCars()`, which removes just those cars. A missing
  receipt never revokes: it can mean another Apple Account.
- The shop (`vr/Store/ShopView.swift`) opens from the garage header's bag button.
  `PaidUnlockCard` also appears in the Workshop (Max Upgrades) and the locked-car
  sheet (All Cars). All Cars is never sold once the player owns every car.
- `Config/DriveAR.storekit` is the local StoreKit test file used by the Run scheme.
  UI fixtures: `--garage-ui-preview --shop --unlocks=doubleCoins,allCars`.
- The public privacy policy, terms and support pages describe this behaviour
  (repo `ak375456/ar-ios-game-privacy-policy`); update them if it changes.

### Asset tooling and verification

`Tools/build_cars.py` owns the hand-authored `CARS` roster and writes bundled
car assets, `Tools/cars.json`, and `CarCatalogGenerated.swift`. Do not hand-edit
the generated roster as the permanent solution. Source GLBs live under the
author's `~/Downloads`, including `kenney_car-kit`; they are not bundled here.
The converter uses Python standard-library code plus macOS `sips`, `usdcat`,
and `usdzip`. `usdchecker --arkit` is an additional asset validation step.

**Read the script before running a full rebuild:** `build_cars.py` deletes all
USDZ and loose PNG/JPG resources before conversion, including course prop
USDZs, and skips missing/failed cars. A partial source collection can therefore
remove working assets and shrink the generated roster. Stage outputs/back up
resources, verify every source/tool, and rebuild/restore props afterward.
Ordinary UI work does not require asset conversion.

The commands at the end of this README run driving, collision, prop physics,
and wheel-pivot checks. Other tools compare SceneKit/RealityKit bounds and
render car facing, props, or a course scene; inspect each tool's command-line
arguments before use. Some use macOS RealityKit/Metal rendering and require
working graphics services. There is no CI configuration in this folder.
Historical measurements in the detailed notes below are prior results, not
fresh validation of a future change.

For UI work, verify garage browsing/paint consistency, loading/error states,
small-screen layout, accessible labels, editor transitions, and customized
controls. For dynamics changes, run the dynamics/contact checks. For asset
changes, verify bounds/facing/pivots, paint isolation, and both rendering paths.
On device, verify placement/tracking recovery, reset/reposition, collisions,
occlusion capabilities, background/resume, capture permissions, and saved media.
Report what was actually checked and any device-only behavior left unverified.

## Progression: read before changing it

- [Balancing](Docs/Balancing.md): final slots/prices, actual tuning curves,
  detector rules, economic assumptions and tradeoffs.
- [Economy report](Docs/EconomyReport.md): reproducible twelve-route comparison
  (three player profiles × saving/mixed spending × daily/no daily).
- [Verification](Docs/Verification.md): checked invariants and physical-device QA.
- [Original requested specification](Docs/ProgressionRequirements.md): design
  input. Final measured decisions are recorded in Balancing, not silently
  substituted into that document.

`Economy` is the only place to spend/grant currency. Call it through
`ProgressionModel.transaction`, which writes before publishing. Reward IDs,
completion and credit commit together; pending presentation is separate.
Upgrade requests carry the reviewed level so repeated taps cannot buy a second
transition. Keep these rules below the UI. Avoid adding a second wallet or
calling UserDefaults for progression.

`EffectiveTuning.resolve` always starts with the unmodified measured CarRig
reference and a per-car part snapshot. It never compounds a prior build.
Garage values use explicitly labeled reference-geometry estimates. Engine is
one capability curve applied to the engine and its gearbox representation;
transmission gearing, top-speed envelope and road load are calibrated together.
Do not change wheelbase, mesh scale, steering lock or yaw sign for upgrades.

`MissionCatalog` is immutable cached content, keyed by stable IDs. Career
opens the next chapter at eight previous completions; all twelve award a
chapter bonus. First six chapter-one families open Paint permanently. Mastery
counts only while actually driving that owned car. All eligible goals and the
current contract run concurrently. The three pause cards are a stable selection
for readability, not a scoring gate. Completed cards keep their definition even
after a contract advances. Daily rollover/reroll refreshes affected cards.

`DrivingEvaluator` only receives authoritative post-contact stage coordinates.
It knows nothing about phone transforms, settings, display units or render
quality. Drift score is fractional internally and banks on a clean exit;
coins only come from durable mission transactions. Course markers use actual
meters. Pause/reposition/edit/reset cannot integrate a time gap or teleport.
Avoid moving the raw 180 Hz accumulator into SwiftUI observation.

Legacy challenge machinery (not exposed by the current mission catalog)
captures a course snapshot (including undo), uses
temporary layouts, and validates restored prop support points against the
current floor. Loss of the anchor retains that snapshot for this session and
asks for placement again. A 10 cm floor grid covers the entire generated
layout. Compact reduces layout spacing, never car or simulation scale.
`DriveOverlayLayout` places one menu button, the Reset button, compact instruments and essential
status using the real control rectangles plus UIKit touch slop. Tracking warnings
receive space before optional instruments. Scanning has only Back and guidance;
editors own their own tools. Opening pause releases input and suspends scoring
and countdowns; dismissing it resumes the same AR session. Capture actions run
after dismissal. Ordinary clean-driving progress survives a long pause.
Control settings remain in the garage.

**October 1 corrected product rules:** pause MUST show three readable mission
cards first. Keep mission progress out of the live driving view. No manual
tracking gate, introductory tutorial alert, required drift, spatial course,
finish line or multi-stage technique in career/daily/mastery. Free driving,
props, drift physics/effects and upgrades remain. Do not reinstate requirements
from historical briefs or the earlier tools-only Pit stop implementation.

`MissionCatalog` transforms original definitions while retaining IDs/rewards.
`mission-rules.no-drift.v1` and `mission-rules.everyday.v2` are durable one-time
migrations. Completed goals, stars, coins, cars, parts, paint and receipts stay.
Only unfinished counters with changed scoring meaning reset, including
calendar-prefixed daily keys. Same-unit progress survives target adjustments.
New saves carry both markers; failed writes leave the old files recoverable.

`brakeStops` is separate from the legacy bay/acceleration detector. Travel at
least 0.4 rendered metres, release GO and use Brake or Hand; speed crossing
below 0.08 m/s awards one stop. Holding a pedal still cannot farm progress.
There is no dwell requirement (automatic Brake becomes reverse). Collision,
pause or position jumps disarm the detector. `reverseDistance` counts actual
backward translation: Auto holds Brake; Manual selects R then presses GO.
Daily selection finds three distinct metric families across reward tiers, and
reroll always changes the objective instead of selecting an identical variant.

The earlier black/nonresponsive launch was reproduced in Xcode while stopped
at the enabled file breakpoint on `ContentView.swift:20`. That single local
breakpoint was disabled and the debugger continued. When diagnosing launch,
check whether Xcode says **Paused** before changing rendering or save data.

### Interface system and native review

`GarageStudio.swift` owns navy, cyan, cream, yellow and success-green colors,
`GameType`, solid game buttons, currency badges and progress tracks. The display
font is **Lilita One**, PostScript name **LilitaOne**, bundled with its SIL OFL 1.1
license in `vr/Resources/Fonts`. Supporting copy uses SF; counters use tabular
digits. Never depend on a
font installed on the developer's Mac. Simulator fixtures assert font availability.

The Garage stage uses native shapes and one live SceneKit preview. Collection
uses `CarThumbnailCache`: actual models rendered on demand into still images,
16 MB NSCache plus recreatable disk cache (`CarThumbnails-v3`), no live SceneKit
view per tile. SceneKit model parsing stays on the main actor; each thumbnail's
scene is released after its snapshot. Increment cache version when framing or
assets change. Tall models are scaled using height as well as ground footprint.
Reduce Motion stops the hero turntable and control spring animations.

Missions use readable objectives, actual progress and rewards, chapter arrows,
separate Career/Daily/Mastery modes and a collapsed completed list. Detailed
failure rules are behind Info. Goals have no start/track action. Pause uses
cream cards, cyan progress, green completion and a fixed yellow Resume button.
Upgrade purchases still validate the reviewed level; paint remains a preview
until Apply, and already-applied paint is explicitly disabled. Locked car
browsing never changes the owned car selected for driving.

See [corrected pause/mission review](Docs/UIReview/PauseMissions/README.md) and
[earlier October 1 review](Docs/UIReview/October1/README.md) for
screenshots, exact simulator scope, camera-space measurements and device limits.
The debug simulator fixtures use isolated temporary careers/preferences and do
not ship in device/Release builds. `--garage-ui-preview` supports `--collection`,
`--missions`, `--daily`, `--locked`, `--upgrades`, `--paint`, `--purchase`,
`--car=<catalog-id>`, `--thumbnail-audit`, `--large-text` and `--large-balance`.
`--drive-ui-preview` supports `--scanning`, `--menu`, `--tools`,
`--all-missions`, `--completed`, `--partial`, `--large-text`, `--manual`,
`--analog`, `--legacy`, `--editor`, `--recovery`, `--moved` and `--focus`. These render real shipping views over a clearly labeled gray camera
substitute, not a fake AR playtest.

Run the progression checks from this project folder:

```bash
bash Tools/run_progression_checks.sh
```

This reads existing USDZs, checks all 87,500 part combinations, drives stock,
maximum and three mixed builds for every car, audits real starter orbits,
verifies normal Brake/Hand stops on all stock cars, checks automatic/manual
reverse, stable pause cards and save migrations, and prints the economy model. It requires Xcode's Swift SDK,
SceneKit and working Observation macro execution. No asset rebuild is involved.

## Detailed product and implementation notes

An iPhone-only augmented reality driving game. Start with Mini Hatch, earn
coins and career stars, improve the car, unlock earned paint, and collect the
roster in order. Tap PLAY, find the floor with the camera, tap to place the car,
and drive it around the room with two thumbs. Optionally, lay out cones, barriers
and tyres on the floor and drift round them. Photos and video of the scene save
straight to Photos.

Everything runs offline. No third-party dependencies, accounts or network calls.

- **Platform:** iPhone, portrait, iOS 18.0 and later
- **Frameworks:** SwiftUI, ARKit, RealityKit (the car in the room), SceneKit
  (the garage turntable), ReplayKit (video), Photos, AVFoundation, Core Graphics
  (repainting), OSLog
- **Plane detection:** horizontal planes via `ARWorldTrackingConfiguration` and
  raycasting — no LiDAR required

## The cars

28 cars, about 9 MB of USDZ. Every one was converted from a source model with
[`Tools/glb_to_usdz.py`](Tools/glb_to_usdz.py) and wired up by
[`Tools/build_cars.py`](Tools/build_cars.py), which is the only place the
hand-authored part of the roster lives.

| In game | Class | Repaintable | Source model |
|---|---|---|---|
| Sports Sedan | sedan | yes | Kenney Car Kit (3.1) |
| Hot Hatch | drift | yes | Kenney Car Kit (3.1) |
| Open Wheeler | openWheel | yes | Kenney Car Kit (3.1) |
| Apex GT | supercar | yes | Apex GT |
| 80s Car | sports | yes | 80s Car |
| Ambulance | van | — | Ambulance |
| Rust Bucket | classic | yes | Broken Car |
| Muscle Coupe | sports | yes | Muscle Coupe |
| Mini Hatch | compact | yes | Car Hatchback |
| Runabout | compact | yes | Car |
| Beach Buggy | offroad | yes | Car |
| Pony Coupe | sports | yes | Pony Coupe |
| Roadster | sports | yes | Convertible |
| Grand Tourer | sports | yes | Convertible |
| Wedge Racer | supercar | yes | Wedge Racer |
| Field Truck | offroad | — | Field Truck |
| Trail Runner | offroad | — | Trail Runner |
| Drift Coupe | drift | — | Drift Coupe |
| Vintage Saloon | classic | — | Old Car |
| Police Car | sedan | — | Police Car |
| Estate 4x4 | offroad | yes | Estate 4x4 |
| Luxury Limo | classic | — | Luxury Limo |
| Track Coupe | sports | — | Sports Car |
| City Taxi | sedan | yes | Taxi |
| Work Pickup | truck | yes | Work Pickup |
| Angular Truck | truck | — | Truck |
| Family Van | van | yes | Van |
| Banana Kart | novelty | — | cartoon banana car |

Cars are named after their source models, because generic names made it look
like models were missing from the roster.

> **Before a public release:** several models depict real, trademarked vehicles
> and some textures carry manufacturer badges. The Creative Commons licences
> cover the 3D models, not the manufacturers' trade marks, and the in-game names
> now use the marques. Clear this properly before shipping publicly.

### The pipeline

Source models arrive in whatever convention their author used — Z-up, nose
along X, nose along -Z, authored at an angle, wheel meshes with their origins
left at zero. The converter fixes all of that and bakes a single corrective
rotation onto the root, so the app can assume one convention for every car:

1. **Upright.** If the tallest measured axis is Y, the model was authored Z-up
   and gets turned upright. Bounds are measured by composing full node
   transforms, not just accumulating translations — several of these models
   carry a rotation on an inner node, and ignoring it puts the axes in the
   wrong order.
2. **Lengthwise.** The longest horizontal axis is found from the *principal
   axis* of the vertices, not by comparing bounding-box widths. Two of these
   models are authored at an angle in their own frame, which a bounding box
   cannot see — it just reports a fat box and the car ends up sitting
   diagonally on the floor.
3. **Facing.** Principal-axis analysis gives an axis, not a direction, so
   front-versus-back is decided by rendering every car head-on from +Z and
   checking whether the tile shows headlights and a grille or tail lights and a
   number plate. Seven of the 28 needed turning round. Side-on thumbnails were
   tried first and proved too easy to misread — that is how a supercar ended up
   driving backwards.

> **A trap worth knowing.** `SCNNode.boundingBox` is expressed in the node's
> own space and does **not** include a transform set on that node. Because the
> orientation fix is baked onto each car's root prim, measuring a model
> directly reports its *pre-rotation* box — so a car turned 90° measures its
> width as its length. That silently pointed the verification renders at the
> wrong side of every rotated car and oversized them in the garage. Always wrap
> the model in a holder node and measure the holder. RealityKit's
> `visualBounds(relativeTo:)` does include it, which is why the AR path was
> never affected; there is a check for this in `Tools/`.

Wheel meshes are then re-centred on their hubs so they can spin and steer,
embedded textures are extracted and capped at 1024 px, and the car's paint
material is identified by walking the body triangles weighted by area.

> **A second trap, from the same family.** A wheel's pivot cannot live in the
> wheel's own group, because a group's frame is not always square. The Range
> Rover scales its wheel group by (0.48, 3.66, 3.66) and stands it on its
> side, so a rotation applied in that frame is followed by an uneven scale —
> which shears the tyre into a slab rather than turning it, while the hub
> itself stays perfectly still. Its left wheels are authored with a shear
> already. `CarRig` therefore hangs each pivot off the model's own square
> frame and puts a carrier underneath that replays the group's transform, and
> never touches the wheel's authored transform at all.
> `Tools/WheelPivotCheck.swift` asserts the exact condition — after turning a
> pivot by R, the wheel's placement must equal T(hub)·R·T(-hub) applied to
> where it started — which catches both a moved hub and a sheared tyre
> however asymmetric the wheel is. 52 wheels across 14 cars.

Everything the physics needs (wheelbase, track, wheel radius) is measured from
the mesh at load time, so a car can never drive like a shape it isn't. A
headless check rebuilds the runtime hierarchy and confirms that each model's
nose points along the physics heading at 0°, 90° and 180°.

```bash
python3 Tools/build_cars.py      # rebuilds every car and CarCatalogGenerated.swift
```

All 28 pass `usdchecker --arkit`.

### Paint

Cars with a base-colour map are repainted by rewriting the hue of that map
inside the car's measured paint window, so glass, tyres, lights and trim
survive and the original shading is preserved. Cars whose paint is a flat
material get that material re-tinted instead. Either way only prims the
converter tagged as carrying the paint material are touched.

## Structure

```
vr/
  vrApp.swift             App entry point
  ContentView.swift       Router: garage <-> AR session
  Home/
    HomeView.swift          The garage
    GarageStudio.swift      The lit stage, and the garage's palette
    CarPreviewView.swift    SceneKit turntable
    GarageModel.swift       Legacy sandbox preferences; inactive in player flow
  AR/
    ARDriveController.swift  ARKit session, raycasting, placement, frame loop
    ARExperienceModel.swift  Observable state and wording for the interface
    ARViewContainer.swift    UIViewRepresentable around ARView
    PlacementReticle.swift   The ring drawn on the detected floor
    SceneOcclusion.swift     What this iPhone can hide the car behind
    ManualOccluders.swift    Hand-placed invisible shapes, and their editing
  Course/
    CourseSpec.swift        Prop kinds, layout, sizes, masses and the prop limit
    CourseGeometry.swift    Floor-plane shapes, overlap tests, contact manifolds
    CourseContacts.swift    The car against barriers and cones, inside each step
    CourseBuilder.swift     Layout, editing, undo, and running the props
    PropFactory.swift       Loads and prepares the props once; hands out clones
    BarrierMesh.swift       The race barrier, built from native geometry
    DetectedSurfaces.swift  Detected plane outlines: where a prop may stand
    SlalomPlanner.swift     Fits a row of cones in front of the car
  Car/
    CarCatalog.swift        Car definitions and handling profiles
    CarCatalogGenerated.swift  The 28 cars, written by Tools/build_cars.py
    CarRig.swift            Loading, measuring, painting, wheel animation
    CarPaint.swift          Colours and the hue-rewriting recolourer
    PaintShop.swift         Builds and caches repainted textures
    VehicleDynamics.swift   Fixed-step bicycle model with tyre saturation
    VehicleTuning.swift     Per-class reference figures
    DrivingInput.swift      Control state shared with the render loop
    Drivetrain.swift        Engine, gearbox, shift rules and RPM
    SimulationScale.swift   Rendered/full-size speed conversion and units
  Capture/
    SceneCapture.swift      Photo snapshot, ReplayKit video, saving to Photos
  Controls/
    DriveScreen.swift, DriveContainerView.swift
    ControlLayout.swift     Placement, sizes and persisted settings
    ControlPad.swift        Layout + UIKit multi-touch surface
    DrivingControlsView.swift, ControlChrome.swift
    InstrumentCluster.swift  Analog/digital speed, gear and RPM displays
    ControlSettingsView.swift, OccluderEditorView.swift
    CourseEditorView.swift  The Build Course tray
    CourseIcons.swift       Drawn cone, barrier and slalom icons
    BlockerView.swift
  Effects/
    TireSmoke.swift, SkidMarks.swift, SmokeTexture.swift
  Support/
    DriveConfiguration.swift, Haptics.swift, AppLog.swift
  Resources/
    28 x car .usdz, TrafficCone.usdz, Tyre.usdz, textures
Tools/
  build_cars.py              Rebuilds every car and CarCatalogGenerated.swift
  glb_to_usdz.py             glTF -> USDZ converter
  paint_probe.py             Finds a car's paint hue
  VehicleDynamicsChecks.swift  Headless checks for the driving model
  WheelPivotCheck.swift        Proves every wheel turns about its own hub
  BoundsAgreementCheck.swift   SceneKit vs RealityKit bounds
  CarFacingSheet.swift         Renders every car to check which way it faces
  build_props.py               Rebuilds TrafficCone.usdz and Tyre.usdz from their glTFs
  CourseCollisionChecks.swift  Headless checks: car vs barriers and cones, slalom
  PropPhysicsCheck.swift       RealityKit/PhysX checks for the props
  PropRenderCheck.swift        Renders USDZ props through RealityKit
  CourseSceneRender.swift      Renders the props beside a car at game scale
```

## Driving model

A **dynamic bicycle model**, in [`VehicleDynamics.swift`](vr/Car/VehicleDynamics.swift).
Front and rear axles each get a slip angle from the car's own velocity and yaw
rate. Slip produces a lateral force that rises and then *saturates* at the grip
available on that axle, and a friction circle means force already spent
accelerating or braking is not available for cornering. Those forces drive both
sideways acceleration and yaw acceleration, so the car rotates because its
tyres push it round — nothing rotates the model directly.

A drift happens when the rear axle is asked for more than it has: too much
slip, too much throttle eating the friction circle, or the handbrake cutting
rear grip. The rear force saturates while the front keeps gripping, the car
yaws faster than its velocity vector turns, and it is sliding. Countersteering
works because unwinding the front wheels cuts the front lateral force and the
yaw moment with it.

The simulation runs at a **fixed 180 Hz with an accumulator**, and rendering
interpolates between the last two states, so behaviour is identical at any
frame rate. Below about 0.45 m/s it blends towards plain kinematic steering,
and tyre forces fade out entirely near standstill, so the car is easy to shuffle
around and cannot spin on the spot.

**Tuning** lives in [`VehicleTuning.swift`](vr/Car/VehicleTuning.swift): one
reference set per `CarClass` (mass, top speed, acceleration, front/rear grip,
steering lock, handbrake grip), scaled by each car's measured geometry.

**Deliberate simplifications.** No suspension, no load transfer, no per-wheel
rotational dynamics, no differential, flat ground. Longitudinal slip is
estimated from excess drive or brake force rather than simulated with wheel
inertia. This is an arcade model tuned to feel right, not a motorsport
simulator.

**Simulation scale.** The cars are roughly 1:10 but gravity is not scaled, so
full-size friction coefficients would make them physically unable to slide at
the speeds they travel, and their rotational response would be about an order
of magnitude too fast. Grip coefficients are tuned for this scale and yaw
inertia carries a documented compensation factor; everything else is in honest
SI units.

## Tyre effects

**Smoke** ([`TireSmoke.swift`](vr/Effects/TireSmoke.swift)) uses RealityKit's
`ParticleEmitterComponent` (iOS 18+). Two emitters sit on the rear contact
patches taken from each model's real wheel positions, parented to the placement
anchor rather than to the car, with `particlesInheritTransform = false` — so a
puff stays exactly where the tyre was when it was born and the car drives away
from it. Emission comes from the rear axle's measured lateral slip speed plus
the longitudinal slip estimate, never from whether a button is held: a small
correction makes a wisp, a sustained slide makes a trail, a parked car makes
nothing, and wheelspin smokes even at a standstill. Density, size and lifetime
all scale with slip severity and with the car's wheel radius. Puffs are born
small and dense at the tyre, billow out to about 4.6× and thin and cool to grey
as they age, lingering up to about 2.5 s. The sprite is drawn procedurally, once
and off the main thread: domain-warped fractal noise inside a ragged silhouette,
with relief shading from one side so each billow has light and shadow.

**Skid marks** ([`SkidMarks.swift`](vr/Effects/SkidMarks.swift)) lay a capped
world-space ribbon under the rear tyres during sustained slip, rebuilt at 12 Hz
into a single flat mesh and faded out at the old end through an opacity ramp.
Both effects are cleaned up when the car changes, placement resets, or the
screen goes away, and can be turned down in Settings.

Both appear in captures automatically: photos are rendered by RealityKit itself
and video is a ReplayKit screen recording.

## Controls

Steering, accelerator, brake and handbrake can each be dragged anywhere on
screen and resized, in Settings. New layouts put the handbrake above the pedals;
existing saved anchors/scales are retained, including the old left-hand position. The
touch surface covers the whole screen but only claims touches that land on a
control, so tap-to-place still works around them. Layout, effects quality and
haptics persist between launches.

## The garage

A miniature pit bay with cyan garage-door seams, a navy floor and painted bay
lines, drawn in SwiftUI. A transparent SceneKit view holds the car and its real
contact shadow. The stage is capped at 300 points and scrolls with the name,
stats and secondary actions. DRIVE and the three-destination dock stay in a
safe-area inset so the last scroll item remains reachable.

> **Two traps, both paid for in empty stages.**
>
> A model parsed on a background thread reports the right bounds and draws
> *nothing* once it is parented into a scene built on the main thread. The
> garage showed a lit, empty studio and no error. The parse now stays on the
> main actor, after a `Task.yield()` so the previous car holds for one more
> frame and a spinner can appear if a model is slow.
>
> `UIImage(cgImage:)` looks free — it shares the pixels — but SceneKit keys its
> uploaded textures on the object it is handed, so a fresh wrapper each time
> re-uploaded the whole base-colour map. Browsing grew by several megabytes per
> car and gave none of it back, even for cars already shown. `PaintShop` now
> keeps the wrapper too, and bounds every cache to the six most recent cars.
> Ten car changes moved the footprint by less than a megabyte afterwards.

## Going behind real things

Occlusion is capability-gated, never guessed from the device model:
`ARWorldTrackingConfiguration` is asked directly, in `SceneOcclusion.swift`.
Three separate paths, from three different pieces of hardware:

| Path | Needs | What it does |
| --- | --- | --- |
| Room scan | LiDAR | ARKit reconstructs the room; RealityKit renders it depth-only, so real walls and furniture hide the car everywhere, automatically. |
| People | Runtime support for depth-aware person segmentation | `.personSegmentationWithDepth`, so a hand in front of the car hides it and a hand behind it does not. |
| Manual occluders | Nothing | The player marks out real objects by hand with invisible boxes. |

All three are set up **once**, while the configuration is built, and the
session is never re-run to change them — re-running a world-tracking
configuration is what duplicates reconstructed mesh anchors. The one thing
that can be changed live is whether the room mesh is *drawn* into the depth
buffer (`ARView.setSceneMeshOcclusion`), which touches the renderer and not
the session. That is the switch behind "Use the room scan" in settings: a
reconstructed floor sits a centimetre or two off the real one and can swallow
the skid marks, which are a millimetre thick.

Everything is real geometry at a real distance — `OcclusionMaterial` writes
depth and no colour, so the camera feed shows straight through and only
virtual things behind it are hidden. There is no screen-space cut-out
anywhere, which is why the car, its wheels, the tyre smoke and the skid marks
are each hidden exactly as far as they are actually behind something, and why
occlusion is there in a snapshot and a ReplayKit recording without any extra
work.

**Occlusion is not collision.** No occluder has a `CollisionComponent` —
picking one by tapping goes through screen projection rather than a collision
raycast, so there is no collision shape in the scene at all. Marking out a
sofa changes what you can see, never what the car can hit.

The manual tool is optional and can be hidden from the driving screen.
Its boxes are anchored to `ARAnchor`s so ARKit keeps refining where they are;
drag to move, and the box is re-anchored once, when the finger lifts, rather
than churning anchors sixty times a second. Outlines are drawn only while the
editor is open, and editing and driving are mutually exclusive, so scaffolding
cannot reach a photo or a recording. The panel says plainly that the shapes
are hand-placed and approximate: without LiDAR nothing can work out the shape
of a sofa, and pretending otherwise just looks broken.

## Building a course

Once the car is down, open **Pause → Tools → Build course**. It is
entirely optional — nothing about driving changes if it is never touched.

The tray along the bottom offers **Cone**, **Barrier**, **Tyre** and **Slalom**. Picking
a prop shows a see-through copy of it under the middle of the screen, green
where it can go and red where it cannot, with the reason in the line at the
top: off the scanned floor, on a different surface, too close to the car or
another prop, the course full. Tapping the floor puts it down where the preview
is. Tapping a prop selects it: drag it with one finger, twist it with two, or
use the tray to turn it in 15° steps, copy it (barriers copy end to end and
tyres shoulder to shoulder, so a few taps make a wall), or delete it. Undo covers every change, including
Clear Course, which also asks first. **Drive** hides every editing aid and
hands the controls back; the cone button reopens the editor with everything
where it was left, no rescan and no re-placing.

Driving and editing are never on screen together. While the tray is up the
wheel, pedals and gauges are gone and the car is stopped, so a finger on a
cone can never also be steering.

**Slalom** lays a row of cones in front of the car, spaced in car lengths (2.1
down to 1.5) so it suits the car being driven. Every cone must pass exactly the
test a hand-placed one does. Short of room it tries fewer, closer cones, then
other directions round the car; below three it places nothing and says why.

A course holds up to **24 props**, shown in the tray. **Reset** puts the car
back at its start and puts knocked cones and tyres back on their marks without
touching the layout. **Move the car** leaves the course where it is: the car can go back
down anywhere on the course's floor except on a prop, and if that floor is out
of reach the course can be cleared from the same screen.

### The cone

Of the two downloads of the cone, the small USDZ Sketchfab generates
**fails `usdchecker --arkit`** and renders wrongly in RealityKit: its meshes
hang under a mirroring (negative) scale and rely on `doubleSided` to hide the
inside-out faces, which RealityKit does not honour, so one flank of the cone
draws black and, seen from below, the base is simply missing. It is also in
centimetres, which RealityKit ignores, so it arrives 2.56 m tall and floating
15 mm above the ground.

[`Tools/build_props.py`](Tools/build_props.py) rebuilds it from the original
glTF instead: bakes every node transform into the mesh, checks each triangle's
winding against its normals (100% agree once the mirror is baked), checks the
three parts together are watertight (0 open edges — so single-sided rendering
is safe even with the cone lying on its side), centres it on its base, stands
it on y = 0 and scales it to a real 0.70 m cone. The author's three materials
are kept exactly. The result is 12 KB and passes `usdchecker --arkit`; only it
is in the project. If it ever failed to load, the app
would build a plain cone from RealityKit primitives rather than lose the course.

### The tyre

The tyre download is **two** tyres, one lying flat and one propped against it, which
cannot be a single loose prop: knocked, both would move as one rigid lump. So
`build_props.py` splits the model into its connected pieces, gives every wheel
nut and hub to the nearest tread, keeps the flat one and levels it exactly —
axle up, wheel nuts on top (0.1° of correction). Winding agrees with the
normals throughout and the kept tyre is watertight. It passes
`usdchecker --arkit` at 55 KB.

It is sized to the cars rather than to a textbook: the wheels on the 14 cars
with separate wheels measure 5.0–10.8 cm at game scale, median 7.0 cm, so the
course tyre is 7 cm across (a real 70 cm, 255/55 R19). This wheel's back face
stands 1.7 mm proud of the sidewall, so lying flat it really rests on its hub;
its collision hull is built from the whole model for exactly that reason — a
hull of the tread alone let it sink into the floor by that much.

### The barrier

Nothing suitable came with the project, so the barrier is generated:
a water-filled race barrier with a Jersey profile — rubber toe, steep lower
slope, near-vertical face — extruded and painted in red and white sections,
flat-shaded to sit with the low-poly cone. See
[`BarrierMesh.swift`](vr/Course/BarrierMesh.swift).

### Size

Props are at the same 1:10 as the cars (`SimulationScale`): a 70 cm road cone
is 7 cm, about half the height of a car, as a real one is; a barrier is 24 ×
5.6 × 7.5 cm; a tyre is 7 cm across and 2.1 cm deep. Because the cars already differ in size the way the vehicles
they depict do, the props do not scale with the car.

### Collisions

The car is moved by `VehicleDynamics`, not by a physics engine, so a collision
component on it would stop nothing. Collisions are therefore split cleanly:

- **The car's side** is solved by [`CourseContacts`](vr/Course/CourseContacts.swift)
  inside every 180 Hz vehicle step, on the same state the tyres work on. The car
  is a box a shade inside its measured bounds.
- **Barriers** are fixed boxes. The car is moved back out by the depth it went
  in — no more, so it cannot jump — and an impulse removes the closing speed at
  each contact point, with a little restitution on a hard hit and none on a
  gentle one. Friction along the barrier is capped by that normal impulse, so a
  shallow hit keeps nearly all its speed and scrapes along. Separating axes pick
  the push-out direction, and along the barrier's own axes it always goes back
  to the side the car came from, so nothing can be pushed through a thin barrier.
- **Cones and tyres** are loose. Car and prop exchange momentum as two masses:
  a cone is light (100 g against cars of 0.8–4.4 kg), so the car loses a few per
  cent of its speed; a tyre is 200 g of grippy rubber, so it shoves back harder
  but is never a wall. The prop's share goes to RealityKit — at bumper height
  for a cone, which tips it, and through the middle for a flat tyre, which
  skids and spins it away.
- **RealityKit (PhysX)** does what only a 3D solver can: tips and tumbles the
  cones, spins the tyres, settles both on an invisible floor, and bounces them
  off barriers and each other. It runs as a localised simulation in the anchor's own space, so
  ARKit nudging the anchor never throws a cone.

Because every impact edits the one vehicle state, the drivetrain, RPM,
speedometer, wheel rotation, tyre slip and smoke all follow it on the next step.

Measured by the checks below: a head-on hit at 2 m/s stops the car with 0.5 mm
of penetration and a 0.17 m/s rebound, identically at 30, 60 and 120 frames per
second; a 15° glancing hit keeps 96% of its speed; a car sliding sideways in a
drift cannot pass through; the fastest car cannot tunnel through a barrier at
any angle; pushing a barrier on full throttle moves 0.06 mm in two seconds. A
cone costs a compact about 12% of its speed and a truck about 2%; a tyre costs
them about 25% and 5%, always more than a cone. In PhysX, twelve untouched cones
and eight untouched tyres stay put with no measurable movement for ten seconds;
a cone hit at up to about 1.3 m/s rocks and slides upright, from about 1.6 m/s
it goes over; a tyre skids up to half a metre and always ends flat; every prop
comes to rest within a second without sinking into the floor. A barrier moved
in the editor collides where it now is.

The course is virtual. It never collides with real furniture — without LiDAR
the phone cannot know where a sofa is — and the tray says so.

### Anchoring, lifecycle and captures

The car and the course share one ARKit anchor, so ARKit's refinements move them
together and they stay aligned as the player walks round. Props stand only on
the outlines of detected horizontal planes at the course's height, never on
estimated planes. Losing tracking cancels a drag in progress; going to the
background keeps the anchor and the course for relocalising; a restart, ARKit
dropping the anchor, or leaving the screen removes the course, its physics
bodies and the anchor together. Editing aids — preview, outlines, the car's
start box — are hidden while driving, for the frame a photo is taken, and while
recording; starting a recording from the editor finishes editing first.

### Running the checks

```bash
xcrun swiftc -parse-as-library -O -o /tmp/drivetest \
  vr/Car/DrivingInput.swift vr/Car/VehicleTuning.swift vr/Car/Drivetrain.swift \
  vr/Car/VehicleDynamics.swift vr/Car/SimulationScale.swift \
  Tools/VehicleDynamicsChecks.swift && /tmp/drivetest
```

```bash
xcrun swiftc -parse-as-library -O -o /tmp/coursetest \
  vr/Car/DrivingInput.swift vr/Car/VehicleTuning.swift vr/Car/Drivetrain.swift \
  vr/Car/VehicleDynamics.swift vr/Car/SimulationScale.swift \
  vr/Course/CourseSpec.swift vr/Course/CourseGeometry.swift \
  vr/Course/CourseContacts.swift vr/Course/SlalomPlanner.swift \
  Tools/CourseCollisionChecks.swift && /tmp/coursetest
```

```bash
xcrun swiftc -parse-as-library -O -o /tmp/propphysics \
  vr/Support/AppLog.swift vr/Course/CourseSpec.swift vr/Course/CourseGeometry.swift \
  vr/Course/BarrierMesh.swift vr/Course/PropFactory.swift \
  Tools/PropPhysicsCheck.swift && \
  /tmp/propphysics vr/Resources/TrafficCone.usdz vr/Resources/Tyre.usdz
```

```bash
xcrun swiftc -O -o /tmp/wheelcheck Tools/WheelPivotCheck.swift && /tmp/wheelcheck vr/Resources
```
# AR-ios-game
