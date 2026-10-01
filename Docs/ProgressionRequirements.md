> Historical brief. October 1 owner feedback overrides required drift goals and
> the driving mission HUD. Required drift/donut steps are replaced by accessible
> driving/gate tasks, with stable reward IDs and an atomic migration. Missions
> have a dedicated garage tab; driving has one menu and compact instruments.
> September 30 feedback also removed onboarding alerts and manual Track actions.
> See README and UIReview/October1 for current behavior.

# Drive AR — complete progression, missions, rewards, and garage implementation prompt

You are implementing this feature inside my existing Drive AR iPhone project. Read the entire prompt and the project's README before modifying code. Inspect the actual source; the README describes the architecture but source is authoritative. Implement the finished experience, not a proposal, mock interface, disconnected prototype, or collection of TODOs. Work through coherent milestones and verify each. UI/UX is my highest priority.

## 1. Product outcome

Turn the current free-driving sandbox into a satisfying driving game with a reason to return after the first few hours. Keep free driving available, but add a substantial career, daily missions, car mastery, coins, sequential car ownership, meaningful bounded upgrades, and earned paint customization.

The loop is: drive → complete clear goals → earn coins and career stars → improve the current car or save for the next → discover different handling and harder challenges → return for fresh goals.

Requirements:

- Start with exactly one basic car. All other cars are visible but locked.
- Move genuinely slower cars toward the beginning and genuinely faster cars toward the end. Do not merely rearrange names while every vehicle keeps equivalent performance.
- New cars start at stock upgrade level 1, including later purchases.
- The starter is slower, less powerful, less agile, and less capable of sustained controlled drifting than its upgraded version. It must remain responsive, steerable, and enjoyable.
- No paint changes initially. Earn access and colors through progression.
- Car 3 cannot be purchased before car 2; car 4 requires car 3, continuing across the roster. Enforce this below the UI.
- Upgrades are earned per car, not automatically shared across the garage.
- Fully upgraded vehicles remain plausible within this miniature arcade simulation. No ridiculous power, instant acceleration, infinite grip, or uncontrollable final cars.
- Target moderate difficulty. Do not create a chore, compulsory daily streak, or frustrating starter grind.
- Daily login grants exactly 10 coins, once per eligible day, without requiring AR placement.
- Remain offline with no login, backend, analytics dependency, real-money purchases, ads, fuel, repair bills, or energy system.

Numbers in this prompt are initial design targets, not measured facts about the existing game. Measure current dynamics and adjust together where necessary, recording final values and reasons.

## 2. Respect the existing project

This is native Swift, SwiftUI, ARKit, RealityKit, SceneKit, iPhone portrait, iOS 18+. The scheme/target is `vr`. Work relative to the real project root described in README.

Inspect at least:

- `CarCatalog.swift`, `CarCatalogGenerated.swift`, `VehicleTuning.swift`, `VehicleDynamics.swift`, `Drivetrain.swift`, `SimulationScale.swift`.
- `GarageModel.swift`, `HomeView.swift`, `GarageStudio.swift`, `CarPreviewView.swift`, `CarPaint.swift`, `PaintShop.swift`.
- `ARDriveController.swift`, `ARExperienceModel.swift`, `DriveScreen.swift`, `DrivingControlsView.swift`, `InstrumentCluster.swift`.
- Course builder, geometry, contacts, slalom planner, settings, and existing Tools checks.

Preserve the single vehicle state, fixed 180 Hz solver, interpolation, 0.1-second catch-up ceiling, stage-local coordinates, simultaneous UIKit driving touches, dynamic control layouts, memory limits, preview cleanup, and generation checks for asynchronous loading. Do not put the physics loop into SwiftUI observation.

Only displayed speed is multiplied by ten for the 1:10 presentation. Mission geometry and distances use actual stage meters; format them explicitly as course distance. Do not multiply the same value twice. Speed-unit changes must never change mission eligibility or progress.

Cars and course share an anchor. Real furniture and occluders are not collision obstacles. Do not promise near-miss or collision detection against real objects.

Do not rebuild assets for progression work. `Tools/build_cars.py` can delete working resources when original models are missing. Do not hand-edit the generated roster as the permanent source of progression. Prefer a hand-authored catalog extension keyed by stable car IDs.

## 3. Car progression and ordering

