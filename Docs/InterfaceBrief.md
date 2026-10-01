> Design reference supplied by the owner on October 1. The direct request takes priority: no mission indicator during driving, and no required drift goals. Current implementation and verification are documented in README and UIReview/October1.

Redesign the UI and UX of my existing Drive AR game. Inspect the attached screenshots of my game, Subway Surfers, and Clash Royale, then implement the redesign in the actual project.

This is a substantial interface redesign. Changing colors, reducing a few corner radii, or switching everything to another rounded font is not enough.

Read the README and current source first. Preserve the implemented progression, car ownership, missions, upgrades, rewards, persistence, AR behavior, and driving physics. Existing source and saved data are authoritative for current progression values; do not restore older proposed prices or reorder cars as part of this UI task.

My highest priorities are:
1. A distinctive, cohesive mobile-game identity.
2. Much better information hierarchy and navigation.
3. A clear AR view with minimal obstruction while driving.
4. Attractive visual collections, upgrades, and missions.
5. Responsive controls and understandable interactions.

## 1. Understand what is wrong with the current screens

Use these screenshot-specific problems as the starting point:

- The garage resembles a generic dark app dashboard: violet surfaces, large rounded containers, thin stat bars, and interchangeable buttons.
- Oversized headers and repeated branding consume useful space on secondary screens.
- Missions have large cards containing several lines of text, while completed missions occupy prominent space ahead of unfinished goals.
- Chapter navigation is a row of mostly locked number buttons.
- The car collection is a text list without vehicle imagery. Players cannot visually appreciate what they are unlocking.
- The driving toolbar contains six equally prominent circular buttons.
- Capture and occlusion utilities remain prominent even during scanning.
- After placement, the mission appears in a persistent, wide, two-line box.
- The instrument cluster is a large dark slab containing two large gauges.
- Handbrake, steering, brake, accelerator, instruments, and utilities do not feel like one designed control system.

Do not solve clutter by making everything tiny. Reduce visible choices, shorten content, and reveal details at the appropriate time.

## 2. Art direction: a miniature motorsport game

Create an original “miniature motorsport garage” identity suited to the existing low-poly cars.

Take inspiration from the references:

**Subway Surfers**
- Bold, readable display typography.
- Immediately recognizable action buttons.
- Simple visual progress.
- Important gameplay information placed near screen edges.
- Detailed mission information available outside active gameplay.

**Clash Royale**
- Strong hierarchy between the featured object and surrounding actions.
- Illustrated collections that make progression desirable.
- Consistent treatment of buttons, panels, icons, and numbers.
- Clear selected, locked, available, and upgraded states.
- Tactile button depth and satisfying feedback.

Do not reproduce their artwork, logos, proprietary fonts, currencies, or exact layouts. Do not copy their promotional clutter, offers, passes, and notification badges.

My game should have its own visual language:
- Asphalt or deep navy foundations.
- Warm off-white text and selected light surfaces.
- Racing yellow for the main action.
- A restrained secondary accent for selection and progress.
- Green for an actual positive result, not random decoration.
- Small motorsport details such as a checkered finish marker, pit-board labels, or a garage-bay number.

Use these details selectively. Do not place stripes, bolts, checkers, and glowing outlines on every element.

Remove broad decorative purple gradients, generic glass cards, excessive blur, floating pills, and repetitive rounded containers. A subtle highlight on an important game button or lighting in the 3D garage is acceptable when it serves the visual design.

Prefer solid surfaces, deliberate borders, restrained corner radii, and short directional shadows. Establish a small consistent shape system.

Keep the camera feed unobstructed in gameplay. Do not place a full-screen decorative tint over AR.

## 3. Implement a real typography system

Bundle a properly licensed custom display font that suits a playful motorsport game. Use it for car names, screen titles, major numbers, and primary actions.

Pair it with a highly readable text font for objectives, descriptions, and settings. System text is acceptable for supporting copy; default system typography must not define the entire identity.

Inspect existing font assets first. If adding a font:
- Register it correctly in this project’s generated Info.plist configuration.
- Use the actual internal font name.
- Verify the rendered result is not silently falling back.
- Keep the font available offline.

Use a centralized typography scale. Use tabular digits for speed, counters, prices, and mission progress so updates do not shift the layout.

Avoid:
- Wide letter spacing everywhere.
- All-caps paragraphs.
- Thick outlined text on every label.
- Tiny gray explanatory text.
- Decorative typography for long instructions.

Do not mistake the current rounded title treatment for a complete typography system.

## 4. Give every screen one primary purpose

