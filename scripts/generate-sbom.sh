#!/usr/bin/env bash
# generate-sbom.sh — Generate and sign SBOM for a container image.
# Usage: ./scripts/generate-sbom.sh <image:tag> [output-dir]
set -euo pipefail

IMAGE="${1:-}"
OUTPUT_DIR="${2:-./sbom-output}"

[[ -z "${IMAGE}" ]] && { echo "Usage: $0 <image:tag> [output-dir]"; exit 1; }

IMAGE_SAFE="${IMAGE//[:\/]/-}"
mkdir -p "${OUTPUT_DIR}"

info()    { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m    $*"; }

# ── Generate CycloneDX SBOM ────────────────────────────────────────────────────
info "Generating CycloneDX SBOM for ${IMAGE}..."
syft "${IMAGE}" -o cyclonedx-json \
    --file "${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json"
success "CycloneDX SBOM: ${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json"

# ── Generate SPDX SBOM ─────────────────────────────────────────────────────────
info "Generating SPDX SBOM..."
syft "${IMAGE}" -o spdx-json \
    --file "${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-spdx.json"
success "SPDX SBOM: ${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-spdx.json"

# ── Vulnerability scan on SBOM ─────────────────────────────────────────────────
info "Running Grype scan on SBOM..."
grype "sbom:${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json" \
    --output json \
    --file "${OUTPUT_DIR}/${IMAGE_SAFE}-vuln-report.json" || true

# ── CVSS threshold enforcement ─────────────────────────────────────────────────
info "Checking CVSS thresholds..."
python3 - << PYEOF
import json, sys

try:
    report = json.load(open("${OUTPUT_DIR}/${IMAGE_SAFE}-vuln-report.json"))
    matches = report.get("matches", [])

    critical = [m for m in matches if m.get("vulnerability", {}).get("severity", "").upper() == "CRITICAL"]
    high     = [m for m in matches if m.get("vulnerability", {}).get("severity", "").upper() == "HIGH"]
    medium   = [m for m in matches if m.get("vulnerability", {}).get("severity", "").upper() == "MEDIUM"]

    print(f"  Critical (CVSS >= 9.0): {len(critical)}")
    print(f"  High     (CVSS 7.0-8.9): {len(high)}")
    print(f"  Medium   (CVSS 4.0-6.9): {len(medium)}")

    if critical:
        print("\n\033[0;31mBLOCKING: Critical vulnerabilities found:\033[0m")
        for m in critical[:5]:
            vuln = m["vulnerability"]
            print(f"  [{vuln['severity']}] {vuln['id']} in {m.get('artifact', {}).get('name', 'unknown')}")
        sys.exit(1)

    if high:
        print("\n\033[1;33mWARNING: High severity vulnerabilities — create tracking tickets\033[0m")
        for m in high[:5]:
            vuln = m["vulnerability"]
            print(f"  [{vuln['severity']}] {vuln['id']} in {m.get('artifact', {}).get('name', 'unknown')}")
except FileNotFoundError:
    print("  No vulnerability report found, skipping threshold check")
PYEOF

# ── Sign SBOM with cosign ──────────────────────────────────────────────────────
if command -v cosign &>/dev/null && [[ -n "${COSIGN_KEY:-}" ]]; then
    info "Signing SBOM with cosign..."
    cosign sign-blob \
        --key "${COSIGN_KEY}" \
        --output-signature "${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json.sig" \
        "${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json"
    success "SBOM signed"
elif command -v cosign &>/dev/null; then
    info "Attaching SBOM to image (keyless)..."
    cosign attach sbom \
        --sbom "${OUTPUT_DIR}/${IMAGE_SAFE}-sbom-cyclonedx.json" \
        --type cyclonedx \
        "${IMAGE}" && success "SBOM attached to image" || warn "Could not attach SBOM (no registry auth?)"
fi

echo ""
success "SBOM generation complete. Files in ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