Use **Mini Hatch** as the initial owned car, with default factory paint and all parts at level 1. If the source reveals a concrete reason Runabout is the better starter, use Runabout and document the swap. Do not give Sports Sedan its current full performance for free; it should also start below its eventual upgraded capability.

Suggested full roster sequence below. It is a proposed game progression, not a claim about real-world car speeds. Audit actual tuned stock and maximum performance before finalizing it. Swap neighboring cars where needed to maintain coherent speed bands and class character. Commit the resulting stable explicit order; never dynamically reorder the player's collection when upgrading a car.

| Position | Car | Initial purchase cost | Stars required |
|---|---|---:|---:|
| 1 | Mini Hatch | Free | 0 |
| 2 | Runabout | 100 | 2 |
| 3 | Rust Bucket | 180 | 4 |
| 4 | Vintage Saloon | 260 | 6 |
| 5 | Family Van | 350 | 9 |
| 6 | Ambulance | 450 | 12 |
| 7 | Angular Truck | 560 | 15 |
| 8 | Work Pickup | 680 | 18 |
| 9 | Trail Runner | 820 | 22 |
| 10 | Field Truck | 980 | 26 |
| 11 | Beach Buggy | 1,150 | 30 |
| 12 | Banana Kart | 1,350 | 34 |
| 13 | City Taxi | 1,550 | 38 |
| 14 | Sports Sedan | 1,800 | 43 |
| 15 | Police Car | 2,050 | 48 |
| 16 | Luxury Limo | 2,350 | 53 |
| 17 | Estate 4x4 | 2,650 | 58 |
| 18 | Hot Hatch | 3,000 | 63 |
| 19 | 80s Car | 3,400 | 68 |
| 20 | Roadster | 3,800 | 74 |
| 21 | Grand Tourer | 4,300 | 80 |
| 22 | Pony Coupe | 4,800 | 86 |
| 23 | Drift Coupe | 5,400 | 92 |
| 24 | Track Coupe | 6,100 | 98 |
| 25 | Muscle Coupe | 6,900 | 104 |
| 26 | Wedge Racer | 7,800 | 110 |
| 27 | Apex GT | 8,800 | 115 |
| 28 | Open Wheeler | 10,000 | 120 |

Every purchase requires the immediately preceding car AND the listed coins AND the listed stars. Stars are permanent career completion counts, not spendable currency. One first career completion grants one star; repeats, dailies, and mastery never grant more career stars. Car unlocking must not require fully upgrading the previous car.

The table's costs and star gates attach to progression slots if the final order changes. Save ownership by stable ID, never array index. Later app updates must not revoke legitimately owned cars when adding or changing slots.

Keep stock top-speed bands broadly ascending. Allow overlap between a fully upgraded early car and a stock neighboring car, but not a starter outperforming late supercars. Drift specialists can have better slide control without outrunning every car. Trucks and vans should keep their mass and handling identity. Do not distort all cars just to force an arbitrary ordering.

Allow inspection of every locked model and its future stats. Locked preview does not grant driving, ownership, upgrades, or paint access. Display the next actionable condition, for example: “Own Runabout first” or “2 more career stars needed.” Do not show a generic lock with no explanation.

## 4. Upgrades that affect real driving

Implement five independently purchased categories, with level 1 stock and levels 2–5 earned:

| Category | Main effect | Constraint |
|---|---|---|
| Engine | Torque and acceleration | Do not also apply an independent duplicate power multiplier |
| Transmission | Achievable top speed and acceleration trade-off | Calibrate gearing and torque together; taller gearing alone does not guarantee speed |
| Tires | Usable cornering grip and braking traction | Preserve the possibility of drifting; avoid perfect rail-like grip |
| Steering | Steering response and agility | No instant heading changes or impossible turning radius |
| Drift setup | More controllable initiation, sustained slide, and recovery | Tune supported tire/handbrake/response parameters; no fictional differential simulation |

Keep braking usable from the start. Never gate essential controls, reset, accessibility, AR recovery, or control-layout settings.

Initial starter endpoints, relative to its audited balanced reference: level-1 effective engine capability approximately 60–70%, achievable top speed 60–70%, useful cornering grip 85–90%, steering response 80–85%. At maximum it approaches its balanced class reference, rather than multiplying that reference several times. Drift upgrades improve controllability, not random luck or magnetic auto-drifting. Use explicit per-category level curves between measured endpoints. Later classes may begin closer to reference; derive their curves separately.

