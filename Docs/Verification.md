## October 1 pause and mission correction

Current evidence and captures: [PauseMissions](UIReview/PauseMissions/README.md).
All mandatory missions now score during ordinary driving. Pause opens three
progress cards; tools are secondary. The checks below describe earlier passes
where they mention generated course requirements or the tools-only menu.

## October 1 redesign

See [native UI review](UIReview/October1/README.md) for current renders and
verification. The dated notes below describe earlier milestones; the new
interface has no mission HUD or required drift goals. Tests retain explicit
legacy drift fixtures solely to protect free-driving physics.

# Progression verification

Run from the project folder (the folder containing this README and `vr.xcodeproj`).
The following automated evidence and UI notes are the September 30 baseline.
Current October 1 builds, 764 assertions, and visual results are linked above.

## Automated evidence

- Unsigned Debug **iOS device and simulator builds passed**, using the README
  recipe and the corresponding `generic/platform=iOS Simulator` destination.
- Progression suite: **756 / 756 assertions passed**. This includes catalog
  identity/counts (28 cars, 120 career, 60 daily, 168 mastery), initial ownership,
  locked selection, predecessor gates, reviewed-level double-tap rejection,
  paint permanence/gates, idempotent rewards, exact wallet on reload, backup
  recovery, interruptions before/after primary replacement, unknown IDs and
  finite/bounded save sanitization, chapter reachability, zero-wallet contracts,
  daily midnight/DST/travel/rollback/forward jumps/reroll, replay without payout,
  and attempt/cumulative reset behavior.
- Tuning: all **87,500** five-part combinations across the 28 profiles checked
  for finite coefficients, bounds and unchanged geometry. Stock, maximum and
  three problematic mixed builds per car driven through straight acceleration,
  full opposite turns and repeated handbrake pulses. No nonfinite state or
  unbounded yaw. Actual bundled mesh dimensions are used for these runs.
- Maneuver checks cover swept forward/reverse/standing/edge-footprint gates,
  valid standard/perfect orbits, reverse/non-sliding circles, stationary spin,
  wall pushing, major contact dropping unbanked points, sign jitter rejecting
  links, clean exit banking, teleport/rebaseline, parking footprint/heading/
  speed/hold/reentry protection, pre-activation clean-time exclusion and
  figure-eight geometry. Fixed-step traces agree across 30/60/120 render FPS.
- Automatic-goal regressions cover older completed pins, unselected career and
  daily completion, wrong-car mastery exclusion, locked chapters, exactly-once
  credit, continuous contracts, next-course selection and clearing an exited run.
- Full overlay placement checks cover 320/375/393/430-point widths and
  548/724/810-point heights, focus mode, moved handbrakes and manual shifters.
  Every returned panel stays on screen and avoids all controls and other panels.
  Camera transforms, km/h/mph, visual effects and instruments are absent from
  the evaluator's API.
- **Existing vehicle dynamics and course collision/slalom suites passed.**
- A separate audit uses the real vehicle solver and Mini Hatch USDZ geometry,
  sweeps actual steering and binary handbrake inputs, and requires a genuine
  fixed-center orbit to pass. Both stock assisted and maximum standard traces
  pass. Raw output is in [DrivingAudit.txt](DrivingAudit.txt); performance
  measurements are in [TuningAudit.csv](TuningAudit.csv).
- The deterministic economy simulator runs all twelve profile/spending/daily
  combinations against the shipping catalogs and transaction rules. Its
  assumptions and results are in [EconomyReport.md](EconomyReport.md).

Run `bash Tools/run_progression_checks.sh` for progression, geometry/dynamics
coverage, orbit audit and economy report. Run the existing two Swift commands
under README's “Running the checks” for baseline dynamics and collisions.
The scripts do not rebuild USDZ assets. The model tests prove rule/graph
reachability, not human ability to finish every authored maneuver.

## UI inspection and limits

