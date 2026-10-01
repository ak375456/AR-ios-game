# Drive AR — final balance and implementation decisions

Source of truth: `ProgressionCatalog`, `MissionCatalog`, `EffectiveTuning`, and
`DrivingEvaluator`. September 30, 2026. Asset dimensions were measured from the
bundled USDZs; assets and generated roster metadata were not rebuilt.

## Car order, prices and measured performance

Stock speed bands are explicit and ascending. Limousine moved into the classic
band; Estate 4x4 joins the offroad band; Drift Coupe joins Hot Hatch in the drift
band. Class mass, grip, brake bias and geometry remain distinct. A maximum
classic can remain slower than an upgraded compact: order is by stock band,
not a promise that every maximum build dominates the one before it.

Prices were revised from the proposed 81,580-coin curve to 86,450 total. The
first car purchase was too quick and the final 10,000-coin step dominated the
original model (average car gap up to 148 minutes). Redistributing the costs
originally brought average car 2 near 10–12 minutes. After automatic goal
tracking, the revised model puts it at 6.8–8.8 minutes and the largest average
gap at roughly 55–63 minutes. Prices are unchanged by the UI revision. Star gates still attach to slots; every purchase also
requires the immediately preceding stable ID. No part or paint is compulsory.

The speed and acceleration columns below are **headless solver measurements**
with SceneKit-measured asset geometry, automatic transmission, full straight
throttle, no contacts, and a 180 Hz step. Speed is after 20 seconds; acceleration
is time to 0.8 actual course m/s. These are not phone driving-feel measurements.
Only displayed speed converts by 10 × unit conversion (1 m/s → 36 km/h).

| Slot | Car and stable ID | Coins | Stars | Stock / max m/s | Stock / max time to 0.8 m/s |
|---|---|---:|---:|---:|---:|
| 1 | Mini Hatch (`mini-hatch`) | 0 | 0 | 1.00 / 1.55 | 1.09 / 0.37 |
| 2 | Runabout (`runabout`) | 1,000 | 2 | 1.02 / 1.55 | 1.07 / 0.37 |
| 3 | Rust Bucket (`rust-bucket`) | 1,200 | 4 | 1.04 / 1.35 | 0.92 / 0.50 |
| 4 | Vintage Saloon (`vintage-saloon`) | 1,400 | 6 | 1.06 / 1.35 | 0.89 / 0.50 |
| 5 | Luxury Limo (`limousine`) | 1,600 | 9 | 1.08 / 1.35 | 0.87 / 0.50 |
| 6 | Family Van (`family-van`) | 1,850 | 12 | 1.10 / 1.45 | 0.88 / 0.43 |
| 7 | Ambulance (`ambulance`) | 2,100 | 15 | 1.12 / 1.45 | 0.87 / 0.43 |
| 8 | Angular Truck (`angular-truck`) | 2,400 | 18 | 1.14 / 1.50 | 0.86 / 0.43 |
| 9 | Work Pickup (`work-pickup`) | 2,700 | 22 | 1.16 / 1.50 | 0.84 / 0.43 |
| 10 | Trail Runner (`trail-jeep`) | 2,900 | 26 | 1.18 / 1.50 | 0.78 / 0.40 |
| 11 | Field Truck (`field-truck`) | 3,000 | 30 | 1.20 / 1.50 | 0.77 / 0.40 |
| 12 | Estate 4x4 (`estate-4x-4`) | 3,100 | 34 | 1.22 / 1.50 | 0.76 / 0.40 |
| 13 | Beach Buggy (`beach-buggy`) | 3,200 | 38 | 1.24 / 1.50 | 0.75 / 0.40 |
| 14 | Banana Kart (`banana-kart`) | 3,300 | 43 | 1.26 / 1.60 | 0.50 / 0.43 |
| 15 | City Taxi (`city-taxi`) | 3,400 | 48 | 1.28 / 1.65 | 0.46 / 0.31 |
| 16 | Sports Sedan (`sedan-sports`) | 3,500 | 53 | 1.30 / 1.65 | 0.44 / 0.31 |
| 17 | Police Car (`patrol-car`) | 3,600 | 58 | 1.32 / 1.65 | 0.43 / 0.31 |
| 18 | Hot Hatch (`hot-hatch`) | 3,700 | 63 | 1.38 / 1.80 | 0.51 / 0.44 |
| 19 | Drift Coupe (`rotary-coupe`) | 3,800 | 68 | 1.43 / 1.80 | 0.50 / 0.44 |
| 20 | 80s Car (`eighties-wedge`) | 3,900 | 74 | 1.52 / 2.05 | 0.33 / 0.28 |
| 21 | Roadster (`roadster`) | 4,000 | 80 | 1.57 / 2.05 | 0.32 / 0.28 |
| 22 | Grand Tourer (`grand-tourer`) | 4,100 | 86 | 1.62 / 2.05 | 0.31 / 0.28 |
| 23 | Pony Coupe (`pony-car`) | 4,200 | 92 | 1.67 / 2.05 | 0.31 / 0.28 |
| 24 | Track Coupe (`track-coupe`) | 4,300 | 98 | 1.72 / 2.05 | 0.31 / 0.28 |
| 25 | Muscle Coupe (`muscle-coupe`) | 4,400 | 104 | 1.78 / 2.05 | 0.30 / 0.28 |
| 26 | Wedge Racer (`eighties-icon`) | 4,500 | 110 | 1.93 / 2.30 | 0.29 / 0.27 |
| 27 | Apex GT (`supercar`) | 4,600 | 115 | 2.01 / 2.30 | 0.29 / 0.27 |
| 28 | Open Wheeler (`racer`) | 4,700 | 120 | 2.16 / 2.45 | 0.28 / 0.27 |