These are target behaviors, not instructions to multiply every existing coefficient blindly. In particular, reduced grip can make drifting easier and steering worse. Tune front/rear balance, response, traction, and power together so stock is limited but fair. Use the real model, not cosmetic stat bars, to validate outcomes.

Do not change measured wheelbase, car dimensions, mesh scale, or yaw sign to create upgrades. Avoid increasing steering lock if it destabilizes the bicycle model. Keep physics safety bounds for every allowed combination of part levels, including mixed builds.

For starter upgrades, base prices for transitions 1→2, 2→3, 3→4, 4→5 are **25, 50, 90, 150 coins**. Multiply by category factors: Engine 1.0, Transmission 0.9, Tires 0.9, Steering 0.8, Drift setup 1.0. For car slot n, multiply by `1 + 0.08 × (n − 1)` and round to the nearest 5, minimum 5. Keep prices data-driven.

Snapshot the effective tuning when starting a drive. Buying upgrades in the garage must not unexpectedly mutate an active simulation. Recompute garage stats and next-session tuning from a shared resolver.

## 5. Upgrade UI: explicit before and after

Keep the existing violet garage and amber accent. Aim for a polished game garage with strong spacing, readable numbers, and restrained animation. The car preview remains the focus.

Use a lightweight navigation structure: Garage, Missions, and Collection. Put Upgrade and Paint actions next to the selected owned car. Avoid five competing bottom bars or a wall of currencies. The balance and career stars are compact and always understandable.

On an upgrade detail sheet show, in this order:

1. Part icon, name, and current/next level: “Transmission · Level 1 → 2.”
2. One sentence explaining the practical benefit.
3. “Current” on its own labeled line.
4. “After upgrade” directly below, with improvement emphasized and a trailing delta.
5. Cost, current balance, and balance after purchase.
6. One prominent “Upgrade · 25 coins” action.

Example layout content only: “Current top speed: 42 km/h”; beneath it, “After upgrade: 47 km/h”; “+5 km/h.” These numbers must come from actual effective tuning or a reproducible estimate, never be pasted into production as invented measurements. Use “Estimated top speed” when appropriate. For metrics without trustworthy physical units, show clearly labeled normalized ratings, such as “Control rating: 34/100 → 40/100,” explaining the scale. Do not label a rating horsepower or seconds.

Use consistent rating scales across cars and levels. Bars must not rescale themselves to make each vehicle look best. Top speed, acceleration, grip, agility, and drift control can be the five overview stats; map each to actual tuning/measurements. Avoid duplicate “power” and “engine power” upgrades that charge twice for one benefit.

Low balance: “Need 12 more coins” plus “View missions.” Maximum level: “Fully upgraded” with achieved values. Rapid double taps must buy exactly one transition. A single clear purchase tap is enough for an ordinary upgrade; car purchases can use a review sheet. Show restrained success feedback and honor reduced motion and haptics preferences.

Do not cover PLAY, shrink the preview out of existence, or break smaller iPhone layouts. Mission sheets can scroll; essential buttons stay reachable. Accessible labels must announce levels, costs, locks, and before/after values. Color alone must not communicate availability or improvement.

## 6. Paint progression

Start with factory paint only. Unlock the paint shop permanently by completing the first six career missions; show this requirement before unlock.

For repaintable cars, retain the original finish for free and price each additional existing paint at an initial 30 coins. A color purchase unlocks that color for that car permanently. Never charge again to reapply it. Show both the paint-shop gate and color ownership where relevant. A locked paint can be previewed in the garage, but cancels back to the owned selection and cannot leak into PLAY or persistence.

Respect fixed-paint metadata. For non-repaintable cars show “Original finish” rather than selling a paint that does nothing. Do not require paint purchases to complete the main career or buy the next car. Keep smoke settings available as currently designed; do not silently turn existing accessibility or visual settings into purchases.

## 7. Mission modes and substantial content

Implement four systems sharing one typed evaluator:

- **Career:** 120 authored missions, 10 chapters × 12, each paying coins and one first-completion star.
- **Daily:** three deterministic, eligible daily choices: easy, medium, and skill. A bank of at least 60 parameterized variants defined below. No login-streak penalty.
- **Car mastery:** six first-completion milestones for each of 28 cars, 168 total. Owned cars only.
- **Repeatable contracts:** always offer reachable objectives so spending coins cannot soft-lock progression. No energy or entry fee.

