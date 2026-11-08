#!/bin/bash
# Downloads the local RAG embedding model into LocalRAG/model (git-ignored) and verifies it.
#
#   Model:   intfloat/multilingual-e5-small (MIT), int8 ONNX export by Xenova (Transformers.js)
#   Files:   model_quantized.onnx (118 MB) + tokenizer.json (17 MB); ~135 MB of disk space
#   Source:  ${HF_ENDPOINT:-https://huggingface.co}/Xenova/multilingual-e5-small
#            (set HF_ENDPOINT=https://hf-mirror.com to use a mirror)
#
# Run once before building a release (scripts/build-dmg.sh and the Windows release workflow call it).
# The app itself never downloads anything: without these files it falls back to keyword search.
# Each file is checked against the SHA-256 below; a mismatch stops the script and nothing is installed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT_DIR}/LocalRAG/model"
ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
REPO="Xenova/multilingual-e5-small"
REVISION="${RAG_MODEL_REVISION:-main}"

FILES=(
  "onnx/model_quantized.onnx|model_quantized.onnx|118308185|f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193"
  "tokenizer.json|tokenizer.json|17082730|0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"
)

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

mkdir -p "${DEST}"
echo "Local RAG model → ${DEST} (about 135 MB)"
for spec in "${FILES[@]}"; do
  IFS='|' read -r remote name size expected <<< "${spec}"
  target="${DEST}/${name}"
  if [[ -f "${target}" && "$(sha256 "${target}")" == "${expected}" ]]; then
    echo "✓ ${name} already present and verified"
    continue
  fi
  url="${ENDPOINT}/${REPO}/resolve/${REVISION}/${remote}"
  echo "↓ ${name} ($((size / 1000000)) MB) from ${url}"
  # Resumable download into a temporary file; Ctrl-C leaves the old file untouched.
  curl --fail --location --retry 3 --continue-at - --progress-bar --output "${target}.part" "${url}"
  actual="$(sha256 "${target}.part")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "✗ ${name}: SHA-256 mismatch (got ${actual}, expected ${expected}). Not installed." >&2
    rm -f "${target}.part"
    exit 1
  fi
  mv "${target}.part" "${target}"
  echo "✓ ${name} verified"
done
echo "Done. Rebuild the app to bundle the model."
