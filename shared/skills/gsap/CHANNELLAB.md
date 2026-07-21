# ChannelLab Adaptation

This is an application layer, not a rewrite of the official GSAP rules. Keep upstream API, lifecycle, accessibility, and performance guidance in the adjacent skill documents authoritative.

## Applies to

- MVP dashboard state changes: queue reflow, card focus, panel expand/collapse, and configuration-preview movement.
- Public product and campaign pages where motion establishes hierarchy, responds to an action, or explains a state transition.

## Does not apply to

- PPT/deck production. Use the presentation/design workflow instead; do not ship a browser animation library as a deck substitute.
- Decorative motion without a one-sentence purpose. State the purpose first: hierarchy, feedback, continuity, or explanation.

## Dashboard motion contract

1. Use a `gsap.timeline()` when more than one visual state changes; label semantic beats such as `"select"` and `"settle"`.
2. Animate compositor-friendly `x`, `y`, `scale`, `rotation`, `opacity`, and `autoAlpha`; do not animate layout properties merely to move an element.
3. Make rapid replay safe: kill or overwrite the previous timeline before starting a new state transition.
4. Respect `prefers-reduced-motion`. The reduced path must still communicate the final state without a long transition.
5. Pair every motion with a stable semantic state (text, ARIA state, or both); animation is an enhancement, never the only signal.

## Pane-scoped token compatibility

MVP dashboard panes own their visual tokens. Do not introduce global animation colors, dimensions, or z-index values. Scope any motion-only variables beneath the pane root, for example:

```css
.queue-pane {
  --pane-accent: var(--queue-accent);
  --pane-lift: 12px;
}
```

GSAP may animate the pane's descendants, but it must not mutate shared/root token values. Prefer `gsap.context()` (or framework cleanup equivalents) scoped to the pane component so a re-render or unmount reverts only that pane's inline animation state.

## Review checklist

- Is the motion motivated and interruptible?
- Does the implementation use a timeline/easing/stagger where the state change warrants it, instead of a CSS-transition imitation?
- Does it preserve reduced-motion and final-state readability?
- Are targets scoped and cleaned up for the framework?
- Are pane tokens local and production UI untouched until a dedicated implementation task exists?
