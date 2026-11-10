# Context Menu Example

Demonstrates context-sensitive native menus for links, images, text selection, editable areas, and the page background, using `Features::ContextMenu`.

## What it demonstrates

- `on_link`, `on_image`, `on_text_selection`, `on_editable`, and `on_default` builders.
- Checkbox items and nested submenus inside `on_editable`.
- Listening for `contextmenu.action` on the frontend with the chosen `item_id`.

## Run

```bash
# From the project root
crystal run examples/context_menu/main.cr
```

Right-click in each labelled section to see the matching menu; the selected action id is printed in the output box.