A selected challenge is explicit. Compatible passive cumulative missions can progress together, but starting a timed course challenge never silently resets another challenge. Support pinning up to three compact objectives; default to one. Do not reward progress earned before a mission was eligible unless it is explicitly a lifetime milestone.

Mission definitions need stable ID, title, short objective, family, metric, target, scope, prerequisite, vehicle/capability eligibility, spatial requirements, course template/seed if any, reward, failure/reset rules, and display formatting. Keep definitions data-driven and separate from SwiftUI.

Each chapter unlocks when 8 of the previous chapter's 12 missions are complete; chapter 1 starts open. All incomplete missions in open chapters remain available. Every career mission must be completable with the starter's available build or a feasible earlier unlock. No mission requiring car 28 before the 120th star. Never require purchases whose only funding is behind those purchases.

### Career content matrix: author all 120 instances

Create one mission per column below per chapter. Give every instance a short distinct human title, an explicit objective, and its own saved ID. This is a concrete 12-family matrix, not permission to ship only 12 missions. Chapters change course layouts, sequencing, and precision as well as numbers.

Scopes: D and T are cumulative valid driving since mission activation; S is clean driving over one attempt; A is a controlled acceleration-and-stop sequence; F is one continuous drift; P is banked drift score across attempts; N is completed donuts across attempts; L is one slalom run; G is ordered gates in one run; K is one parking hold; E is a two-step technique sequence; C is a chapter capstone. Distances are actual stage travel, not real-life walking requirements.

| Chapter | D distance | T moving time | S clean run | A accel/stop cycles | F drift hold | P drift score | N donuts | L slalom cones | G gates | K park hold | E sequence | C capstone |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1: First Keys | 5 m | 20 s | 8 s | 1 | 0.6 s | 60 | 1 assisted | 3 wide | 3 wide | 1.5 s | brake, then clean turn | 3 gates, then park |
| 2: Finding Grip | 12 m | 40 s | 12 s | 2 | 0.8 s | 120 | 1 | 3 | 4 | 2 s | left turn, then right | 3 cones, then stop |
| 3: Slide School | 20 m | 60 s | 16 s | 2 | 1.0 s | 180 | 2 | 4 wide | 5 | 2 s | drift, then recover | drift, 3 gates, stop |
| 4: Precision Driver | 30 m | 80 s | 20 s | 3 | 1.2 s | 260 | 2 | 4 | 6 | 2.5 s | reverse, then park | 4 cones, then park |
| 5: Smooth Operator | 40 m | 100 s | 25 s | 3 | 1.5 s | 360 | 3 | 5 wide | 6 | 2.5 s | drift left, recover, right | figure eight, then stop |
| 6: Course Regular | 55 m | 120 s | 30 s | 4 | 1.8 s | 480 | 3 | 5 | 7 | 3 s | gates, then controlled stop | 5 cones and 4 gates |
| 7: Drift Rhythm | 70 m | 150 s | 35 s | 4 | 2.0 s | 620 | 4 | 6 wide | 8 | 3 s | two linked drifts | donut, drift, recover |
| 8: Technical Driver | 90 m | 180 s | 40 s | 5 | 2.3 s | 780 | 4 | 6 | 9 | 3.5 s | reverse gate, forward park | reverse park and 5 gates |
| 9: Garage Veteran | 110 m | 210 s | 45 s | 5 | 2.6 s | 950 | 5 | 7 wide | 10 | 3.5 s | figure eight, then park | 6 cones and 2 drifts |
| 10: Room Champion | 140 m | 240 s | 50 s | 6 | 3.0 s | 1,150 | 5, including 1 perfect | 7 | 12 | 4 s | three clean techniques | gates, slalom, drift, park |

Assisted donut means visible practice guidance with a generous ring and tolerance, not automatic steering or free completion. Later donuts use standard tolerance. “Wide” means forgiving geometry relative to the current car footprint, not an enormous required room. Ordered gates may reuse a compact loop across laps; they need not all occupy separate floor space.

Use chapter-specific course presets, visible turn arrows, and concise instructions. Acceleration targets are safe relative fractions of the selected eligible car's achievable speed, calibrated to the floor footprint. Reach target for a short valid dwell and then stop within the marked zone. Do not demand full supercar speed across a living room.

Allow practice and failure with immediate retries and no lost coins. Earned cumulative progress persists. The optional best-time/medal layer can add mastery, but one-star career completion must not require expert times. Capstones should take roughly 45–120 seconds once understood, not ten-minute flawless runs.

