"""Contrôle d'une base de sessions OpenCode restaurée (15.B.1) : intégrité SQLite et nombre de sessions, en lecture seule."""
import sqlite3
import sys

db = sys.argv[1] if len(sys.argv) > 1 else "/s/.local/share/opencode/opencode.db"
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
print(con.execute("pragma integrity_check").fetchone()[0])
tables = [r[0] for r in con.execute("select name from sqlite_master where type='table' and name like '%session%' order by length(name)")]
if not tables:
    print("aucune-table -1")
else:
    print(tables[0], con.execute(f'select count(*) from "{tables[0]}"').fetchone()[0])
