#!/usr/bin/env bash
# One continuous-eval sample, end to end (RFC §6 step 1):
#   1. run agent-evals against the target and take the machine-readable verdict
#   2. append {"ts","passed","total"} to the samples ConfigMap the operator reads
#   3. push the run through agent-meter's SLI instruments (OTLP)
#
# Usage: slice/continuous-eval.sh <dataset.yaml> <target-url|echo>
# Env:   EVALS_JAR (required)  METRICS_JAR (optional; skips metric push if unset)
#        NS=agents  SAMPLES_CM=support-slo-samples  AGENT_NAME=support
#        OTLP_ENDPOINT=http://localhost:4317
set -euo pipefail

DATASET=${1:?dataset yaml}
TARGET=${2:?target url or 'echo'}
NS=${NS:-agents}
CM=${SAMPLES_CM:-support-slo-samples}
EVALS_JAR=${EVALS_JAR:?path to the agent-evals shaded jar}
METRICS_JAR=${METRICS_JAR:-}
OTLP=${OTLP_ENDPOINT:-http://localhost:4317}
AGENT_NAME=${AGENT_NAME:-support}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The runner exits 1 when the gate fails — for sampling that is data, not an error.
out=$(java -jar "$EVALS_JAR" "$DATASET" --target "$TARGET" \
        --report "$work/report.md" --verdict "$work/verdict.json" || true)
verdict=$(printf '%s\n' "$out" | grep '^VERDICT-JSON: ' | sed 's/^VERDICT-JSON: //') \
  || { echo "ERROR: no VERDICT-JSON line from the runner"; printf '%s\n' "$out" | tail -5; exit 1; }
passed=$(printf '%s' "$verdict" | jq .passed)
total=$(printf '%s' "$verdict" | jq .total)

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sample="{\"ts\":\"$ts\",\"passed\":$passed,\"total\":$total}"
existing=$(kubectl -n "$NS" get configmap "$CM" -o jsonpath='{.data.samples\.jsonl}' 2>/dev/null || true)
{ [ -n "$existing" ] && printf '%s\n' "$existing"; printf '%s\n' "$sample"; } > "$work/samples.jsonl"
kubectl -n "$NS" create configmap "$CM" --from-file=samples.jsonl="$work/samples.jsonl" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "sample recorded: $sample (dataset $(basename "$DATASET"))"

if [ -n "$METRICS_JAR" ]; then
  java -jar "$METRICS_JAR" --passed "$passed" --total "$total" \
      --dataset "$(basename "$DATASET" .yaml)" --agent "$AGENT_NAME" --endpoint "$OTLP" \
    || echo "WARN: metric push failed (collector unreachable?) — sample still recorded"
fi
