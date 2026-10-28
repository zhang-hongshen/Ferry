# UI

Use this reference whenever you add or change user-facing UI. These principles are mandatory and must also be written into the project's root `AGENTS.md` (see [Required `AGENTS.md` Section](#required-agentsmd-section)), so that every later agent follows them.

## Core Principle: The Layout Explains Itself

The interface should communicate what something is and what it does through structure, controls, grouping, position, icons, and state — not through explanatory prose. If a screen needs a sentence to explain how to use it, fix the layout first.

Models tend to add explanatory text everywhere. Treat that tendency as a defect to correct, not a helpful default.

## Do Not Add

- **Secondary labels or subtitles** under a control that restate its title (e.g. "Appearance" with a caption "Choose how the app looks").
- **Description or helper text** that explains an obvious control (toggles, pickers, text fields, standard buttons).
- **Section headers or footers** that repeat the label of the only row inside them, or that exist only to introduce one control.
- **Instructional banners, empty-state paragraphs, or onboarding copy** that describe what the user can plainly see.
- **Placeholder text that is a full sentence**; use a short example value or a single noun.
- **Tooltips / `.help` text** that merely duplicate the visible label.
- **Redundant confirmation text** after an action whose result is already visible in the UI.

## Prefer Instead

- **Precise titles.** Use one short, specific noun or verb for each control or row. Rename vague labels rather than adding a description beside them.
- **Structure.** Use grouping, alignment, order, and spacing to show relationships. One row per setting; label on the leading edge, control on the trailing edge.
- **Native controls.** A toggle, picker, stepper, or segmented control already communicates its behavior; do not narrate it.
- **Visual previews and state.** Show the effect (thumbnail, live preview, selected state, disabled state) instead of describing it.
- **Standard SF Symbols** where an icon is clearer than words, paired with a visible or accessibility label as appropriate.
- **Progressive disclosure.** Move rare or advanced options to a secondary place instead of explaining them inline.

## When Text Is Justified

Explanatory text is allowed only when the information cannot be inferred from the UI and is needed to avoid a real mistake, for example:

- A destructive or irreversible consequence that is not obvious ("Deleting removes all files from iCloud").
- A non-obvious constraint or requirement (a permission the user must grant, a format the input must match).
- An error message that tells the user what went wrong and what to do.

Keep such text to one short sentence, place it next to the relevant control, and use the platform's standard secondary style. If you are unsure whether text is needed, leave it out.

## Accessibility Is Not Visible Text

Removing visible descriptions must not weaken accessibility. Provide `accessibilityLabel`, `accessibilityValue`, and `accessibilityHint` where they add information for assistive technologies; these do not appear on screen. Follow [`Features/Accessibility.md`](Features/Accessibility.md).

## Review Checklist

Before finishing any UI change, check each visible string and ask: "If I delete this, does the user lose information they cannot get from the layout?" If not, delete it.

- No subtitle or caption restates its control's title.
- No section header duplicates the label of its row.
- No helper text describes a standard control's behavior.
- Every remaining explanatory sentence meets [When Text Is Justified](#when-text-is-justified).

## Required `AGENTS.md` Section

Add this section to the project's root `AGENTS.md` (adapt wording to the project, but keep every rule). If the project has `Docs/`, also copy this reference as `Docs/UI.md` and link it from `Docs/AGENTS.md`.

```markdown
## UI Principles
- Let layout, grouping, native controls, icons, and visible state explain the UI. Do not explain the UI with prose.
- Do not add secondary labels, subtitles, captions, descriptions, helper text, or tooltips that restate a title or describe an obvious control.
- Do not add section headers or footers that repeat the only row's label or just introduce a single control.
- Fix unclear UI by renaming or restructuring, not by adding explanatory text.
- Add visible explanatory text only for non-obvious consequences, constraints, or errors; keep it to one short sentence.
- Keep accessibility labels, values, and hints; they are not visible text and are still required.
- Before finishing a UI change, delete every visible string whose removal loses no information.
```