## Parts, paint and ratings

Each car has five independent levels, 1–5. Curve fractions are
`[0, .22, .47, .73, 1]`. Every resolve starts from its unmodified class reference
and measured wheelbase, track and wheel radius. Session tuning is a snapshot.

- Engine floor is `.65 + .19 × zeroBasedSlot / 27`, reaching reference at level 5.
  The engine and gearbox share this one capability factor. Transmission applies
  one additional gearing trade from 1 to .92; these are not compounded saves.
- Transmission interpolates the listed stock speed to the class reference.
  Final drive is `referenceFinalDrive × referenceSpeed / effectiveSpeed`.
  Drag is `(effectiveEngineForce − rollingResistance) / effectiveSpeed²` with
  a positive numerator floor. Straight-line results verify achievable endpoints.
- Tires scale grip and cornering stiffness from .88 to 1, braking .94 to 1.
  Drift's rear balance scales rear grip/stiffness from 1.08 to 1.
- Steering response goes from .82 to 1 of reference. Lock and geometry never change.
- Drift setup changes handbrake grip scale 1.35 → 1 of reference, recovery rate
  .75 → 1, and handbrake force 1 → 1.25. Yaw damping goes 1.18 → 1 for most
  classes and **1.18 → 2.5 for compacts**. The compact exception is measured:
  the unmodified maximum reference fell into an unstable tiny orbit; increased
  damping produces a stable, faster sliding circle without auto-steering.

The starter's stock/top maximum is 1 / 1.55 m/s, about 65% at stock. In the real
solver orbit audit, stock maintained about .505 m/s with 12.14° body slip and
.552 m radius; maximum maintained about .785 m/s and .796 m radius. Stock has
one narrow qualifying input region; maximum reaches the standard ring with
less steering and more speed. Over a 20-second settled trace, the detector
counted 2 stock assisted orbits and 3 maximum standard orbits, all also satisfying
the perfect statistics. The center was fitted from settled velocity/yaw and
then **held fixed**, equivalent to positioning that trajectory over the marked
ring. The audit does not prove that a player can place/maintain it on a phone.
See `DrivingAudit.txt` and `Tools/ProgressionDrivingAudit.swift`.

Upgrade transitions keep bases 25 / 50 / 90 / 150. Multiply by category factors
engine 1, transmission .9, tires .9, steering .8, drift 1 and by
`1 + .08 × zeroBasedSlot`; round to nearest 5, minimum 5. Ordinary purchases
need one tap; the reviewed level is the transaction guard against double taps.