Keep three main destinations:
- Garage: choose and prepare the current car.
- Missions: choose the next objective.
- Collection: discover and unlock cars.

Use a designed bottom navigation dock with coherent icons, readable labels, and a clear selected state. Avoid floating capsule navigation.

Keep the dock stable and account for its full height in scroll insets. The final list item must scroll completely above it.

Use contextual titles such as “Missions” and “Collection.” Do not repeat the large DRIVE logo and subtitle on every screen.

Settings and help belong behind a compact menu. Keep currency readable, but do not add empty purchase-plus buttons or fake shop affordances.

## 5. Redesign the garage around the car

The car should be the emotional focus of the screen.

Suggested hierarchy:
1. Compact header with identity, balance, and settings.
2. Large, well-framed car preview.
3. Car name and concise class/ownership information.
4. Compact performance summary.
5. Upgrade and Paint actions.
6. One strong DRIVE button.
7. Main navigation.

Use a coherent garage stage with convincing contact shadow and restrained environmental details. Avoid enclosing the entire preview inside another rounded card.

Improve framing for every car shape, including tall vans, trucks, and low sports cars. Do not zoom so far that wheels or bumpers clip.

Allow swiping between cars with visible previous/next affordances. Maintain stable layout as names and statuses change. Browsing a locked car must not accidentally select it for driving.

Replace the giant generic stats box with a compact designed presentation. Use clear labels and consistent scales. Put deeper explanations behind a Details action.

Shorten “PLAY IN AR” to “DRIVE” if the flow already makes AR clear. Give this button a distinct shape, strong contrast, and a restrained pressed state.

Upgrade and Paint should look secondary. Neither should compete with DRIVE.

For locked cars:
- Keep the model visible.
- Show the next unmet requirement clearly.
- Offer a purchase action only when appropriate.
- Preserve actual ownership and sequential-unlock checks.

## 6. Turn Collection into a visual car collection

Replace the text-only list with a responsive two-column vehicle grid at ordinary iPhone text sizes.

Each tile contains:
- A recognizable thumbnail of the actual car.
- Car name.
- A compact ownership or lock state.
- Price or the next relevant requirement.
- A subtle progression position where useful.

Use consistent camera angle, lighting, and framing for thumbnails. Generate them from existing models and cache them. Do not run 28 live SceneKit previews inside a scrolling grid.

Owned, next-to-unlock, and future cars need distinct treatments:
- Owned: clear artwork and a small check.
- Next unlock: a deliberate highlight.
- Future: subdued artwork and lock, while keeping the car recognizable.

Do not cover locked cars with large dark overlays and multiple paragraphs.

Opening a tile shows full requirements and comparison in a detail view. Keep the grid concise.

Preserve the progression order. Scroll to the selected or next relevant car when entering where appropriate.

At large accessibility sizes, adapt to a readable single-column layout instead of crushing text into two columns.

## 7. Make missions visual, concise, and actionable

Replace the current stack of large text cards.

At the top show:
- Current chapter name.
- Compact chapter progress.
- A clear indication of what opens next.

Replace the long row of locked chapter pills with a chapter selector: current chapter with previous/next controls and an optional chapter overview.

Career, Daily, and Mastery can use simple text tabs with a clear underline or solid selected treatment. Do not introduce another oversized pill switch.

A mission row should communicate:
- Distinct mission-family icon.
- Short objective.
- Progress.
- Reward.
- One relevant action.

Example:
“Hold a drift”
“0.0 / 0.6 s”
Coin icon + “25”
“Track”

Use actual rewards and targets from the model.

Keep flavor titles in mission details if they make the overview harder to understand. “A Little Sideways” is less useful during driving than “Drift · 0.0/0.6 s.”

Rewrite implementation-style copy:
- “Drive 5 course meters while moving” → “Drive 5 m.”
- “Keep moving for 8 seconds without a significant contact” → “Drive cleanly for 8 s.”

Keep precise rules available in details. Shortened copy must accurately describe what the evaluator counts.

Prioritize active and available objectives. Move completed items into a compact Completed section with a count, while retaining access to their results.

Use recognizable family artwork for drift, donut, slalom, parking, distance, and clean driving. Build a coherent icon set with matching visual weight.

Do not add claim buttons if rewards are already credited automatically. Show that a reward was received without asking for a redundant action.

## 8. Replace the driving toolbar with contextual controls

This is the most important UX change.

Normal driving should not show six utility buttons.

Default driving layout:
- Top left: one Pause/Menu button.
- Top right: one compact tracked-objective indicator.
- Bottom left: steering.
- Bottom right: accelerator, brake, and reachable handbrake.
- Near the bottom controls: compact speed and gear information.

