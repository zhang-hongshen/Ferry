# Accessibility

Ferry should be fully operable through the runtime Accessibility Tree (VoiceOver, keyboard, UI agents).

## Current behavior (from source)
- Native controls throughout: `List` sidebar, `Table` with disclosure rows for files, `Form` for settings and the
  connection editor, standard menus with keyboard shortcuts.
- Icon-only controls have labels: Add Connection (`addConnectionButton`), New Tab, Close Tab, Delete,
  metadata Remove buttons, existing-group menu.
- Selected state is exposed with `.isSelected` on tabs, breadcrumb segments, icon-view items, and appearance
  choices. Icon-view items read as name and kind, with an Open action. The in-place name field is labeled "Name".
- Upload progress rings and spinners are labeled "Uploading"; a failed upload's warning is labeled "Upload
  Failed" with the error as its value. Icon-view and column rows announce the same state as their value.
- Image thumbnails are labeled "Preview of <name>"; decorative large icons are hidden.
- Permissions toggles are labeled with class and right (for example "Owner Read").
- Keyboard: Space (Quick Look), Return (Rename in place; Escape cancels), ⌘O (Open), ⌘⌫ (Delete), ⌘1 / ⌘2 / ⌘3 (as Icons / as List / as Columns), ← / → between columns, ⌘A, ⌘R, ⇧⌘N, ⌘T, ⌘[ / ⌘] / ⌘↑,
  ⇧⌘U (Upload), ⌥⌘D (Download), ⌥⌘N (New Connection).
- Identifiers for UI tests: `fileTable`, `fileGrid`, `addConnectionButton`, `protocol-<kind>`.

## Not verified
The app has not yet been run with the Accessibility Inspector or VoiceOver, and there are no UI tests.
Check the file table rows (name, size, date announced), icon-view keyboard selection (arrow keys do not
move the selection yet), the tab strip, and drag-and-drop alternatives
(copy/paste covers every drag operation).
