# October 1 — miniature motor club redesign

**Historical first pass:** its tools-only Pit stop and spatial missions were
replaced by the [pause/mission correction](../PauseMissions/README.md). Use that
review and the root README for current behavior; captures below remain evidence
of the earlier implementation.

These are renders of the implemented SwiftUI screens, not design mockups. The
small device is an iPhone 13 mini; the large device is an iPhone 16 Pro Max with
Dynamic Island. Both run the iOS 26.5 simulator. The gray driving background is
a clearly labeled layout fixture: it does not represent a working AR session.

## Product changes

- No mission panel, mission indicator, reward banner, or mission sheet during
  normal driving. Career, Daily, and Mastery live in the garage's Missions tab.
- Passive goals score automatically. Spatial courses can be started from a
  mission or Pit stop; the existing automatic course queue continues between
  runs. Rewards are credited automatically, with a receipt when returning home.
- Required drift, donut, and linked-slide goals have been replaced with clean
  driving, distance, time, turns, and gates. Free-driving drift physics, smoke,
  scoring, and upgrades remain available.
- One driving menu, compact default instruments, reachable pedals, and a clean
  view with an eye button to restore the interface. Scanning shows only Back
  and surface guidance. Menus release controls and suspend challenge scoring.
- Navy/cyan/cream surfaces, yellow primary actions, a bundled display font,
  a stable navigation dock, illustrated collection, and concise mission and
  workshop views share the same native components.

## Before and after

The September 30 captures provide matching iPhone 13 mini baselines. The user's
October 1 screenshots supplied the additional design references. Earlier
captures do not exist for every new screen; no before image was reconstructed.

| State | Before — September 30 | After — October 1 |
|---|---|---|
| Owned garage | [Before](../garage.png) | [After](garage.png) |
| Driving | [Before](../driving.png) | [After](driving.png) |
| Clean view | [Before](../focus.png) | [After](focus.png) |
| Moved controls | [Before](../moved-controls.png) | [After](moved-controls.png) |
| Mission information | [Old driving sheet](../progress.png) | [Dedicated Missions](missions.png) |

## Reviewed screens

| Screen/state | Native render | What was inspected |
|---|---|---|
| Owned garage | [Small](garage.png), [Large](Large/garage.png) | Car framing, car navigation, compact stats, fixed DRIVE and dock |
| Locked garage | [Garage](locked.png), [Requirements](purchase.png) | Actual unlock checks, costs, preview remains visible |
| Long car name | [Small](long-car.png), [Large](Large/long-car.png) | Grand Tourer title and model fit |
| Collection | [Grid](collection.png), [All 28 models](all-cars.png) | Recognizable model thumbnails, consistent camera, ownership and prices |
| Career | [Missions](missions.png) | Unfinished goals first, Completed collapsed, real targets and rewards |
| Daily | [Daily](daily.png) | Populated rotating goals, progress and rewards |
| Workshop | [Upgrade](upgrades.png) | Current/next level, values, improvement and price |
| Paint | [Paint shop](paint.png) | Model, swatches, unlock state and applied finish |
| Scanning | [Scanning](scanning.png) | Only Back and short guidance; no pedals or utilities |
| Driving | [Small](driving.png), [Large](Large/driving.png) | One menu, compact readout, clear central area, no mission overlay |
| Active course | [Course](active-course.png) | Course state does not add a mission box |
| Pit stop | [Small](menu.png), [Large](Large/menu.png) | Resume/reset hierarchy, scrollable tools and capture |
| Manual | [Small](manual.png), [Large](Large/manual.png) | RPM, shifter, pedal and HUD separation |
| Analogue preference | [Analogue](analog.png), [Saved layout](legacy-layout.png) | Compact gauges; old handbrake position and analogue choice decode intact |
| Course editor | [Editor](editor.png) | Dedicated editor and Done action; driving controls hidden |
| Tracking recovery | [Recovery](recovery.png) | Warning takes priority over countdown/capture messages |
| Clean view | [Clean view](focus.png) | Instruments hidden; restoration button remains accessible |
| Custom controls | [Moved/resized](moved-controls.png) | Menu and readout avoid handbrake, shifter, and expanded touch regions |
| Accessibility text | [Collection and large wallet](large-text.png), [Missions](Large/large-text-missions.png) | Single-column collection, stacked mission metadata, readable wallet and dock |

