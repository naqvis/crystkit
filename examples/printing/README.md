# Printing Example

Demonstrates printing the webview content and exporting it to PDF through the built-in `Printing` plugin.

## What it demonstrates

- `printing.print` — print the current page.
- `printing.print_to_pdf` — export the page to a PDF file.
- `printing.list_printers` and `printing.show_dialog`.
- Gating printing behind the `printing:print`, `printing:pdf`, and `printing:info` capabilities.

## Run

```bash
# From the project root
crystal run examples/printing/main.cr
```