Only show additional controls when the active state requires them, such as manual gear shifts or stopping an ongoing recording.

Move these utilities into the pause/tools flow:
- Return to garage.
- Reset vehicle.
- Reposition vehicle.
- Build/edit course.
- Photo and video.
- Occlusion tools.
- Control layout.
- Settings and mission details.

Organize the pause panel into a small number of clear destinations, not a replacement wall of ten equally large buttons. Resume should be unmistakable.

Pause must release all held controls and suspend challenge timing/progress consistently with existing lifecycle rules.

Reset should remain quick to reach from pause. Do not require confirmation for a routine recoverable reset. Confirm leaving only when genuinely necessary to prevent loss.

### Capture must still work correctly

A video action started from pause should close the menu and resume driving into a defined recording state. Show one compact recording timer/stop control.

A photo action should enter a clean capture state or temporarily dismiss menu overlays before capturing. Do not photograph the pause menu unintentionally.

Preserve capture permissions, failure handling, and UI restoration.

If a clean-HUD option hides controls, provide an obvious reliable exit. Never leave the player in a hidden mode they cannot escape.

## 9. Replace the persistent mission box

Remove the wide two-line mission panel from normal driving.

Use a compact single-line indicator such as:
“Drift  0.0/0.6 s”

An icon and short progress line are enough. A thin progress track may sit beneath the text if it helps.

At ordinary text sizes:
- Aim for approximately 140–180 points wide.
- Keep the visible presentation approximately 28–36 points tall.
- Preserve a minimum 44-point interactive hit target.
- Do not exceed roughly half the available screen width.
- Adapt to smaller screens and safe areas.

These are layout targets, not a reason to truncate required information or defeat accessibility.

Do not permanently display both the flavor title and instructions. Show mission explanation before starting, in pause/details, or through a short first-use hint.

Tapping the indicator opens mission details through the paused state. It must not open a large live-driving card while the car continues moving.

Only one objective is shown in the driving HUD even if multiple missions track internally. Do not automatically cycle text while the player is steering.

On completion:
- Show a short “Complete +25” style acknowledgement using the actual reward.
- Keep it within the same compact region.
- Use restrained feedback.
- Queue simultaneous completions.
- Never block driving with a modal or force a reward-claim tap.

After the acknowledgement, show the next deliberately selected objective or clear the indicator. Do not replace it with a larger recommendation card.

In free drive without a pinned objective, show no mission container at all.

At large accessibility sizes, use a compact accessible mission button that opens the full details in pause rather than stacking clipped HUD text.

## 10. Reduce the instrument cluster

Replace the default full-width two-gauge slab with a compact instrument presentation.

Default:
- Prominent readable speed.
- Small unit label.
- Gear indicator.
- Slim RPM indication only when useful, especially in manual mode.

Keep the player’s choice of analog instruments available. Redesign analog as a compact option; do not delete the preference or silently overwrite existing users’ choice.

Do not make every driving session resemble a full dashboard simulator when the primary game is a miniature car in the room.

Instruments should sit near the driving controls with minimal backing and good contrast on both bright and dark camera scenes.

Avoid turning a transparent cluster into several new pill containers.

## 11. Redesign driving controls as one family

Create coherent steering, accelerator, brake, handbrake, and manual-shift visuals.

They should share:
- Border treatment.
- Material/opacity logic.
- Icon weight.
- Pressed feedback.
- Consistent visual depth.

Use recognizable pedal or driving symbols. Short labels can assist learning, but avoid large repeated words such as GO, BRAKE, and HAND dominating the screen.

Do not sacrifice touch usability for cleaner screenshots:
- Preserve simultaneous steering and pedal input.
- Keep useful touch targets and separation.
- Preserve customizable positions and sizes.
- Keep manual shift controls reachable.
- Release input when opening menus, changing modes, or losing interaction.

Do not silently relocate existing customized controls. Preserve their layout and offer the improved arrangement as the default for new users and through an explicit reset option.

Reserve utility and mission positions around the actual control frames. Visual transparency does not justify overlapping interactive hit regions.

## 12. Design each AR state separately

Do not use one persistent toolbar for every AR state.

**Scanning**
- Back button.
- Simple surface-finding guidance.
- Placement reticle when appropriate.
- No driving controls, mission card, gauges, capture toolbar, or disabled reset button.

**Ready to place**
- Clear reticle.
- Short “Tap to place” instruction.
- Essential navigation only.

**Driving**
- Minimal HUD described above.

