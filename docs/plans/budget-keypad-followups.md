# Budget assignment keypad — follow-ups

Status: backlog. Deferred polish for `BudgetAssignmentKeypad` in
`Actualist/Features/Budget/BudgetView.swift`. (Accessibility labels, haptics, design-system
fonts/constants, and the input-length cap were already done.)

## 1. Error message causes layout shift (deferred from keypad review item #7)

The inline error `Text` lives inside the keypad `VStack`, between the toolbar row and the digit
grid. When an error appears/disappears the grid moves and the keypad's measured height changes,
which can re-trigger the scroll-to-keep-category-visible logic and looks janky.

Fix direction: give the error area a stable footprint so showing/hiding it doesn't reflow the
grid or change the measured height — e.g. reserve space with a fixed/min-height container, or
move the error outside the height-measured region (out of the `.readHeight` subtree). Verify the
keypad height preference (`BudgetAssignmentKeypadHeightKey`) and the keypad-top measurement stay
stable across error show/hide.

## 2. Dead placeholder controls shipped as prominent UI (keypad review item #2, not yet chosen)

"Auto-Assign", "Move Money", and "Details" render at full prominence (68pt tall) but are
`.disabled(true)` with empty actions — they look like real features and do nothing, and they eat
vertical space that worsens keypad occlusion. Hide them until implemented, or visibly mark them
as coming-soon.