Garage ratings have fixed common denominators: speed 2.5 m/s; acceleration
3.6 m/s² engine-force/mass proxy; mean grip 1.25; steering rate 4.8; drift
`(1 − handbrakeGripScale) × releaseRate / 3.5`. Clamp to 0–100. They are labeled
ratings, not horsepower, lap times or measured agility. Garage speed is an
estimate; driving uses the loaded model's actual geometry.

Factory finish is free. The first six chapter-one missions permanently unlock
Paint. Each of the ten existing colors costs 30 **per repaintable car** and is
then free to reapply. Mastery grants one free color choice after the shop gate.
Fixed-paint cars keep their original finish and receive the mastery badge.
Unapplied previews never enter the session snapshot or selected-paint save.

## Mission content and reward schedule

All 120 career, 60 daily and 168 mastery instances retain stable IDs/rewards.
The October 1 correction replaces all required courses and drift skills with
ordinary distance, moving time, crash-free moving time, Brake/Hand stops and
reverse distance. Titles state the action and target. Repeated action/target
pairs within a chapter are adjusted so the task is distinct. The catalog is
the authority for current targets; original matrices below the transformation
are migration inputs. Chapter eight-of-twelve progression is unchanged.

Career reward formulas are unchanged (chapter c, starting at 1): easy D/T/S/A
`15+10(c−1)`; medium F/P/L/G/K `25+15(c−1)`; skill N/E `40+20(c−1)`; capstone
`60+30(c−1)`. All twelve give `100c` once. Only first career completion earns
one star. Replays are practice with ephemeral counters.

Mastery stages pay 15/25/30/40/50/75 multiplied by `1+.15×slot`, rounded to 5.
All stages count automatically while driving that owned car. Six milestones grant a badge and, where applicable, a gift.

Daily easy/medium/skill pays 20/35/50 and the set pays 20, each multiplied by
`1+.2×(highest unlocked chapter−1)` and rounded to 5. The chapter multiplier is
snapshotted at daily refresh. Login is **exactly 10** once per eligible day.

One repeatable contract is always active during driving: alternate
`30+6c` moving seconds and `10+3c` actual rendered metres. Reward is the chapter's
easy reward. No entry fee, purchase or daily attendance is needed. There are
no per-drift or per-donut coin bonuses: overlapping mission payouts are
intentional and included in the model.

## Current free-driving rules

Stops require 0.4 m of meaningful travel between credits and Brake or Hand used
while moving, followed by speed below 0.08 m/s. No bay, speed target or standstill
dwell is required. A held pedal at rest, collision, pause, or reset grants no
stop. Reverse distance uses actual backward travel, with either transmission.
Clean goals count moving time only and reset on significant prop contact or car
reset. Ordinary pause retains clean progress, even longer than ten seconds.

## Legacy maneuver machinery (not current mission requirements)

All samples come after contact resolution at 180 Hz. Car-relative distances
are actual stage meters. Meaningful movement requires speed > .12 m/s and a
nonzero displacement. Invalid/paused samples add nothing. A travel discontinuity
exceeding `max(.04, (newSpeed+oldSpeed)×dt×.7 + .015)` resets the evaluator.

Drift needs 12–55° signed body slip, speed ≥ .48 m/s (.40 in assisted practice),
forward component > .12 m/s and |yaw rate| > .12 rad/s. Entry needs .25s of
qualifying travel. After entry .32s grace retains the chain with no unqualified
score/time. Reverse below −.1 m/s, angles >72°, or an impact >.35 m/s loses the
unbanked chain. Clean exits bank only established segments; opposite segments
must each establish entry and bank within five seconds to link.

Points per valid second are `20 × angleQuality × speedQuality × combo`.
Angle/speed quality each clamp to 1–1.5; combo is `min(2,1+chainTime/6)`.
Points remain fractional until banking (floor). Minor impacts (.08–.35 m/s)
reduce unbanked points by a duration-scaled factor, 25% per .4 seconds of
contact; banking on a minor-contact sample also applies .75. Banked coins
are never revoked. General clean runs ignore contacts ≤.08 m/s; any target
cone touch restarts precision weaving. Contact episodes debounce at .4s.