### Daily bank: exactly defined initial 60 variants

Each row yields five variants from the listed targets. Variants need stable IDs and suitable titles. Assign difficulty using real feasibility, not merely column number. Select only from variants attainable with owned cars and available modes.

| Family | Five targets |
|---|---|
| Valid course distance, cumulative | 10 / 20 / 35 / 50 / 75 m |
| Active driving time, cumulative | 30 / 60 / 90 / 120 / 180 s |
| Collision-free moving streak | 8 / 12 / 18 / 25 / 35 s |
| Separate valid drifts | 2 / 3 / 5 / 7 / 10 |
| Banked drift points | 80 / 150 / 250 / 400 / 650 |
| Best continuous drift | 0.6 / 0.8 / 1.2 / 1.6 / 2.0 s |
| Standard donuts, cumulative | 1 / 2 / 3 / 4 / 5 |
| Clean ordered gate crossings | 4 / 6 / 8 / 12 / 16 |
| Completed slalom runs | 1 / 2 / 3 / 4 / 5 |
| Successful parking attempts | 1 / 2 / 3 / 4 / 5 |
| Controlled acceleration-stop cycles | 1 / 2 / 3 / 4 / 5 |
| Clean left/right drift links | 1 / 2 / 3 / 4 / 5 |

Require distinct attempts for repeated parking/slalom objectives. Leaving and re-entering one parking zone every frame is not multiple successes. Avoid assigning three versions of the same family together. Provide one free daily reroll; choose a different eligible family, reset only that slot's unfinished progress, and never allow rerolling a paid/completed slot for another reward.

### Car mastery: six missions per vehicle

1. First Drive: accumulate 30 seconds of valid moving time in that car.
2. Familiar Wheels: drive 30 actual course meters in it.
3. Clean Control: complete a 15-second collision-free moving attempt.
4. Precision: complete a 4-cone slalom with zero relevant cone contacts.
5. Class Signature: drift class = two 1-second drifts; compact/sedan/classic/van/truck = two precise parks; offroad/novelty = two compact gate laps; sports/supercar/openWheel = three controlled acceleration-stop sequences. These are floor-based tasks, not claims of terrain simulation.
6. Car Showcase: complete one compact mixed course in that car: ordered gates, a class-appropriate skill, then park.

Progress only while driving that actual owned car. Mastery never mandates all upgrades or a paint purchase. Give a mastery badge upon all six, plus a free selectable existing paint for repaintable cars or an equivalent badge-only cosmetic treatment for fixed-paint cars. No asset-dependent promised decal unless actually implemented.

## 8. Correct driving telemetry and skill detection

Create a pure, deterministic telemetry/evaluation layer consuming vehicle state, delta time, resolved tuning, input/activity state, collision events, and course geometry. Read from the authoritative dynamics/contact path. Keep bounded ring buffers. Publish UI progress at approximately 5–10 Hz and only on meaningful changes; discrete completions can publish immediately.

Use stage-local positions, not raw camera movement or changing world-anchor transforms. Moving the phone, dragging a car, resetting, relocalizing, or editing props cannot earn distance or score. Integrate only valid simulated moving time, never raw wall-clock session duration.

### Drift detector

- Derive signed body slip from planar velocity versus vehicle forward direction, alongside yaw rate and meaningful translational speed.
- Initial entry band: approximately 12–55 degrees absolute body slip, above a tuned low-speed threshold near 0.45–0.65 rendered m/s, with meaningful curved travel. Audit against the existing low-speed blend and stock vehicle capability before adopting values.
- Require approximately 0.25 seconds to enter; use hysteresis and a brief 0.25–0.4 second grace window so one noisy sample does not destroy a good drift. Grace retains the chain but grants no unqualified score/time.
- Sustained angles over roughly 70 degrees, excessive reverse motion, a spinout, a major collision, or a run reset end the chain. Calibrate boundaries with traces.
- Score per valid second, not per frame: start with 20 × bounded angle quality × bounded speed quality × bounded combo. Keep each quality multiplier around 1.0–1.5 and combo capped at 2.0. Smooth entry/exit; store fractional score internally and round for display/banking.
- Clean exits bank the chain. Define and display any minor-collision reduction; never revoke previously banked mission rewards. Major crashes invalidate the unbanked chain only.
- Wheelspin smoke, holding handbrake at rest, reversing circles, or holding a button against a wall must not count as drifting.
- Linked left/right drift detection requires a genuine direction change and stable qualifying segments, not jitter around zero slip.