Native iPhone 13 mini simulator screenshots were inspected for the garage,
normal driving HUD, hidden-toolbar mode, optional progress sheet, and a moved
handbrake/manual-shifter layout. The live views are rendered by a Debug,
simulator-only fixture; its gray backdrop is explicitly a layout preview, not
AR evidence. The garage opens without onboarding, the toolbar is one row,
completed goals are replaced, the sheet is populated and has no collapse toggle,
and the moved controls have clear space. Screenshots are in [the UI review](UIReview/README.md).

Reproduce after installing a Debug simulator build:

```bash
xcrun simctl launch <qa-device-id> Lexur-Co.vr --drive-ui-preview
# Relaunch with --focus, --goals, or --moved --manual for the other fixtures.
```

Fixtures use temporary progression and separate UserDefaults. They never run on
a physical device or in Release. An ordinary launch still uses the real garage.
Native-app automation could not access the locked Mac, so actual taps, VoiceOver,
Dynamic Type and the full state matrix below remain unverified interactively.
No physical AR device was available. Simulator rendering and builds do **not**
verify tracking, haptics, floor fit, actual touch driving, occlusion, or driving
feel. The new continuous course transition needs device confirmation in particular.

## Physical-device and interactive UI checklist

- Fresh install: one stock factory Mini Hatch; automatic +10 once; readable
  garage with no intro dialog; previous sandbox selection cannot bypass ownership.
  Relaunch before a reward toast finishes: show it again without another credit.
- On a small iPhone and largest accessibility text sizes, inspect Garage,
  Missions, Collection, upgrade before/after, low coins, affordable purchase,
  level 5, owned paint, locked paint, fixed paint and unavailable preview.
  Essential actions must remain reachable in the scroll view and fixed footer.
- VoiceOver: car names/locks, level and cost, before/after values, goal button,
  mission progress and tabs. Verify readable contrast without color alone.
  Reduced Motion and haptics-off should suppress optional movement/feedback.
- Move and enlarge every control, including manual shifter. Open Pit stop, start
  a countdown and dismiss the sheet. Confirm no overlay owns a pedal's touch
  region, simultaneous touches remain reliable, and no input persists on pause.
- Start one Course run on fully scanned floor; finish it, release inputs and
  stop. Verify the next unfinished course fits and starts automatically. On
  partially scanned floor, ordinary goals must keep counting during scan waits.
  Exit to free drive during setup; verify no stale asynchronous setup installs.
  Repeat with a saved custom course and lost/replaced floor anchor. Validate the
  whole footprint, readable numbered arrows, amber bay, ring and explanations
  when a layout does not fit.
- Finish all chapter-one types at stock, then later gate combinations, reverse gate,
  figure eight and mixed capstone. Verify steering-direction instructions
  against the existing +X-is-left vehicle convention. Check drift initiation,
  clean exit, point banking, perfect ring statistics and immediate retry.
- Finish a goal with career/mastery/contract together. Confirm one queued
  notification per durable grant, no mission overlay, accurate exit summary,
  and no replay payout. Check daily rollover during an active daily course.
- Enter a challenge over a hand-built course, finish/cancel/edit, and restore
  layout plus undo history. Lose the anchor, place again, and restore only
  after compatible floor is found; no silent discard of the session snapshot.
- Background briefly and for >10 seconds, interrupt tracking, relocalize,
  reset/reposition, edit, restart AR and exit during asset loading. Confirm
  unbanked maneuvers/reset scopes, retained cumulative values and no teleport
  distance, scan-time progress, stale asset assignment or duplicate credit.
- Confirm original photo/video, occlusion, settings persistence, smoke quality,
  touch layouts, memory-warning cleanup still work.
- Playtest the economy with real players. The first upgrade is intentionally
  faster than the requested 3–5-minute target; slow learners and some late
  purchases exceed other aspirational pacing ranges. See Balancing for exact
  modeled values and reasons, rather than treating the estimates as proven.
