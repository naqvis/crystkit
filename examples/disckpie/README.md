# DiskPie

DiskPie is an open-source disk usage analyzer inspired by [SquirrelDisk](https://github.com/adileo/squirreldisk). It scans directories recursively, visualizes disk usage with an interactive sunburst chart, and lets you delete unwanted files — all from a single window.

An open-source alternative to WinDirStat, WizTree, TreeSize, and DaisyDisk.

## Features

- **Fast recursive scanning** — async Crystal backend with real-time progress tracking
- **Interactive sunburst chart** — d3.js visualization with smooth zoom transitions, click to drill down, click center to go back
- **Sortable file table** — shows children sorted by size with percentage bars
- **Drag-to-delete** — drag files/folders to the collector bar, batch delete them
- **Breadcrumb navigation** — click any ancestor in the breadcrumb to jump to that level
- **System tray** — minimizes to tray, tray menu with quick actions
- **Right-click context menu** — "Show in folder" opens the native file explorer
- **Cross-platform** — macOS, Windows, Linux from a single codebase
- **Capability-based security** — explicit permissions for filesystem access, deletion, and system info

### Run from source

```bash
# From the crystkit root
crystal run examples/disckpie/main.cr
```
