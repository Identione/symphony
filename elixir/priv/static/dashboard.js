// Symphony dashboard LiveView hooks. Loaded as a defer'd script tag from the
// root layout; the inline LiveSocket init reads `window.SymphonyHooks` after
// this file executes.
(function () {
  "use strict";

  var STATE_TYPE_ICONS = {
    triage: "⚠",
    backlog: "◌",
    unstarted: "○",
    started: "◐",
    completed: "●",
    canceled: "✕"
  };

  var STATE_TYPE_FILLS = {
    triage: "#fde68a",
    backlog: "#e2e8f0",
    unstarted: "#dbeafe",
    started: "#bfdbfe",
    completed: "#bbf7d0",
    canceled: "#fecaca"
  };

  var STATUS_BORDERS = {
    running: "#16a34a",
    retrying: "#d97706",
    blocked: "#dc2626",
    waiting_on_blockers: "#7c3aed"
  };

  function iconForStateType(type) {
    return STATE_TYPE_ICONS[type] || "○";
  }

  function fillForStateType(type) {
    return STATE_TYPE_FILLS[type] || "#e2e8f0";
  }

  function borderForStatus(status) {
    return STATUS_BORDERS[status] || "#94a3b8";
  }

  // Workspace paths are long absolute paths; show only the trailing segment(s)
  // so a node stays compact. The full value is available via the JSON API.
  function workspaceDisplay(path) {
    if (!path) return "-";
    var segments = path.split("/").filter(function (s) {
      return s !== "";
    });
    if (segments.length === 0) return path;
    return ".../" + segments.slice(-2).join("/");
  }

  // fcose is the compound-aware layout that nests sub-issues inside their
  // parent container; dagre (no compound support) is the fallback used only if
  // fcose failed to load/register.
  function graphLayout() {
    if (typeof window.cytoscapeFcose !== "undefined") {
      return {
        name: "fcose",
        animate: false,
        quality: "default",
        randomize: true,
        nodeSeparation: 80,
        idealEdgeLength: 90,
        nestingFactor: 0.1,
        packComponents: true
      };
    }

    return { name: "dagre", rankDir: "TB", nodeSep: 30, rankSep: 60 };
  }

  // Container (parent/umbrella) nodes summarize their sub-issues rather than a
  // dispatch session: identifier, title, and aggregate completion.
  function buildContainerLabel(node) {
    var lines = ["▦ " + (node.issue_identifier || ""), node.title || ""];

    if (typeof node.child_total === "number") {
      lines.push((node.child_done || 0) + "/" + node.child_total + " sub-issues done");
    }

    return lines.join("\n");
  }

  function buildLabel(node) {
    if (node.kind === "container") {
      return buildContainerLabel(node);
    }

    var icon = iconForStateType(node.state_type);
    var lines = [
      icon + " " + (node.state || ""),
      (node.issue_identifier || "") + " · " + (node.priority_label || ""),
      node.title || ""
    ];

    if (node.symphony_status_label) {
      var prefix = "";
      switch (node.symphony_status) {
        case "running":
          prefix = "▶ ";
          break;
        case "retrying":
          prefix = "↻ ";
          break;
        case "blocked":
          prefix = "⏸ ";
          break;
        case "waiting_on_blockers":
          prefix = "⛓ ";
          break;
        default:
          prefix = "";
      }

      lines.push(prefix + node.symphony_status_label);
    }

    // Unmanaged sub-issues: this instance would not pick them up. Show the
    // Linear identifier (already above) plus exactly what must change, and skip
    // the session/workspace lines (there is no agent for them).
    if (node.managed === false) {
      lines.push("⚠ Not managed by this instance");

      if (node.requirements && node.requirements.length) {
        node.requirements.forEach(function (requirement) {
          lines.push("• " + requirement);
        });
      } else if (node.inactive_reason) {
        lines.push("ⓘ " + node.inactive_reason);
      }

      return lines.join("\n");
    }

    lines.push("⧉ " + (node.session_id || "-"));
    lines.push("⌂ " + workspaceDisplay(node.workspace_path));

    if (node.symphony_status !== "running" && node.inactive_reason) {
      lines.push("ⓘ " + node.inactive_reason);
    }

    return lines.join("\n");
  }

  function toElements(graph) {
    var nodes = (graph && graph.nodes) || [];
    var edges = (graph && graph.edges) || [];

    // Index node ids so a sub-issue's `parent` only nests it into a container
    // that is actually present — a container dropped by the node cap must not
    // leave a dangling compound reference (Cytoscape would reject it).
    var nodeIds = {};
    nodes.forEach(function (node) {
      nodeIds[node.id] = true;
    });

    var nodeElements = nodes.map(function (node) {
      var data = {
        id: node.id,
        label: buildLabel(node),
        state_type: node.state_type || "",
        symphony_status: node.symphony_status || "",
        placeholder: node.placeholder ? "true" : "false",
        kind: node.kind || "issue",
        managed: node.managed === false ? "false" : "true",
        url: node.url || ""
      };

      if (node.parent && nodeIds[node.parent]) {
        data.parent = node.parent;
      }

      return { group: "nodes", data: data };
    });

    var edgeElements = edges.map(function (edge, index) {
      return {
        group: "edges",
        data: {
          id: "e" + index + "-" + edge.source + "-" + edge.target,
          source: edge.source,
          target: edge.target,
          label: edge.kind || "blocks"
        }
      };
    });

    return nodeElements.concat(edgeElements);
  }

  function render(hook) {
    if (!window.cytoscape) return;

    var raw = hook.el.dataset.graph || "{}";
    var graph;

    try {
      graph = JSON.parse(raw);
    } catch (err) {
      return;
    }

    var container = hook.el.querySelector("#dependency-graph-canvas");
    if (!container) return;

    if (hook._cy) {
      hook._cy.destroy();
      hook._cy = null;
    }

    var elements = toElements(graph);

    hook._cy = window.cytoscape({
      container: container,
      elements: elements,
      style: [
        {
          selector: "node",
          style: {
            shape: "round-rectangle",
            label: "data(label)",
            "text-wrap": "wrap",
            "text-valign": "center",
            "text-halign": "center",
            "font-size": "11px",
            "background-color": function (ele) {
              return fillForStateType(ele.data("state_type"));
            },
            "border-width": 2,
            "border-color": function (ele) {
              return borderForStatus(ele.data("symphony_status"));
            },
            "border-style": function (ele) {
              return ele.data("placeholder") === "true" ? "dashed" : "solid";
            },
            padding: "10px",
            width: "label",
            height: "label"
          }
        },
        {
          // Unmanaged sub-issues: dashed amber treatment so it is visually clear
          // this instance will not pick them up until their attributes change.
          selector: "node[managed = 'false']",
          style: {
            "background-color": "#fff7ed",
            "border-color": "#d97706",
            "border-style": "dashed"
          }
        },
        {
          // Container (parent/umbrella) node: a translucent box that Cytoscape
          // sizes to enclose its sub-issues, with the title pinned to the top.
          selector: "node[kind = 'container']",
          style: {
            shape: "round-rectangle",
            "background-color": "#64748b",
            "background-opacity": 0.08,
            "border-width": 2,
            "border-color": "#64748b",
            "border-style": "solid",
            "text-valign": "top",
            "text-halign": "center",
            "font-size": "11px",
            "font-weight": "bold",
            color: "#334155",
            padding: "18px"
          }
        },
        {
          selector: "edge",
          style: {
            width: 2,
            "line-color": "#94a3b8",
            "target-arrow-color": "#94a3b8",
            "target-arrow-shape": "triangle",
            "curve-style": "bezier",
            label: "data(label)",
            "font-size": "9px",
            "text-rotation": "autorotate",
            color: "#475569",
            "text-background-color": "#ffffff",
            "text-background-opacity": 1,
            "text-background-padding": "2px"
          }
        }
      ],
      layout: graphLayout(),
      wheelSensitivity: 0.2
    });

    hook._cy.on("tap", "node", function (event) {
      var url = event.target.data("url");
      if (url) {
        window.open(url, "_blank", "noopener,noreferrer");
      }
    });

    hook._lastGraph = raw;
  }

  window.SymphonyHooks = window.SymphonyHooks || {};

  window.SymphonyHooks.DependencyGraph = {
    mounted: function () {
      render(this);
    },
    updated: function () {
      var next = this.el.dataset.graph || "{}";
      if (next === this._lastGraph) return;
      render(this);
    },
    destroyed: function () {
      if (this._cy) {
        this._cy.destroy();
        this._cy = null;
      }
    }
  };
})();
