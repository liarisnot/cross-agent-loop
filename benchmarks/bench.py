"""Benchmark bookkeeping for the delegate skill (stdlib only).

  python bench.py status                      -> is benchmark mode on, how many tasks left
  python bench.py on [N] [--profile P]        -> enable for the next N tasks (default 8)
  python bench.py off
  python bench.py add <judgment.json>         -> record one head-to-head task, count down, rebuild REPORT.md
  python bench.py report                      -> rebuild REPORT.md from records.jsonl + runs.jsonl

Token usage / seconds are NOT typed in by the lead: they are summed from runs.jsonl
(written automatically by delegate.ps1 for every run, in $XAGENT_LOG_DIR or %LOCALAPPDATA%/xagent) by matching repo + taskId.

judgment.json (written by the lead after reviewing both):
{
  "repo": "D:\\proj", "task": "short description", "heldOutTests": true,
  "entries": [
    {"agent": "cursor", "taskId": "foo--cursor", "firstTryPass": true, "finalPass": true,
     "reviewRounds": 0, "scopeOk": true,
     "rubric": {"correctness": 5, "instructions": 4, "quality": 4}, "notes": "..."},
    {"agent": "agy", "taskId": "foo--agy", ...}
  ],
  "winner": "cursor|agy|tie", "summary": "one or two sentences"
}
"""
import json
import os
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG, RECORDS, REPORT = (HERE / n for n in ("config.json", "records.jsonl", "REPORT.md"))
# runs.jsonl lives outside every repo (delegate.ps1 writes it there), so private usage data is never committed
LOG_DIR = Path(os.environ.get("XAGENT_LOG_DIR") or Path(os.environ["LOCALAPPDATA"]) / "xagent")
RUNS = LOG_DIR / "runs.jsonl"


def load_jsonl(p):
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8-sig").splitlines() if l.strip()]


def cfg_load():
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def cfg_save(c):
    CONFIG.write_text(json.dumps(c, indent=2) + "\n", encoding="utf-8")


def norm(p):
    return str(p).replace("/", "\\").rstrip("\\").lower()


def sum_runs(repo, task_id, runs):
    tot = {"runs": 0, "seconds": 0, "input": 0, "output": 0, "reasoning": 0, "cacheRead": 0, "total": 0, "model": None}
    for r in runs:
        if norm(r.get("repo", "")) == norm(repo) and r.get("taskId") == task_id:
            tot["runs"] += 1
            tot["seconds"] += r.get("seconds", 0)
            tot["model"] = r.get("model")
            for k in ("input", "output", "reasoning", "cacheRead", "total"):
                tot[k] += r.get("usage", {}).get(k, 0)
    return tot


def add(path):
    j = json.loads(Path(path).read_text(encoding="utf-8"))
    runs = load_jsonl(RUNS)
    for e in j["entries"]:
        e["measured"] = sum_runs(j["repo"], e["taskId"], runs)
        if e["measured"]["runs"] == 0:
            sys.exit(f"no runs.jsonl entries for repo={j['repo']} taskId={e['taskId']}")
    j["ts"] = datetime.now().isoformat(timespec="seconds")
    with RECORDS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(j) + "\n")
    c = cfg_load()
    if c.get("enabled"):
        c["remainingTasks"] = max(0, c.get("remainingTasks", 0) - 1)
        if c["remainingTasks"] == 0:
            c["enabled"] = False
        cfg_save(c)
    report()
    print(comparison(j))
    print(f"\nrecorded. benchmark enabled={c['enabled']} remaining={c['remainingTasks']}")


def comparison(j):
    rows = ["| | " + " | ".join(f"{e['agent']} ({e['measured']['model']})" for e in j["entries"]) + " |",
            "|---|" + "---|" * len(j["entries"])]
    def row(label, fn):
        rows.append(f"| {label} | " + " | ".join(str(fn(e)) for e in j["entries"]) + " |")
    row("first-try pass", lambda e: "✅" if e["firstTryPass"] else "❌")
    row("final pass", lambda e: "✅" if e["finalPass"] else "❌")
    row("review rounds", lambda e: e["reviewRounds"])
    row("in scope", lambda e: "✅" if e["scopeOk"] else "❌")
    row("rubric C/I/Q", lambda e: "/".join(str(e["rubric"][k]) for k in ("correctness", "instructions", "quality")))
    row("tokens in/out/reason", lambda e: f"{e['measured']['input']:,}/{e['measured']['output']:,}/{e['measured']['reasoning']:,}")
    row("cache read", lambda e: f"{e['measured']['cacheRead']:,}")
    row("total incl. cache", lambda e: f"{e['measured']['total'] + e['measured']['cacheRead']:,}")
    row("wall time", lambda e: f"{e['measured']['seconds']}s ({e['measured']['runs']} runs)")
    return f"**{j['task']}**: winner **{j['winner']}**. {j.get('summary', '')}\n\n" + "\n".join(rows)