## Measured HUD area

`DrivingUIAudit` records the actual geometry used by `DriveScreen`. It sums the
full bounding rectangles of visible controls, instruments, menu, and status
panels, then subtracts that area from the safe-area viewport. Transparent
corners are counted as occupied. It does not count translucency as clear space.
The collision solver separately reserves the UIKit controls' expanded touch
targets. The central driving region remains free of substantial UI.

| Driving state | iPhone 13 mini — 375 × 728 pt | iPhone 16 Pro Max — 440 × 860 pt |
|---|---:|---:|
| Default automatic | 86.1% clear | 90.0% clear |
| Manual | 83.3% clear | 87.9% clear |
| Analogue | 83.4% clear | — |
| Saved analogue/handbrake layout | 83.4% clear | — |
| Moved/resized manual controls | 82.2% clear | — |
| Clean view | 90.0% clear | — |
| Recovery guidance | 78.3% clear | — |

Raw geometry: [Small](DrivingUIAudit.json), [Large](Large/DrivingUIAudit.json).
Menu/editor entries describe the underlying HUD only and are **excluded** from
the space-budget claim. No panel/control intersections or mission panels were
reported by the fixture assertions.

## Builds and regression checks

Recorded result summary: [Checks.txt](Checks.txt).

- Debug simulator build passed.
- Release generic iOS build passed with signing disabled. This is a compile
  check, not a signed archive or physical-device installation.
- `bash Tools/run_progression_checks.sh`: **764/764 progression assertions
  passed**, plus 87,500 tuning combinations, stock/max/mixed vehicle simulations,
  actual starter-model orbit checks, and the deterministic economy report.
- Catalog checks ensure no required drift metrics or drift sequence steps
  remain in career, daily, or mastery. Existing legacy maneuver fixtures still
  protect free-driving behavior.
- Migration tests cover once-only conversion, unfinished counter resets when
  their measurement units change, completed goals, wallet, receipts, ownership,
  paint, upgrades, unrelated progress, and fresh-install/relaunch behavior.
- Lilita One is bundled offline under SIL OFL 1.1. Its verified PostScript name
  is `LilitaOne`; runtime fixtures assert it resolves without fallback. The
  Release application's Info.plist contains the expected `UIAppFonts` array.
- All 28 cached thumbnail renders succeeded. The grid uses images, not 28 live
  SceneKit scenes. Reduced Motion stops the garage's optional rotation and
  removes optional driving-control animation.

Commands, from the project folder:

```sh
bash Tools/run_progression_checks.sh
xcodebuild -project vr.xcodeproj -scheme vr -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/drive-ar-oct1-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project vr.xcodeproj -scheme vr -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/drive-ar-oct1-device CODE_SIGNING_ALLOWED=NO build
```

Install the simulator build, then launch with `--garage-ui-preview` or
`--drive-ui-preview`. Available fixture flags are listed in the project README.
Fixtures are compiled only for Debug simulators, use isolated settings and
temporary saves, and do not run on physical devices or in Release.

## Remaining device verification

The Mac was locked to native UI automation, so the review used native simulator
launch fixtures and screenshots rather than a tap-through session. Physical
simultaneous steering/pedal touches, haptics, camera capture, video permissions,
AR tracking/recovery, real floor fitting, course continuation/restoration, and
screen-reader traversal remain unverified. Larger text was visually rendered;
VoiceOver and Reduce Motion were inspected in source but not exercised through
their system UI. The full physical-device checklist is in
[Verification.md](../../Verification.md).
