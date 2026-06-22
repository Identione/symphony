import os
import sys
import sqlite3
import tempfile
import subprocess
from datetime import datetime
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))


def test_script_exists():
    """Test that the write_date.py script exists in scripts folder."""
    script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'
    assert script_path.exists(), f"Script {script_path} does not exist"


def test_script_prints_date(capsys):
    """Test that the script prints the current date to stdout."""
    script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'
    result = subprocess.run(
        [sys.executable, str(script_path)],
        capture_output=True,
        text=True,
        cwd=str(Path(__file__).parent.parent)
    )
    assert result.returncode == 0, f"Script failed: {result.stderr}"

    # Verify that output contains a date in YYYY-MM-DD format
    output = result.stdout.strip()
    assert output, "Script did not print anything"

    # Check if output contains a date pattern
    import re
    date_pattern = r'\d{4}-\d{2}-\d{2}'
    assert re.search(date_pattern, output), f"Script output does not contain date: {output}"


def test_script_creates_database():
    """Test that the script creates a SQLite database."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'dates.db')
        script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'

        env = os.environ.copy()
        env['DATES_DB'] = db_path

        result = subprocess.run(
            [sys.executable, str(script_path)],
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).parent.parent),
            env=env
        )
        assert result.returncode == 0, f"Script failed: {result.stderr}"

        # Verify database was created
        assert os.path.exists(db_path), f"Database {db_path} was not created"


def test_script_creates_dates_table():
    """Test that the script creates a dates table with correct schema."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'dates.db')
        script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'

        env = os.environ.copy()
        env['DATES_DB'] = db_path

        result = subprocess.run(
            [sys.executable, str(script_path)],
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).parent.parent),
            env=env
        )
        assert result.returncode == 0, f"Script failed: {result.stderr}"

        # Verify table exists and has correct schema
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='dates'")
        table = cursor.fetchone()
        assert table is not None, "Table 'dates' was not created"

        # Verify table structure
        cursor.execute("PRAGMA table_info(dates)")
        columns = {col[1]: col[2] for col in cursor.fetchall()}
        assert 'date' in columns, "Column 'date' not found in 'dates' table"

        conn.close()


def test_script_writes_date_to_database():
    """Test that the script writes the current date to the database."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'dates.db')
        script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'

        env = os.environ.copy()
        env['DATES_DB'] = db_path

        result = subprocess.run(
            [sys.executable, str(script_path)],
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).parent.parent),
            env=env
        )
        assert result.returncode == 0, f"Script failed: {result.stderr}"

        # Verify data was written to database
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        cursor.execute("SELECT COUNT(*) FROM dates")
        count = cursor.fetchone()[0]
        assert count > 0, "No rows found in 'dates' table"

        cursor.execute("SELECT date FROM dates ORDER BY rowid DESC LIMIT 1")
        stored_date = cursor.fetchone()[0]
        assert stored_date is not None, "No date value found in database"

        # Verify the stored date is today's date (in YYYY-MM-DD format)
        today = datetime.now().strftime('%Y-%m-%d')
        assert stored_date == today, f"Expected {today}, got {stored_date}"

        conn.close()


def test_script_multiple_executions():
    """Test that the script can be run multiple times and writes new rows."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'dates.db')
        script_path = Path(__file__).parent.parent / 'scripts' / 'write_date.py'

        env = os.environ.copy()
        env['DATES_DB'] = db_path

        # Run script twice
        for _ in range(2):
            result = subprocess.run(
                [sys.executable, str(script_path)],
                capture_output=True,
                text=True,
                cwd=str(Path(__file__).parent.parent),
                env=env
            )
            assert result.returncode == 0, f"Script failed: {result.stderr}"

        # Verify that at least 2 rows exist (same date but separate entries)
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        cursor.execute("SELECT COUNT(*) FROM dates")
        count = cursor.fetchone()[0]
        assert count >= 2, f"Expected at least 2 rows, got {count}"

        conn.close()