def report():
    recs = load_jsonl(RECORDS)
    agg = defaultdict(lambda: defaultdict(float))
    for r in recs:
        for e in r["entries"]:
            key = f"{e['agent']} / {e['measured']['model']}"
            a = agg[key]
            a["tasks"] += 1
            a["firstTry"] += e["firstTryPass"]
            a["final"] += e["finalPass"]
            a["rounds"] += e["reviewRounds"]
            a["scope"] += e["scopeOk"]
            a["rubric"] += sum(e["rubric"].values()) / len(e["rubric"])
            a["tokens"] += e["measured"]["total"]
            a["tokensAll"] += e["measured"]["total"] + e["measured"]["cacheRead"]
            a["seconds"] += e["measured"]["seconds"]
            a["wins"] += r["winner"] == e["agent"]
    lines = [f"# Benchmark report: Cursor vs Antigravity workers",
             f"_Generated {datetime.now():%Y-%m-%d %H:%M} from {len(recs)} head-to-head task(s). Raw data: records.jsonl, runs.jsonl._", "",
             "## Totals per agent / model", "",
             "| agent / model | tasks | wins | first-try pass | final pass | avg review rounds | in scope | avg rubric (1-5) | avg tokens excl. cache | avg tokens incl. cache | avg wall time |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for k, a in sorted(agg.items()):
        n = a["tasks"]
        lines.append(f"| {k} | {n:.0f} | {a['wins']:.0f} | {a['firstTry']/n:.0%} | {a['final']/n:.0%} | {a['rounds']/n:.1f} | "
                     f"{a['scope']/n:.0%} | {a['rubric']/n:.2f} | {a['tokens']/n:,.0f} | {a['tokensAll']/n:,.0f} | {a['seconds']/n:.0f}s |")
    lines += ["", "## Per-task log", ""]
    for r in reversed(recs):
        lines += [f"### {r['ts'][:16]} · {Path(r['repo']).name}", "", comparison(r), ""]
        for e in r["entries"]:
            if e.get("notes"):
                lines.append(f"- *{e['agent']}*: {e['notes']}")
        lines.append("")
    lines += ["## Method", "",
              "- Both workers get the identical task file, base commit, profile tier and timeout.",
              "- **first-try pass**: lead reruns the tests (including held-out acceptance tests the workers never saw, when `heldOutTests` is true) before any review feedback.",
              "- **rubric** (lead's judgment, 1-5): correctness, instruction-following/scope, code quality.",
              "- Tokens are as reported by each CLI. Subscription plans don't expose a $ cost, so token counts are the comparable cost proxy. The CLIs report caching differently (Cursor splits out cache reads; agy has so far reported 0 cached), so compare **incl. cache** totals for volume; cache reads are usually billed/quota-weighted lower.",
              "- Small sample sizes: treat early numbers as directional."]
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv):
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # Windows consoles default to cp1252
    except Exception:
        pass
    if argv and argv[0] == "last":
        recs = load_jsonl(RECORDS)
        print(comparison(recs[-1]) if recs else "no records")
        return
    if not argv or argv[0] == "status":
        c = cfg_load()
        print(json.dumps({"enabled": c["enabled"], "remainingTasks": c["remainingTasks"], "profile": c.get("profile", "code"),
                          "recordedTasks": len(load_jsonl(RECORDS))}))
    elif argv[0] == "on":
        c = cfg_load()
        c["enabled"] = True
        c["remainingTasks"] = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 8
        if "--profile" in argv:
            c["profile"] = argv[argv.index("--profile") + 1]
        cfg_save(c)
        main(["status"])
    elif argv[0] == "off":
        c = cfg_load()
        c["enabled"] = False
        cfg_save(c)
        main(["status"])
    elif argv[0] == "add":
        add(argv[1])
    elif argv[0] == "report":
        report()
        print(f"wrote {REPORT}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