### Standard and perfect donuts

Heading rotation alone is insufficient. Track angular travel of the vehicle's position around a stable estimated center or a mission's marked center. Use a bounded trajectory fit and reject near-zero translation, huge center drift, discontinuities, or back-and-forth yaw.

A standard donut needs approximately one full 360-degree orbit in a consistent direction, plausible radius relative to car length, meaningful traveled arc, and qualifying slide during a substantial portion of the orbit. A perfect donut additionally requires no qualifying contacts, roughly 80% valid drift coverage, radius variation initially under 20%, and speed variation initially under 25%. Document the exact statistical definitions and handle near-zero means safely.

Display a subtle ring/progress arc and “Keep the circle steady” guidance. Count one success per completed revolution with residual angular travel carried forward; never award every frame after 360 degrees. Standard and perfect flags can describe the same maneuver, but any direct maneuver payout must happen once. Distinct mission completions can each reward intentionally.

Do not require perfect donuts early. Validate a genuine starter-build trace can satisfy the tutorial donut. If not, tune the starter or tutorial tolerances; do not fake detection.

### Gates, slalom, parking, clean runs

Gate passage uses swept previous/current position or vehicle footprint against a gate plane, ordered progression, crossing direction, and hysteresis. Standing in a trigger is not repeated crossing. Slalom verifies alternating sides of ordered cones, not merely distance traveled nearby.

Parking requires the complete car footprint inside the zone, heading within a defined tolerance, and speed below a small threshold throughout the hold. Use approximately 20-degree heading tolerance early, tightening moderately later. A stop zone must be sized for the selected car.

Clean-run time advances only during meaningful movement. Use contact severity and debounced episodes to avoid dozens of “crashes” from one contact. A precision mission may reject even a light target-cone touch, while a general clean-driving task may tolerate tiny solver noise. Define those rules per mission and show them before starting.

## 9. AR challenge layouts and interruptions

Add compact generated practice layouts using existing cones/barriers/tyres and lightweight procedural gate/parking markings. Preserve the 24-prop limit and course collision architecture. Validate full course footprint and spacing on compatible detected floor before starting.

Offer compact/default footprints or adapt within safe, tested car-relative bounds. If a challenge will not fit, explain it and offer a compact eligible alternative. Do not silently lower a running mission's rules. Never shrink car scale or alter simulation scale to fit a mission.

Mission courses must not silently destroy a user's hand-built course. Use an explicit temporary challenge layout and restore a captured session-local course snapshot afterward. Validate restore against current stage availability; if the stage has been lost, explain that the layout needs placement again. Challenge layouts cannot be edited during a scored attempt. Editing cancels that attempt with a clear message.

Reset/reposition clears attempt-local score, timers, gate order, and unbanked chains; persisted cumulative progress and already awarded rewards survive. Backgrounding/tracking interruption pauses progress and releases inputs. Short usable tracking warnings follow the existing app policy rather than unnecessarily freezing the car. Long interruption, anchor loss, or coordinate discontinuity restarts precision/timed attempts without a penalty; cumulative counters remain. Resume must not integrate the time gap or teleport distance.

On-screen challenge timers begin after placement and a short ready countdown, not during scanning. Show one clear retry action. Avoid mission overlays in driving-control hit regions, including user-moved pedals and manual shift controls.

## 10. Economy and pacing

Use one spendable currency: integer Coins. Career stars and mastery badges are progress indicators. No second premium currency.

Initial rewards:

- Chapter c career easy missions D/T/S/A: `15 + 10 × (c − 1)` coins each.
- Chapter c medium missions F/P/L/G/K: `25 + 15 × (c − 1)` each.
- Chapter c skill missions N/E: `40 + 20 × (c − 1)` each.
- Chapter c capstone C: `60 + 30 × (c − 1)`.
- Completing all 12 missions in chapter c: `100 × c` once.
- Mastery stages 1–6: base 15/25/30/40/50/75, multiplied by `1 + 0.15 × (car slot − 1)`, rounded to nearest 5.
- Daily missions: base 20/35/50 for easy/medium/skill, multiplied by `1 + 0.2 × (highest unlocked chapter − 1)`, rounded to nearest 5; completing the set adds 20 times that multiplier once.
- Daily login: exactly 10; no multiplier, streak, or escalating login bonus.
- Repeatable contracts: same chapter/difficulty reward scale, chosen to provide a viable sustainable income. Refresh after valid completion; replaying a finished career mission does not replay its first-completion payout.

