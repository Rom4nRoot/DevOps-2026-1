#!/usr/bin/env python3
"""Защита критических файлов и сравнение с базовой веткой (job guard в CI).

Что делает:
1. Показывает, какие критические файлы приёмки изменены (список: ci/critical-files.txt),
   чтобы такие изменения были видны в Pull Request. Отзыв владельца требует CODEOWNERS.
2. Сравнивает изменение с базой и НЕ ПРОПУСКАЕТ ослабление проверок:
   - уменьшилось число тестов или снижен порог в quality-baseline.txt или fail_under;
   - выросло число исключений ruff или появились skips в bandit;
   - в Makefile и workflow добавлены обходы (continue-on-error, || true, if: false, exit 0,
     игнорирование ошибок команды).
   Любой обход можно оставить только осознанно: метка quality-waiver на Pull Request
   (её ставит владелец репозитория), и тогда нарушения остаются в сводке как предупреждения.
Переменные окружения: CI_BASE_SHA, CI_EVENT_FILE, CI_EVENT_NAME, GITHUB_REF.
"""

import fnmatch
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZERO_SHA = "0" * 40
WAIVER_LABEL = "quality-waiver"

violations: list[str] = []
critical_changed: list[str] = []


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=False)


def show(rev: str, path: str) -> str | None:
    result = git("show", f"{rev}:{path}")
    return result.stdout if result.returncode == 0 else None


def resolve_base() -> str | None:
    sha = os.environ.get("CI_BASE_SHA", "").strip()
    if sha and sha != ZERO_SHA and git("cat-file", "-e", f"{sha}^{{commit}}").returncode == 0:
        return sha
    for ref in ("origin/main", "main"):
        merged = git("merge-base", ref, "HEAD")
        if merged.returncode == 0 and merged.stdout.strip():
            return merged.stdout.strip()
    return None


def parse_baseline(text: str | None) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            if value.strip().isdigit():
                values[key.strip()] = int(value)
    return values


def count_tests_at(rev: str | None) -> int:
    pattern = re.compile(r"^\s*def test_", re.M)
    if rev is None:
        return sum(
            len(pattern.findall(p.read_text(encoding="utf-8")))
            for p in (ROOT / "backend" / "tests").glob("test_*.py")
        )
    listing = git("ls-tree", "-r", "--name-only", rev, "backend/tests").stdout.splitlines()
    total = 0
    for name in listing:
        if re.fullmatch(r"backend/tests/test_[^/]*\.py", name):
            total += len(pattern.findall(show(rev, name) or ""))
    return total


def toml_numbers(text: str | None) -> dict[str, int]:
    """Числа из pyproject.toml, ослабление которых нужно заметить."""
    if not text:
        return {}
    tool = tomllib.loads(text).get("tool", {})
    lint = tool.get("ruff", {}).get("lint", {})
    ignores = len(lint.get("ignore", [])) + sum(
        len(v) for v in lint.get("per-file-ignores", {}).values()
    )
    return {
        "fail_under": int(tool.get("coverage", {}).get("report", {}).get("fail_under", 0)),
        "ruff_ignores": ignores,
        "bandit_skips": len(tool.get("bandit", {}).get("skips", [])),
    }


def check_thresholds(base: str) -> None:
    old_b = parse_baseline(show(base, "quality-baseline.txt"))
    new_b = parse_baseline((ROOT / "quality-baseline.txt").read_text(encoding="utf-8"))
    for key in ("COVERAGE_MIN", "TESTS_MIN", "TRACEABILITY_MIN"):
        if key in old_b and new_b.get(key, 0) < old_b[key]:
            violations.append(f"quality-baseline.txt: {key} снижен {old_b[key]} -> {new_b.get(key, 0)}")
    if "RUFF_IGNORES" in old_b and new_b.get("RUFF_IGNORES", 0) > old_b["RUFF_IGNORES"]:
        violations.append("quality-baseline.txt: увеличено допустимое число исключений ruff")

    old_t = toml_numbers(show(base, "backend/pyproject.toml"))
    new_t = toml_numbers((ROOT / "backend" / "pyproject.toml").read_text(encoding="utf-8"))
    if old_t and new_t["fail_under"] < old_t["fail_under"]:
        violations.append(f"pyproject.toml: порог покрытия снижен {old_t['fail_under']} -> {new_t['fail_under']}")
    if old_t and new_t["ruff_ignores"] > old_t["ruff_ignores"]:
        violations.append("pyproject.toml: добавлены исключения ruff")
    if old_t and new_t["bandit_skips"] > old_t["bandit_skips"]:
        violations.append("pyproject.toml: добавлены исключения bandit (skips)")

    old_n, new_n = count_tests_at(base), count_tests_at(None)
    if new_n < old_n:
        violations.append(f"Тестов стало меньше: {old_n} -> {new_n} (удалено {old_n - new_n})")


