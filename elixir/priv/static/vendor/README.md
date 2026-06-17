# Vendored Dashboard JS Assets

The dashboard ships browser libraries it does not author. Each file is a
minified UMD build downloaded from npm/unpkg at a pinned version and embedded
into the compiled BEAM via `SymphonyElixirWeb.StaticAssets`. Refresh the file
in place when bumping a version and update the row below.

| Library          | Version | License | Source URL                                                | Local path                                      |
| ---------------- | ------- | ------- | --------------------------------------------------------- | ----------------------------------------------- |
| cytoscape        | 3.30.2  | MIT     | https://unpkg.com/cytoscape@3.30.2/dist/cytoscape.min.js  | `vendor/cytoscape/cytoscape.min.js`             |
| dagre            | 0.8.5   | MIT     | https://unpkg.com/dagre@0.8.5/dist/dagre.min.js           | `vendor/dagre/dagre.min.js`                     |
| cytoscape-dagre  | 2.5.0   | MIT     | https://unpkg.com/cytoscape-dagre@2.5.0/cytoscape-dagre.js | `vendor/cytoscape-dagre/cytoscape-dagre.js`     |
| layout-base      | 2.0.1   | MIT     | https://unpkg.com/layout-base@2.0.1/layout-base.js        | `vendor/layout-base/layout-base.js`             |
| cose-base        | 2.2.0   | MIT     | https://unpkg.com/cose-base@2.2.0/cose-base.js            | `vendor/cose-base/cose-base.js`                 |
| cytoscape-fcose  | 2.2.0   | MIT     | https://unpkg.com/cytoscape-fcose@2.2.0/cytoscape-fcose.js | `vendor/cytoscape-fcose/cytoscape-fcose.js`     |

`cytoscape-dagre` self-registers when `window.cytoscape` is present, so the
layout layer becomes available as soon as cytoscape + dagre are both loaded.

`cytoscape-fcose` is the compound-aware layout used to render sub-issue
containers (parent issues as bounding boxes around their sub-issues). It
self-registers as layout `fcose` when `window.cytoscape` is present, and resolves
its dependency chain through globals — load order must be `layout-base` →
`cose-base` → `cytoscape-fcose` (each after `cytoscape`). The dashboard falls
back to `dagre` if `fcose` is unavailable.