No passive income while parked, backgrounded, scanning, or in menus. Drift points are a skill score, not a second currency and not a per-frame coin faucet. Coins primarily come from mission rewards; do not accidentally pay a maneuver bonus, contract bonus, and career bonus without accounting for the intended combined income.

Start at zero coins. Make the first easy mission award enough toward a 25-coin upgrade, with the next quick mission providing the remainder. A player should be able to earn the first upgrade in approximately 3–5 active minutes and purchase car 2 in approximately 10–20 minutes, including a modest first upgrade. Treat these as playtest targets and fix bottlenecks.

Early meaningful purchases should generally be 5–15 active minutes apart. Later cars can be aspirational, but avoid several hours of identical farming for a single unlock. Aim for roughly 20–45 active minutes per later meaningful purchase, varying with difficulty and skill. The full collection should extend beyond a 2–3-hour novelty session; an initial target is roughly 12–20 active hours without requiring daily attendance. Do not claim that number is proven without a modeled/playtested route.

Build a reproducible economy simulator/report for three player profiles: newcomer with retries, average mixed player, and skilled player. Compare saving for cars against buying sensible upgrades, and compare playing without any daily rewards against returning daily. Include all sequential car costs, optional upgrades, paint costs, first-clear income, and repeatable income. Measure modeled time from defined attempt durations and success rates; distinguish these assumptions from device measurements. Adjust costs/rewards if the proposed table misses the pacing goals.

Critical: a player spending every coin on legal upgrades or paint must always have reachable repeatable contracts with an owned vehicle. Never require daily login to recover. Avoid increasing upgrade requirements with rewards in a way that leaves the player permanently chasing the same gap.

## 11. Daily logic and persistence integrity

Persist versioned progression separately from existing control and garage preferences: wallet, owned-car IDs, per-car parts and paints, career stars/completions, mastery, active counters, daily slots, reroll state, claim records, and selected owned vehicle/paint.

All economy actions go through one transaction boundary. Validate prerequisite ownership, balance, upgrade bounds, and eligibility there. Spend and grant ownership/level atomically. Reward completion and its claimed marker must commit together. Use unique reward identities and an idempotent transaction ledger or equivalent durable design; duplicate callbacks, double taps, scene recreation, and relaunch cannot duplicate payouts. Do not depend on a disabled button for correctness.

Use a Codable versioned save with atomic replacement and a last-known-good backup, or an equally sound approach compatible with this small app. Persist economic changes immediately. Debounce ordinary cumulative counters and flush on lifecycle transitions without blocking every physics tick. Check finite values, integer overflow, invalid levels, unknown IDs, and negative balances. Do not silently award all content or erase a valid save when one field is malformed.

For existing installs without a progression save, initialize the new progression consistently: starter owned, other cars locked, zero coins, stock levels. Preserve all existing control/accessibility settings. Sanitize previously selected locked cars and unowned paints back to the starter/default finish, with a one-time introduction explaining the new career. Do not infer ownership simply because the old sandbox let a user browse a car. If the repository contains real purchase entitlements, preserve them and implement their migration explicitly.

Daily reset follows the device's local calendar day with stored day/time-zone metadata and monotonic elapsed time during a running session. Prevent duplicate daily claims for a saved day and simple clock rollback replay; keep a forward high-water marker. Large time jumps must not grant multiple missed login days. Explain clock-related ineligibility without punitive bans. Offline-only storage cannot be completely tamper-proof: do not claim server-grade protection or introduce a backend. Cover legitimate midnight, DST, and travel behavior in tests and document the chosen policy.

Login reward is automatic once on opening an eligible day, with a small “Daily bonus +10” notification. No forced modal or claim scavenger hunt. Persist pending reward presentation independently so a crash can show the notification later without crediting it twice.

## 12. Mission and garage presentation

Mission cards show title, plain objective, current/target progress, coin reward, and one action: Start, Track, or Replay. Completed missions show a check and received reward. Use automatic durable reward credit with a short toast; avoid forcing a menu visit to collect every completed task.

