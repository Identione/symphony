#!/usr/bin/env python3
"""
Script that prints the current date and writes it to a SQLite database.
"""

import os
import sqlite3
from datetime import datetime


def get_db_path():
    """Get the database path from environment or use default."""
    return os.environ.get('DATES_DB', 'dates.db')


def create_dates_table(connection):
    """Create the dates table if it doesn't exist."""
    cursor = connection.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS dates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    connection.commit()


def write_date_to_db(connection, date_str):
    """Write the date to the database."""
    cursor = connection.cursor()
    cursor.execute('INSERT INTO dates (date) VALUES (?)', (date_str,))
    connection.commit()


def main():
    """Main function."""
    current_date = datetime.now().strftime('%Y-%m-%d')

    print(current_date)

    db_path = get_db_path()
    connection = sqlite3.connect(db_path)

    try:
        create_dates_table(connection)
        write_date_to_db(connection, current_date)
    finally:
        connection.close()


if __name__ == '__main__':
    main()
