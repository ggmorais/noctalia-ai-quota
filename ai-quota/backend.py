#!/usr/bin/env python3
"""Read quota through OpenCode's authenticated CLI; never handle credentials."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time

PROVIDERS = (
    ("openai", "OpenAI", "five_hour"),
    ("anthropic", "Anthropic", "five_hour"),
    ("opencode-go", "OpenCode Go", "month"),
)


def fetch():
    command = [executable(), "api", "rpc.call", "--param", "rpcID=slkiser.opencode-quota",
               "--param", "method=refresh", "--data", json.dumps({"input": {
                   "reason": "poll", "providerIds": [p[0] for p in PROVIDERS]}})]
    # 'poll' respects the plugin's own minimum interval, reset waits and backoff.
    result = subprocess.run(command, cwd=Path.home(), capture_output=True, text=True,
                            encoding="utf-8", timeout=90, check=True)
    return json.loads(result.stdout)["output"]["snapshot"]


def timestamp(value):
    try:
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            return value / 1000
    except OverflowError:
        pass
    return None


def reset(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value if parsed.tzinfo is not None else None
    except ValueError:
        return None


def normalize(raw, now=None):
    now = time.time() if now is None else now
    if not isinstance(raw, dict) or not isinstance(raw.get("providers"), list):
        raise ValueError("Invalid snapshot")
    sources = {p["providerId"]: p for p in raw["providers"] if isinstance(p, dict) and "providerId" in p}
    result = {"ok": True, "updated_at": now, "providers": []}
    for pid, name, window in PROVIDERS:
        source = sources.get(pid, {})
        checked = timestamp(source.get("okAtMs"))
        # Aggregate multiple accounts conservatively, never add their percentages.
        windows = {}
        rows = source.get("rows", [])
        if not isinstance(rows, list):
            raise ValueError("Invalid rows")
        for row in rows:
            if not isinstance(row, dict) or row.get("type") != "quota":
                continue
            if row.get("id") and row["id"] not in {pid + suffix for suffix in (".five_hour", ".weekly", ".monthly")}:
                continue
            amount = percentage(row.get("percentRemaining"))
            key = row.get("window")
            if amount is None or key not in ("five_hour", "week", "month"):
                continue
            if key not in windows or amount < windows[key]["remaining"]:
                windows[key] = {"window": key, "remaining": amount, "resets_at": reset(row.get("resetsAt"))}
        selected = windows.get(window, {})
        expires = selected.get("resets_at")
        expired = bool(expires and datetime.fromisoformat(expires.replace("Z", "+00:00")).timestamp() <= now)
        stale = bool(source.get("error")) or checked is None or now - checked > 900 or expired
        provider = dict(id=pid, name=name, window=window, remaining=selected.get("remaining"),
                        resets_at=expires, checked_at=checked, stale=stale,
                        windows=[windows[k] for k in ("five_hour", "week", "month") if k in windows])
        if source.get("error"):
            provider["error"] = "Falha ao consultar o provedor; último dado não confirmado."
        elif not selected:
            provider["error"] = "Quota indisponível. Confira o provedor no OpenCode."
            provider["stale"] = True
        elif stale:
            provider["error"] = "Dado antigo ou janela encerrada; aguardando confirmação."
        if provider["stale"]:
            result["ok"] = False
        result["providers"].append(provider)
    known = [p["checked_at"] for p in result["providers"] if p["checked_at"] is not None]
    result["updated_at"] = min(known) if known else None
    return result


def executable() -> str:
    found = shutil.which("opencode")
    if found:
        return found
    for path in (Path.home() / ".opencode/bin/opencode", Path.home() / ".local/bin/opencode"):
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise RuntimeError("OpenCode não encontrado.")


def percentage(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    try:
        if not math.isfinite(value):
            return None
    except OverflowError:
        return None
    return min(100, max(0, value))


def age_snapshot(value, now=None):
    """Re-evaluate freshness on heartbeats, not just when the RPC is polled."""
    now = time.time() if now is None else now
    result = copy.deepcopy(value)
    for provider in result["providers"]:
        checked = provider.get("checked_at")
        expires = provider.get("resets_at")
        expired = bool(expires and datetime.fromisoformat(expires.replace("Z", "+00:00")).timestamp() <= now)
        if checked is None or now - checked > 900 or expired:
            provider["stale"] = True
            provider["error"] = "Dado antigo ou janela encerrada; aguardando confirmação."
            result["ok"] = False
    return result


def failed_snapshot(previous=None):
    result = copy.deepcopy(previous) if previous else {
        "updated_at": None,
        "providers": [dict(id=pid, name=name, window=window, remaining=None,
                           resets_at=None, checked_at=None, stale=True, windows=[])
                      for pid, name, window in PROVIDERS],
    }
    result["ok"] = False
    result["error"] = "Sem conexão com as quotas do OpenCode. Últimos dados não confirmados."
    for provider in result["providers"]:
        provider["stale"] = True
        provider["error"] = result["error"]
    return result


def snapshot(previous=None):
    try:
        return normalize(fetch())
    except (RuntimeError, OSError, ValueError, TypeError, KeyError, OverflowError, subprocess.SubprocessError):
        # Never include CLI stderr, RPC payloads, or exception text in UI/logs.
        return failed_snapshot(previous)


def serve(interval):
    last = None
    due = 0.0
    while True:
        if time.monotonic() >= due:
            last = snapshot(last)
            due = time.monotonic() + interval
        print(json.dumps(age_snapshot(last), ensure_ascii=True, allow_nan=False), flush=True)
        time.sleep(min(15, max(0.1, due - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("snapshot", "serve"))
    parser.add_argument("--interval", type=int, default=60)
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            print(json.dumps(snapshot(), ensure_ascii=True, allow_nan=False))
        else:
            serve(max(60, min(600, args.interval)))
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
