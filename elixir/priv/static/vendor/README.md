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

`cytoscape-dagre` self-registers when `window.cytoscape` is present, so the
layout layer becomes available as soon as cytoscape + dagre are both loaded.