Donuts integrate actual position around the **fixed marked center**, never
heading alone. Radius tolerance is ±38% (±55% assisted); one angular step must
be <.15 rad, direction must remain consistent, and traveled arc must be at
least .65 of the nominal circumference. A revolution needs ≥50% qualifying
drift coverage (25% assisted). Perfect requires no relevant contact, ≥80%
coverage, population standard deviation / mean radius <20%, and speed <25%.
Means ≤.001 reject the statistic. Samples are bounded to 360 at 30 Hz.
Residual angle carries into the next revolution; no repeated threshold payout.

Gates use directed swept plane crossings with footprint width and .03m rearming.
Order is explicit. Figure eight uses eight directed gates, not heading rotation.
Slalom gates alternate around ordered cones; a contact resets the weave. Parking
requires the whole rotated footprint within the bay, speed <.08 m/s, alignment
within 20° early / 16° later, and the required hold. Another success needs a
real departure beyond bay half-length + car half-length + .15m, then re-entry.
Acceleration dwell is .3s at `min(.5×effectiveTopSpeed,.65)` actual m/s, followed
by a stopped parking hold. Brake/stop technique steps require a braking input,
meaningful prior travel and .5s stopped; coasting at rest is not a brake action.

## Floor layouts, interruptions and save policy

Default radius is 2.5 car lengths, compact is 2.0. The car is never scaled.
Full footprint floor validation uses a grid with spacing ≤.10m, including
boundary corners, on compatible detected horizontal floor. Course props remain
below 24. Markings only display the relevant gates, weave, bay and/or ring.

Temporary courses capture the prior layout **and undo history**. Restoration
checks every prop support point on current floor. Lost anchors retain the
snapshot for the current session, ask for placement, and require explicit
restoration. Reset/reposition/edit clears attempt-local state; cumulative
banked values survive. Scored courses cannot be edited. Short usable tracking
warnings preserve the existing policy. Pauses release input and halt; >10s
monotonic interruption restarts the precision attempt. The next sample after
a short pause establishes a new position baseline; unbanked drift/orbit state
is cleared so opening a new goal cannot claim an earlier maneuver. Ready/countdown waits never
accidentally trigger the tracking recovery timeout.

A version-1 Codable save, atomic primary replacement, and last valid backup
hold wallet, ownership, parts, paints, counters, claims and pending toasts.
Transactions publish after the write succeeds. Simulated failed writes retain
the previous generation. Unknown entitlements are preserved; unknown missions
cannot grant stars. Future/unreadable saves fail closed and preserve files.
Ordinary counters flush every two seconds and on lifecycle changes. Rewards,
purchases, presentation acknowledgments and daily grants persist immediately.

Daily IDs use Gregorian **local calendar** days plus time-zone metadata. The
saved forward day high-water and a five-minute backward wall-clock tolerance
prevent replay; running sessions compare wall time with monotonic uptime.
A forward jump grants one day only. Same-zone midnight is eligible immediately;
a zone change crossing into a new day waits at least 20 elapsed wall hours
since the last grant. A westward day rollback waits until the high-water is
passed. This deliberately favors avoiding duplicate rewards while allowing
travel after 20 hours; career/contracts always remain available. Offline files
are not server-grade tamper protection. Reroll is once per day, only an
unfinished slot, with a different family of the same tier.

## Pacing results and deliberate tradeoffs

See [the complete generated report](EconomyReport.md) and its explicit nominal
attempt durations/success rates. All sequential prices, optional parts/paint,
first clears, concurrent mastery/contracts and daily time are counted. These
are deterministic expected-time routes, not stochastic or device playtests.

The current report is regenerated after mission-rule changes. Its rates for
stops (6 seconds each), reversing (30% of modeled forward speed) and clean goals
are assumptions, not user playtest measurements. All eligible goals overlap,
which makes early unlocks faster than the original sequential-course model.
First upgrades remain quick because the opening rewards and 25-coin starter
engine price are unchanged. Use the generated table rather than historical
course-based timing estimates. Physical-device driving should inform further
pacing adjustments; no hidden delay was added to mission rewards.

Spending every coin cannot soft-lock progression: zero-cost distance/time
contracts remain reachable in Mini Hatch at stock at every chapter. Maxing all
28 cars is optional and is not included in the collection-time target. The
mixed report models three level-2 parts per purchased car and selected paints.
