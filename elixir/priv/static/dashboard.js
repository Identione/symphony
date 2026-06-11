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

  function buildLabel(node) {
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

    return lines.join("\n");
  }

  function toElements(graph) {
    var nodes = (graph && graph.nodes) || [];
    var edges = (graph && graph.edges) || [];

    var nodeElements = nodes.map(function (node) {
      return {
        group: "nodes",
        data: {
          id: node.id,
          label: buildLabel(node),
          state_type: node.state_type || "",
          symphony_status: node.symphony_status || "",
          placeholder: node.placeholder ? "true" : "false",
          url: node.url || ""
        }
      };
    });

    var edgeElements = edges.map(function (edge, index) {
      return {
        group: "edges",
        data: {
          id: "e" + index + "-" + edge.source + "-" + edge.target,
          source: edge.source,
          target: edge.target
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
          selector: "edge",
          style: {
            width: 2,
            "line-color": "#94a3b8",
            "target-arrow-color": "#94a3b8",
            "target-arrow-shape": "triangle",
            "curve-style": "bezier"
          }
        }
      ],
      layout: {
        name: "dagre",
        rankDir: "TB",
        nodeSep: 30,
        rankSep: 60
      },
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
