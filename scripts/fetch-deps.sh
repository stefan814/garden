#!/usr/bin/env bash
# Fetches what git doesn't keep: the sherpa-onnx AAR (test harness + spike) and the models bundled in test app "a".
# Every file is pinned by SHA-256 (the model hashes are the catalog's). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
K2=https://github.com/k2-fsa/sherpa-onnx/releases/download
PK=https://huggingface.co/punitd/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8/resolve/66a4fa70643dc7ce25c9b38b2f87e1b35ddad33d

get() {  # get <dest> <sha256> <url>
  local dest=$1 sha=$2 url=$3
  if [ -f "$dest" ] && echo "$sha  $dest" | shasum -a 256 -c --status; then return; fi
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 3 -o "$dest" "$url"
  echo "$sha  $dest" | shasum -a 256 -c --status || { echo "checksum mismatch: $dest" >&2; rm -f "$dest"; exit 1; }
}

AAR=a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7
get android/harness/libs/sherpa-onnx-2.0.1.aar $AAR $K2/v2.0.1/sherpa-onnx-2.0.1.aar
get spike/app/libs/sherpa-onnx-2.0.1.aar $AAR $K2/v2.0.1/sherpa-onnx-2.0.1.aar

VAD=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6
EMB=ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e
M=android/harness/src/a/assets/models
get $M/silero-vad-v5/vad.onnx $VAD $K2/asr-models/silero_vad.onnx
get $M/titanet-small-en/embed.onnx $EMB $K2/speaker-recongition-models/nemo_en_titanet_small.onnx
P=$M/parakeet-tdt-110m-en-int8
get $P/encoder.int8.onnx 0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657 $PK/encoder.int8.onnx
get $P/decoder.int8.onnx f7c331c5504c2e593c76ed22b728e3f554af6c4a383dde862e719ced08b1da19 $PK/decoder.int8.onnx
get $P/joiner.int8.onnx bf7dff69e9f2cdbe9943d70da358f38b361c115ba0105bae7e908e0d6ec782f6 $PK/joiner.int8.onnx
get $P/tokens.txt 450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10 $PK/tokens.txt

S=spike/app/src/a/assets
for f in vad.onnx embed.onnx; do mkdir -p $S; cp -n $M/*/$f $S/ 2>/dev/null || true; done
mkdir -p $S/asr; cp -n $P/* $S/asr/ 2>/dev/null || true
echo "Dependencies ready."
