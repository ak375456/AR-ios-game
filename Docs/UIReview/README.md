# September 30 UI review

Historical baseline. See the [October 1 redesign](October1/README.md) for the
current interface, which removes the mission overlay and required drift goals.

Native iPhone 13 mini simulator renders. Garage uses the real app. Driving
screens use the shipping views with isolated fixture state and a gray backdrop;
they verify layout, not AR tracking or touch interaction. The three opening
career goals are completed in these fixtures, reproducing the reported stale
checkmarks. An unfinished drift goal replaces them automatically.

- [Garage](garage.png): no first-launch dialog; plain header and tab controls.
- [Driving](driving.png): one toolbar row and one compact unfinished goal.
- [Focus](focus.png): toolbar and goal hidden; eye restores them.
- [Progress](progress.png): populated optional sheet, no collapse toggle.
- [Moved controls](moved-controls.png): moved handbrake/manual shifter respected.

See [verification](../Verification.md) for commands, automated checks and
remaining physical-device testing. No layout image demonstrates AR behavior.