BYPASS_PATTERNS = [
    ("continue-on-error: true (ошибка шага игнорируется)", re.compile(r"continue-on-error\s*:\s*true")),
    ("|| true (ошибка команды скрывается)", re.compile(r"\|\|\s*true\b")),
    ("if: false (шаг или job отключён)", re.compile(r"\bif\s*:\s*(false\b|\$\{\{\s*false)")),
    ("exit 0 (принудительный успех)", re.compile(r"^\s*(run\s*:\s*)?exit\s+0\b")),
    ("--exit-code 0 (анализатор не блокирует)", re.compile(r"--exit-code[ =]0\b")),
    ("игнорирование ошибок команды Makefile (префикс -)", re.compile(r"^\t-")),
]
JUSTIFIED = re.compile(r"#\s*justified:\s*\S.{9,}")


def check_bypasses(base: str) -> None:
    diff = git("diff", "--no-color", "-U0", base, "HEAD", "--", "Makefile", ".github").stdout
    current = ""
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            text = line[1:]
            if JUSTIFIED.search(text):
                continue
            for label, pattern in BYPASS_PATTERNS:
                if label.startswith("игнорирование") and current != "Makefile":
                    continue
                if pattern.search(text):
                    violations.append(f"{current}: добавлено «{text.strip()}» - {label}")


def load_patterns(rev: str | None) -> list[str]:
    path = "ci/critical-files.txt"
    text = (ROOT / path).read_text(encoding="utf-8") if rev is None else (show(rev, path) or "")
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]


def find_critical_changes(base: str) -> None:
    patterns = set(load_patterns(None)) | set(load_patterns(base))
    changed = git("diff", "--name-only", base, "HEAD").stdout.splitlines()
    for name in changed:
        if any(fnmatch.fnmatch(name, pattern) for pattern in patterns):
            critical_changed.append(name)


def event_labels() -> set[str]:
    path = os.environ.get("CI_EVENT_FILE")
    if not path or not Path(path).exists():
        return set()
    event = json.loads(Path(path).read_text(encoding="utf-8"))
    return {label["name"] for label in event.get("pull_request", {}).get("labels", [])}


def write_summary(base: str | None, waived: bool, soft: bool) -> None:
    lines = ["## Защита критических файлов", ""]
    if base is None:
        lines.append("База для сравнения не найдена: проверки ослабления не выполнялись.")
    else:
        lines.append(f"Сравнение с `{base[:7]}`.")
        lines.append("")
        if critical_changed:
            lines += ["### Изменены критические файлы (нужен отзыв владельца)", ""]
            lines += [f"- `{name}`" for name in critical_changed]
        else:
            lines.append("Критические файлы не менялись.")
        lines.append("")
        if violations:
            title = "Ослабление проверок (разрешено меткой quality-waiver)" if waived else "Ослабление проверок"
            if soft:
                title = "Замечания к уже слитому изменению"
            lines += [f"### {title}", ""]
            lines += [f"- {item}" for item in violations]
        else:
            lines.append("Ослабления проверок не обнаружено.")
    (ROOT / "ci-summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    base = resolve_base()
    if base is None:
        print("::warning title=guard::База для сравнения не найдена, проверки ослабления пропущены")
        write_summary(None, False, False)
        return 0

    find_critical_changes(base)
    check_thresholds(base)
    check_bypasses(base)

    waived = WAIVER_LABEL in event_labels()
    soft = os.environ.get("CI_EVENT_NAME") == "push" and os.environ.get("GITHUB_REF") == "refs/heads/main"
    write_summary(base, waived, soft)

    for name in critical_changed:
        print(f"::warning file={name},title=Критический файл::Изменён критический файл приёмки, нужен отзыв владельца")
    for item in violations:
        level = "warning" if (waived or soft) else "error"
        print(f"::{level} title=Ослабление проверок::{item}")

    print(f"Критических файлов изменено: {len(critical_changed)}; нарушений: {len(violations)}")
    if violations and not (waived or soft):
        print("Изменение ослабляет проверки. Исправьте или попросите владельца поставить метку quality-waiver.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
