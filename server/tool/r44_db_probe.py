#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R44 预演用的库探针：只读地打印一份 zaoji.db 的 schema 版本与 v8 落点。

写成独立文件而不是在 ps1 里塞 here-string：PowerShell 5.1 的 `@"` 收尾必须顶格，
内联多行脚本在 -File 调用里极易静默解析错——错一条就当预演过了，这比不预演更危险。

用法：python server/tool/r44_db_probe.py <zaoji.db 路径>
输出（单行，供 ps1 正则读）：
  schema=8 tables=['ai_prompts', 'ai_runs'] v8_cols=['run_ref', 'summary'] synced=none
"""
import sqlite3
import sys

db = sys.argv[1]
c = sqlite3.connect(db)

row = c.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()
schema = row[0] if row else None

tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
new_tables = [t for t in ('ai_prompts', 'ai_runs') if t in tables]

cols = {r[1] for r in c.execute('PRAGMA table_info(ai_usage)')}
v8_cols = [t for t in ('run_ref', 'summary') if t in cols]

# 业务表才进 change_log（列名是 tbl，不是 table_name）：新表若出现在这里，
# 说明 scope 标错了、serverOnly 的表被推给了客户端
synced = []
if 'change_log' in tables:
    try:
        synced = [r[0] for r in c.execute(
            "SELECT DISTINCT tbl FROM change_log "
            "WHERE tbl IN ('ai_prompts','ai_runs','ai_usage')")]
    except sqlite3.Error:
        synced = ['query-failed']

print('schema=%s tables=%s v8_cols=%s synced=%s' % (
    schema, new_tables or 'none', v8_cols or 'none', synced or 'none'))
