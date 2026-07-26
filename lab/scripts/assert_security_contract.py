#!/usr/bin/env python3
"""Assert the platform security contract against rendered Kubernetes manifests.

Kyverno enforces these rules at admission time, which means a violation is
discovered when a deploy is rejected — in the middle of a release. Running the
same assertions against `helm template` output moves that discovery to PR time,
where it costs nothing.

Usage: assert_security_contract.py <rendered.yaml>
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment guard
    sys.exit("PyYAML is required: pip install pyyaml")


def check(manifests: list[dict]) -> dict[str, bool]:
    """Return the contract checks and whether each holds."""
    deployments = [m for m in manifests if m.get("kind") == "Deployment"]
    if not deployments:
        sys.exit("No Deployment found in the rendered output.")

    dep = deployments[0]
    pod_spec = dep["spec"]["template"]["spec"]
    pod_sc = pod_spec.get("securityContext", {})
    container = pod_spec["containers"][0]
    sc = container.get("securityContext", {})
    resources = container.get("resources", {})
    kinds = {m.get("kind") for m in manifests}

    return {
        # Kyverno require-image-digest: a tag is mutable, so what was scanned
        # is not provably what runs.
        "image is digest-pinned": "@sha256:" in container.get("image", ""),
        # Kyverno require-non-root
        "runAsNonRoot": pod_sc.get("runAsNonRoot") is True,
        "runAsUser is non-zero": pod_sc.get("runAsUser", 0) > 0,
        # Kyverno disallow-privileged
        "not privileged": sc.get("privileged") is not True,
        "no privilege escalation": sc.get("allowPrivilegeEscalation") is False,
        "all capabilities dropped": sc.get("capabilities", {}).get("drop") == ["ALL"],
        "read-only root filesystem": sc.get("readOnlyRootFilesystem") is True,
        "seccomp RuntimeDefault": pod_sc.get("seccompProfile", {}).get("type") == "RuntimeDefault",
        # Kyverno require-resource-limits: without requests the scheduler and
        # the autoscaler are both flying blind.
        "cpu request set": "cpu" in resources.get("requests", {}),
        "memory request set": "memory" in resources.get("requests", {}),
        "memory limit set": "memory" in resources.get("limits", {}),
        # Availability contract
        "liveness probe": "livenessProbe" in container,
        "readiness probe": "readinessProbe" in container,
        "surge-only rollout": dep["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0,
        "PodDisruptionBudget present": "PodDisruptionBudget" in kinds,
        # Least privilege
        "SA token not automounted": pod_spec.get("automountServiceAccountToken") is False,
        "NetworkPolicy present": "NetworkPolicy" in kinds,
    }


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {Path(sys.argv[0]).name} <rendered.yaml>")

    path = Path(sys.argv[1])
    if not path.is_file():
        sys.exit(f"No such file: {path}")

    manifests = [m for m in yaml.safe_load_all(path.read_text()) if m]
    results = check(manifests)

    width = max(len(name) for name in results)
    for name, ok in results.items():
        print(f"{'PASS' if ok else 'FAIL'}  {name.ljust(width)}")

    failed = [name for name, ok in results.items() if not ok]
    print()
    if failed:
        print(f"{len(failed)} contract violation(s): {', '.join(failed)}")
        return 1

    print(f"All {len(results)} platform security contract checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
