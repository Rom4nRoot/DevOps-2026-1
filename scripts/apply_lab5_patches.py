#!/usr/bin/env python3
"""Дописывает служебные каталоги CI в .gitignore и .dockerignore (безопасно запускать повторно)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ENTRIES = {
    ".gitignore": ("# Лаб. 5: кэши и временные файлы CI", [".ci-cache/", ".trivycache/", "image.tar", "ci-summary.md", "ci-publish-summary.md"]),
    ".dockerignore": ("# Лаб. 5: файлы CI не попадают в образ", ["ci", ".ci-cache", ".trivycache", "image.tar", "ci-summary.md", "ci-publish-summary.md"]),
}

for name, (title, items) in ENTRIES.items():
    path = ROOT / name
    text = path.read_text(encoding="utf-8")
    present = {ln.strip() for ln in text.splitlines()}
    missing = [item for item in items if item not in present]
    if not missing:
        print(f"{name}: уже обновлён")
        continue
    path.write_text(text.rstrip("\n") + "\n\n" + title + "\n" + "\n".join(missing) + "\n", encoding="utf-8")
    print(f"{name}: добавлено {', '.join(missing)}")
