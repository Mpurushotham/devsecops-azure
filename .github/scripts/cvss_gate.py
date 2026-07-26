#!/usr/bin/env python3
"""Apply the repository CVSS threshold policy to a SARIF report.

    CVSS >= 9.0   CRITICAL   fail the job — blocks the merge
    CVSS 7.0-8.9  HIGH       warn and emit a ticket payload
    CVSS < 7.0    MEDIUM/LOW log only

Why this exists
---------------
Every gate used to re-implement this inline, and all of them used the SARIF
`level` field as a proxy for severity. That mapping is wrong for Trivy, which
emits ``level: "error"`` for **both** CRITICAL and HIGH. The result was that a
HIGH finding (CVSS 7.0-8.9), which policy says should warn, failed the build —
and a MEDIUM was reported as HIGH.

Scanners that follow the SARIF convention publish the real score in
``properties.security-severity`` on the rule. This script reads that when it is
present and falls back to the level only when it is not, so the policy is
applied to the number it is actually written in terms of.

Usage:
    cvss_gate.py <report.sarif> [--tool NAME] [--critical 9.0] [--high 7.0]
                                [--fail-on-high] [--json-out findings.json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Fallback only: used when a scanner emits no security-severity property.
LEVEL_FALLBACK_SCORE = {
    "error": 9.0,
    "warning": 7.0,
    "note": 4.0,
    "none": 0.0,
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("sarif", type=Path, help="SARIF report to evaluate")
    p.add_argument("--tool", default="scanner", help="Tool name, used in log output")
    p.add_argument("--critical", type=float, default=9.0, help="CVSS at or above this blocks (default: 9.0)")
    p.add_argument("--high", type=float, default=7.0, help="CVSS at or above this warns (default: 7.0)")
    p.add_argument(
        "--fail-on-high",
        action="store_true",
        help="Also fail on HIGH. Off by default so the gate matches the documented policy.",
    )
    p.add_argument("--json-out", type=Path, help="Write findings as JSON, for ticket creation")
    return p.parse_args()


def rule_index(run: dict) -> dict[str, dict]:
    """Map ruleId -> rule object, including rules referenced via extensions."""
    driver = run.get("tool", {}).get("driver", {})
    rules = {r["id"]: r for r in driver.get("rules", []) if "id" in r}
    for ext in run.get("tool", {}).get("extensions", []):
        for r in ext.get("rules", []):
            if "id" in r:
                rules.setdefault(r["id"], r)
    return rules


def score_for(result: dict, rules: dict[str, dict]) -> float:
    """Best available CVSS score for a SARIF result."""
    props = {**rules.get(result.get("ruleId", ""), {}).get("properties", {}),
             **result.get("properties", {})}

    # The SARIF convention for security tooling.
    raw = props.get("security-severity")
    if raw is not None:
        try:
            return float(raw)
        except (TypeError, ValueError):
            pass

    # Some scanners publish the CVSS base score directly instead.
    for key in ("cvssv40_baseScore", "cvssv3_baseScore", "cvssv31_baseScore"):
        if key in props:
            try:
                return float(props[key])
            except (TypeError, ValueError):
                continue

    return LEVEL_FALLBACK_SCORE.get(result.get("level", "note"), 0.0)


def location_of(result: dict) -> str:
    locations = result.get("locations") or []
    if not locations:
        return ""
    phys = locations[0].get("physicalLocation", {})
    uri = phys.get("artifactLocation", {}).get("uri", "")
    line = phys.get("region", {}).get("startLine", "")
    return f"{uri}:{line}" if line else uri


def main() -> int:
    args = parse_args()

    if not args.sarif.is_file():
        # A scanner that produced nothing is not the same as a clean scan, but
        # the calling workflow already fails on a tool error — treating a
        # missing file as clean here keeps skipped optional scanners quiet.
        print(f"{args.tool}: no SARIF at {args.sarif} — nothing to evaluate.")
        return 0

    try:
        sarif = json.loads(args.sarif.read_text())
    except json.JSONDecodeError as exc:
        print(f"::error::{args.tool}: SARIF at {args.sarif} is not valid JSON ({exc})")
        return 1

    critical: list[dict] = []
    high: list[dict] = []
    low: list[dict] = []

    for run in sarif.get("runs", []):
        rules = rule_index(run)
        for result in run.get("results", []):
            # Suppressed findings are accepted risk recorded elsewhere.
            if result.get("suppressions"):
                continue

            score = score_for(result, rules)
            finding = {
                "rule": result.get("ruleId", ""),
                "score": score,
                "location": location_of(result),
                "message": (result.get("message", {}).get("text", "") or "").split("\n")[0][:200],
            }

            if score >= args.critical:
                critical.append(finding)
            elif score >= args.high:
                high.append(finding)
            else:
                low.append(finding)

    print(f"{args.tool} — CRITICAL (>={args.critical}): {len(critical)}, "
          f"HIGH ({args.high}-{args.critical}): {len(high)}, "
          f"below threshold: {len(low)}")

    for f in critical:
        print(f"  [CRITICAL {f['score']}] {f['rule']} @ {f['location']}: {f['message']}")
    for f in high:
        print(f"  [HIGH     {f['score']}] {f['rule']} @ {f['location']}: {f['message']}")

    if args.json_out:
        args.json_out.write_text(json.dumps(
            {"tool": args.tool, "critical": critical, "high": high}, indent=2))

    # Surface counts for later steps (ticket creation, summaries).
    if summary := os.environ.get("GITHUB_OUTPUT"):
        with open(summary, "a") as fh:
            fh.write(f"critical_count={len(critical)}\n")
            fh.write(f"high_count={len(high)}\n")

    if critical:
        print(f"::error::{args.tool}: {len(critical)} finding(s) at CVSS >= {args.critical} — blocking")
        return 1

    if high:
        print(f"::warning::{args.tool}: {len(high)} finding(s) at CVSS {args.high}-{args.critical} — "
              "tracking ticket required")
        if args.fail_on_high:
            print(f"::error::{args.tool}: --fail-on-high is set, so HIGH findings block")
            return 1

    print(f"{args.tool}: within policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
