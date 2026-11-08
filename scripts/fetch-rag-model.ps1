# Downloads the local RAG embedding model into LocalRAG\model (git-ignored) and verifies it.
#
#   Model:   intfloat/multilingual-e5-small (MIT), int8 ONNX export by Xenova (Transformers.js)
#   Files:   model_quantized.onnx (118 MB) + tokenizer.json (17 MB); ~135 MB of disk space
#   Source:  $env:HF_ENDPOINT (default https://huggingface.co)/Xenova/multilingual-e5-small
#
# Used by the Windows release workflow. The app itself never downloads anything: without these files it falls back
# to keyword search. Each file is checked against the SHA-256 below; a mismatch stops the script.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root "LocalRAG\model"
$endpoint = if ($env:HF_ENDPOINT) { $env:HF_ENDPOINT } else { "https://huggingface.co" }
$revision = if ($env:RAG_MODEL_REVISION) { $env:RAG_MODEL_REVISION } else { "main" }
$files = @(
  @{ Remote = "onnx/model_quantized.onnx"; Name = "model_quantized.onnx"; Sha256 = "f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193" },
  @{ Remote = "tokenizer.json"; Name = "tokenizer.json"; Sha256 = "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39" }
)
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Write-Host "Local RAG model -> $dest (about 135 MB)"
foreach ($file in $files) {
  $target = Join-Path $dest $file.Name
  if ((Test-Path $target) -and ((Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant() -eq $file.Sha256)) {
    Write-Host "OK $($file.Name) already present and verified"
    continue
  }
  $url = "$endpoint/Xenova/multilingual-e5-small/resolve/$revision/$($file.Remote)"
  Write-Host "Downloading $($file.Name) from $url"
  $partial = "$target.part"
  Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing
  $actual = (Get-FileHash -Algorithm SHA256 $partial).Hash.ToLowerInvariant()
  if ($actual -ne $file.Sha256) {
    Remove-Item $partial -Force
    throw "$($file.Name): SHA-256 mismatch (got $actual, expected $($file.Sha256)). Not installed."
  }
  Move-Item -Force $partial $target
  Write-Host "OK $($file.Name) verified"
}