**Paused**
- Car/input safely paused.
- Readable menu and full mission information.
- Clear Resume.

**Course editing**
- Dedicated contextual editor.
- Driving controls and mission HUD hidden.
- Obvious Done/Drive action.

**Tracking recovery**
- Necessary recovery guidance takes priority.
- Suppress competing completion notifications.
- Restore the appropriate state after recovery.

Respect existing AR behavior: opening a UI panel must not unnecessarily restart the AR session or lose the placed course.

## 13. Use an actual HUD space budget

Evaluate visible UI area in screenshots rather than guessing.

For ordinary driving, aim to keep at least approximately 70% of the camera viewport unobstructed by substantial UI surfaces, with an especially clear central region.

Treat this as a design target and document how it is measured. Do not count a huge translucent panel as unobstructed simply because the camera is faintly visible through it.

Exclude temporary pause/editor screens from this target. Adapt appropriately for accessibility and customized layouts.

The mission indicator must be a small corner element. The combined toolbar, instructions, and gauges must not fence the car into a narrow strip.

Do not implement distracting automatic HUD movement to chase the car around the screen. Use stable locations with predictable layout.

## 14. Make upgrades clear without heavy text

Use a horizontal set of compact part icons or a simple category list, followed by the selected part’s details.

Show:
- Part name.
- Current and next level.
- Current value.
- After-upgrade value directly below.
- Improvement.
- Cost.
- One Upgrade action.

Example presentation:
“Transmission · Lv 1 → 2”
“Current       36 km/h”
“After         40 km/h   +4”
“Upgrade       [coin] 25”

Examples are illustrative. All values must come from current game data and the effective tuning system.

Use segmented level marks and a short stat transition to communicate progress. Avoid a paragraph explaining each number.

For insufficient funds, show a concise shortage and a Missions action. For maximum level, show a clear completed state without a disabled purchase button pretending to be actionable.

Paint should focus on the car and actual swatches, with a clear ownership/price state. Do not put every swatch inside a labeled pill.

## 15. Implement shared components and performance discipline

Create a small cohesive design system for:
- Typography.
- Colors.
- Spacing and radii.
- Primary/secondary/icon buttons.
- Progress tracks.
- Currency display.
- Car tiles.
- Mission rows.
- Compact HUD elements.

Replace old usages consistently. Do not leave three different visual languages across garage, missions, and driving.

Use native SwiftUI shapes, vector assets, or appropriate image assets for decorative UI. Keep semantic text and functional numbers as real accessible text.

Preserve the existing UIKit driving-touch ownership model. Do not replace it with gestures that break simultaneous inputs.

Do not:
- Publish physics at 180 Hz into broad SwiftUI state.
- Rebuild car previews when a coin counter changes.
- Render a live 3D scene per collection tile.
- Add expensive full-screen blur over the camera.
- Introduce particle effects merely to decorate every screen.
- Change the asset-conversion pipeline for this redesign.

## 16. Verify the redesign visually and interactively

Capture before and after images using matching devices and states:
- Garage with an owned car.
- Garage with a locked car.
- Collection.
- Career missions.
- Daily missions.
- Upgrade comparison.
- Paint.
- Scanning.
- Placed car with an active mission.
- Driving with no pinned mission.
- Pause/tools.
- Manual transmission.
- Course editor.
- Tracking recovery.

Inspect the renders. A successful build alone does not prove the UI improved.

Check small and large iPhones, safe areas, Dynamic Island, long car names, large balances, Dynamic Type, VoiceOver, reduced motion, and moved/resized controls.

Specifically verify:
- Normal driving no longer has the six-button toolbar.
- The large persistent mission box is gone.
- Instruments no longer dominate the lower screen by default.
- Collection tiles contain real recognizable car thumbnails.
- Completed missions do not bury the next available goal.
- Bottom navigation never covers the last scroll item.
- Custom fonts actually render.
- Gameplay and utilities remain discoverable.
- No saved purchases, upgrades, missions, settings, or custom controls are lost.
- Capturing and returning from menus does not damage the AR session.
- The redesigned controls still work simultaneously on a physical device.

Implement the complete redesign, not only a style guide or mockup. Start with the driving HUD and state-specific controls, then apply the same visual language to Garage, Collection, Missions, Upgrades, and Paint.

Where simulator or device verification is unavailable, state exactly what remains unverified. Finish with a concise explanation of the changes and before/after evidence.

The final result should feel like a deliberately designed miniature driving game: recognizable typography, appealing cars, satisfying actions, clear progression, and enough open camera space to enjoy driving.