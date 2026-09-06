#!/usr/bin/env python3
"""Evaluate one Step Functions execution against the acceptance criteria.

Reads three JSON files produced by the AWS CLI:
  1. describe-execution output
  2. get-execution-history output
  3. dynamodb query output for this execution

Prints a timing table plus AC-2..AC-7 verdicts. Exits non-zero on any FAIL.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime

FAST_TASK = "transform-a"
SLOW_TASKS = ("transform-b", "transform-c", "transform-d")
FAST_SLA_MS = int(os.environ.get("FAST_SLA_MS", "10000"))
SLOW_SLA_MS = int(os.environ.get("SLOW_SLA_MS", "15000"))

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def load(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def to_ms(iso: str) -> int:
    return int(datetime.fromisoformat(iso).timestamp() * 1000)


def state_times(history: dict) -> dict[str, dict[str, int]]:
    """name -> {"enter": ms, "exit": ms} from the execution history."""
    out: dict[str, dict[str, int]] = {}
    for event in history.get("events", []):
        etype = event.get("type", "")
        ts = to_ms(event["timestamp"])
        if etype.endswith("StateEntered"):
            name = event["stateEnteredEventDetails"]["name"]
            out.setdefault(name, {})["enter"] = ts
        elif etype.endswith("StateExited"):
            name = event["stateExitedEventDetails"]["name"]
            out.setdefault(name, {})["exit"] = ts
    return out


def unwrap(item: dict) -> dict:
    """Flatten a DynamoDB item into plain Python values."""
    out = {}
    for key, val in item.items():
        if "N" in val:
            out[key] = int(val["N"])
        elif "S" in val:
            out[key] = val["S"]
        else:
            out[key] = val
    return out


class Checks:
    def __init__(self) -> None:
        self.results: list[tuple[str, bool, str]] = []

    def add(self, ac: str, ok: bool, detail: str) -> None:
        self.results.append((ac, ok, detail))

    def report(self) -> int:
        print("\n== 受け入れ基準 ==")
        width = max(len(ac) for ac, _, _ in self.results)
        failed = 0
        for ac, ok, detail in self.results:
            mark = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
            failed += 0 if ok else 1
            print(f"  {mark}  {ac.ljust(width)}  {detail}")
        print()
        if failed:
            print(f"{RED}{failed} 件が FAIL{RESET}")
        else:
            print(f"{GREEN}すべて PASS{RESET}")
        return 1 if failed else 0


def main() -> int:
    execution, history, rows = (load(p) for p in sys.argv[1:4])

    status = execution["status"]
    started = to_ms(execution["startDate"])
    stopped = to_ms(execution["stopDate"]) if execution.get("stopDate") else None

    times = state_times(history)
    items = {r["taskName"]: r for r in (unwrap(i) for i in rows.get("Items", []))}

    enqueued = next((r["enqueuedAt"] for r in items.values() if "enqueuedAt" in r), None)

    print(f"execution : {execution['name']}")
    print(f"status    : {status}")
    if enqueued is not None:
        print(f"SQS 到着  : {datetime.fromtimestamp(enqueued / 1000).isoformat(timespec='milliseconds')}")
        print(f"SFN 開始  : +{started - enqueued}ms  {DIM}(SQS ポーリング + Lambda + StartExecution){RESET}")
    if stopped is not None:
        print(f"SFN 終了  : +{stopped - (enqueued or started)}ms")

    print("\n== ステート実行時刻 (SQS 到着からの相対 ms) ==")
    base = enqueued if enqueued is not None else started
    print(f"  {'state'.ljust(14)} {'enter'.rjust(8)} {'exit'.rjust(8)} {'dur'.rjust(8)}")
    for name in ("Preprocess", "FanOut",
                 "TransformA", "PutResultA", "TransformB", "PutResultB",
                 "TransformC", "PutResultC", "TransformD", "PutResultD",
                 "MarkComplete"):
        t = times.get(name)
        if not t:
            continue
        enter, exit_ = t.get("enter"), t.get("exit")
        dur = f"{exit_ - enter}" if enter and exit_ else "-"
        print(f"  {name.ljust(14)} {str(enter - base).rjust(8)} "
              f"{(str(exit_ - base) if exit_ else '-').rjust(8)} {dur.rjust(8)}")

    print("\n== DynamoDB 書き込み結果 ==")
    print(f"  {'taskName'.ljust(14)} {'elapsedMs'.rjust(10)}  判定")
    for name in (FAST_TASK, *SLOW_TASKS, "zz-complete"):
        row = items.get(name)
        if not row:
            print(f"  {name.ljust(14)} {'(missing)'.rjust(10)}")
            continue
        elapsed = row["elapsedMs"]
        sla = FAST_SLA_MS if name == FAST_TASK else SLOW_SLA_MS if name in SLOW_TASKS else None
        verdict = ""
        if sla:
            colour = GREEN if elapsed < sla else RED
            verdict = f"{colour}{'OK' if elapsed < sla else 'NG'} (目標 {sla}ms){RESET}"
        print(f"  {name.ljust(14)} {str(elapsed).rjust(10)}  {verdict}")

    checks = Checks()

    # AC-2: preprocess finishes before the fan-out starts.
    pre, fan = times.get("Preprocess", {}), times.get("FanOut", {})
    ok = bool(pre.get("exit") and fan.get("enter") and pre["exit"] <= fan["enter"])
    checks.add("AC-2 前処理が並列より先に完了", ok,
               f"Preprocess exit={pre.get('exit', 0) - base}ms <= FanOut enter={fan.get('enter', 0) - base}ms")

    # AC-3: all four branches start within 1s of each other.
    starts = [times[n]["enter"] for n in ("TransformA", "TransformB", "TransformC", "TransformD")
              if n in times and "enter" in times[n]]
    spread = max(starts) - min(starts) if len(starts) == 4 else None
    checks.add("AC-3 4分岐が同時開始", spread is not None and spread < 1000,
               f"開始時刻の最大差 {spread}ms (< 1000ms)" if spread is not None
               else f"4分岐そろわず ({len(starts)}/4)")

    # AC-4 / AC-5: SLA on the DynamoDB write, measured from SQS arrival.
    fast = items.get(FAST_TASK)
    checks.add(f"AC-4 {FAST_TASK} が {FAST_SLA_MS}ms 以内",
               bool(fast) and fast["elapsedMs"] < FAST_SLA_MS,
               f"{fast['elapsedMs']}ms" if fast else "レコードなし")
    slow_rows = {n: items[n] for n in SLOW_TASKS if n in items}
    worst = max((r["elapsedMs"] for r in slow_rows.values()), default=None)
    checks.add(f"AC-5 transform-b/c/d が {SLOW_SLA_MS}ms 以内",
               len(slow_rows) == 3 and worst is not None and worst < SLOW_SLA_MS,
               f"最も遅い分岐 {worst}ms ({len(slow_rows)}/3 件)" if worst is not None else "レコードなし")

    # AC-6: the whole point -- the fast branch lands before Parallel completes.
    put_a, fan_exit = times.get("PutResultA", {}).get("exit"), fan.get("exit")
    ok = bool(put_a and fan_exit and put_a < fan_exit)
    checks.add("AC-6 加工A が Parallel 完了より前に書き込み", ok,
               f"PutResultA={put_a - base}ms < FanOut exit={fan_exit - base}ms "
               f"(先行 {fan_exit - put_a}ms)" if ok and put_a and fan_exit else "順序を確認できず")

    # AC-7: clean finish, five rows.
    checks.add("AC-7 SUCCEEDED かつ 5レコード",
               status == "SUCCEEDED" and len(items) == 5,
               f"status={status}, rows={len(items)}")

    return checks.report()


if __name__ == "__main__":
    sys.exit(main())
