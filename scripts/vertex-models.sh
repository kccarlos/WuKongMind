#!/bin/bash
# Prints the Gemini chat/text models Vertex AI offers, to refresh
# `AIProvider.vertexAIModels` (WukongMind/ProviderModels.swift).
#
#   VERTEX_PROJECT=<gcp project with aiplatform enabled> scripts/vertex-models.sh
#
# Skips tts, image, embedding, live, transcribe, robotics, omni and
# computer-use models. Newest first is a manual step; then check each new
# model with generateContent and a tool call (docs/DEVELOPMENT.md).
set -euo pipefail
: "${VERTEX_PROJECT:?set VERTEX_PROJECT to your Google Cloud project ID}"
gcloud ai model-garden models list \
  --model-filter=gemini \
  --project="$VERTEX_PROJECT" \
  --billing-project="$VERTEX_PROJECT" \
  --format='value(name)' |
  sed 's#.*/##; s#@.*##' |
  grep -Eiv 'tts|image|embedding|live|transcribe|robotics|omni|computer-use' |
  sort -u