Use Career/Daily/Mastery filters inside Missions. Career shows chapter identity and completion, not 120 cards in one undifferentiated feed. Collection shows the full ordered roster, owned count, next car, cost, star requirement, and predecessor condition. Garage focuses on the selected car and the next useful upgrade.

During driving, show a small unobtrusive pinned goal such as “Hold a drift: 0.8 / 1.2 s.” Queue completion messages so they do not cover steering or interrupt a run. At the end of a session, summarize coins actually earned, completed missions, mastery progress, and an affordable next action. Aggregate durable transaction records; do not re-credit rewards from the summary.

Write concise tutorial copy: explain where to steer, how to initiate a drift, how to recover, and why an attempt did not qualify. Prefer “Keep moving to build drift score” to “Invalid action.” Do not shame players for retries.

## 13. Architecture and verification

Use a small set of focused services/models, adapted to existing conventions: progression catalog, save store, economy transactions, effective tuning resolver, mission definitions/state, telemetry accumulator, skill detectors, daily selector, and course challenge coordinator. Keep pure evaluation and economy logic testable without ARKit. Avoid adding a dependency or giant observable singleton for every concern.

This project currently uses standalone Tools checks rather than an XCTest target. Follow that pattern for pure Swift checks unless adding a test target has a concrete benefit. Extend existing dynamics/contact checks where appropriate. Build real detectors and transactions before dressing mock values in polished UI.

Required evidence:

- Fresh save owns exactly one car and cannot play another by manipulating selection.
- Car n+1 purchase fails without car n even with sufficient coins/stars.
- All 28 IDs, 120 career missions, 168 mastery missions, and 60 daily variants validate; no duplicate IDs or missing source cars.
- A prerequisite graph/reachability check proves all 120 stars are reachable before the final car unlock, and paint/upgrade spending cannot soft-lock progression.
- Duplicate purchase/reward callbacks, interruption during write, and relaunch preserve exact wallet accounting.
- All levels are bounded, derived from stock each time, and never compound on previously modified tuning.
- Test all 5^5 part-level combinations for finite/clamped tuning across each distinct profile; drive representative extremes and troublesome mixed builds through meaningful dynamics checks.
- Valid drift, clean exit, spinout, stationary wheelspin, reverse circle, wall pushing, noisy slip, and collision traces produce the intended results.
- Valid standard/perfect donut traces count correctly; heading-only spins, center drift, teleportation, and repeated threshold samples do not.
- Swept gate crossing works at low frame rate; skipped/reversed gates and stationary overlap fail correctly.
- Parking requires footprint, heading, low speed, and hold; rapid re-entry cannot farm repeated success.
- Equivalent traces at 30/60/120 rendered FPS yield equivalent progress/rewards under fixed-step integration.
- km/h/mph, UI style, effects quality, and moving the phone do not affect mission evaluation.
- Background, tracking pause, reset, reposition, course edit, and anchor loss apply the documented attempt/cumulative rules.
- Daily same-day relaunch, midnight, rollback, forward jump, time-zone change, reroll, and crash after reward commit behave consistently.
- UI checks cover small iPhones, Dynamic Type, VoiceOver, reduced motion, fixed-paint cars, unavailable previews, locked/affordable/maxed states, moved controls, manual transmission, and multiple completion notifications.

Run the unsigned Xcode build recipe from README when Xcode is available. Run existing vehicle/contact checks plus new pure logic checks. Do not claim AR behavior, haptics, tracking recovery, or driving feel verified solely by a simulator build. Provide a concise physical-device checklist for remaining work.

## 14. Execution and deliverables

First inspect and record current class tuning and catalog IDs. Then implement persistence/economy and effective tuning; mission evaluation and content; challenge layouts; garage/mission UX; daily/mastery integration; balancing and verification. Continue through all milestones in this task. Maintain working compilation between milestones and make ordinary design decisions without stopping for repeated approval.

Deliver working code, the complete data-defined content, verified lock/purchase flows, real telemetry-based rewards, bounded upgrades, migration, and polished screens. Add a concise balancing document with the final car order, exact costs/rewards, tuning endpoints, detector thresholds, and economy simulation assumptions/results. Update README to explain the actual new architecture and player experience.

At completion report what is implemented, what was tested, final first-upgrade/second-car pacing estimates, and any device-only verification still required. Do not present placeholders or untested performance claims as finished work. The result should feel like a coherent driving game where earning an upgrade is satisfying, learning a maneuver is understandable, and owning the next car means something.
