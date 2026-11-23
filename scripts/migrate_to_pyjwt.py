#!/usr/bin/env python3
"""Замена python-jose на PyJWT (безопасно запускать повторно).

Причина: pip-audit нашёл в python-jose неисправленные уязвимости (PYSEC-2026-4298), а зависимость
ecdsa (PYSEC-2026-1325) подтягивается только через неё. PyJWT поддерживается и не тянет ecdsa.
Меняется только библиотека: логика токенов (HS256, срок действия, проверка подписи) остаётся прежней.
После запуска: make lock, make format, make verify.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace(path: str, old: str, new: str) -> None:
    file = ROOT / path
    raw = file.read_bytes().decode("utf-8")
    eol = "\r\n" if "\r\n" in raw else "\n"
    old_n, new_n = old.replace("\n", eol), new.replace("\n", eol)
    if old_n not in raw:
        print(f"{path}: уже обновлено или нет фрагмента {old!r}")
        return
    file.write_bytes(raw.replace(old_n, new_n).encode("utf-8"))
    print(f"{path}: заменено {old!r}")


replace("backend/app/auth.py", "from jose import JWTError, jwt", "import jwt\nfrom jwt import PyJWTError")
replace("backend/app/auth.py", "except JWTError:", "except PyJWTError:")

tests = "backend/tests/test_unit_auth_and_schemas.py"
replace(tests, "from jose import JWTError, jwt\nfrom jose.exceptions import ExpiredSignatureError\n",
        "import jwt\nfrom jwt import ExpiredSignatureError, PyJWTError\n")
replace(tests, "pytest.raises(JWTError)", "pytest.raises(PyJWTError)")

replace("backend/requirements.in", "python-jose[cryptography]>=3.3", "PyJWT>=2.9")
