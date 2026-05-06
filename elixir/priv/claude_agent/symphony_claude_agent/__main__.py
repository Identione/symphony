"""Allow ``python -m symphony_claude_agent`` to run the sidecar."""

from .sidecar import main

raise SystemExit(main())
