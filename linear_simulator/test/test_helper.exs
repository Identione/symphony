# This simulator uses file-backed SQLite with explicit scenario reset instead
# of the SQL sandbox (docs/linear-sim.md §5–6). Tests that touch simulator
# state reset to a known scenario in setup and must run with async: false.
ExUnit.start()
