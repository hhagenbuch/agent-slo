#!/usr/bin/env bash
# End-to-end proof of the agent-slo proving slice (RFC §6) on kind:
#
#   continuous-eval runs → samples ConfigMap + OTel metrics (meter instruments)
#   → operator SloPolicy check → promotionsFrozen
#   → PromptVersion REFUSED while frozen (phase Frozen)
#   → slo-exempt fix passes the FREEZE but still runs the GATE
#   → freeze lifts as the window rolls clean → parked version proceeds by itself
#
# Modes:
#   full      — default when ANTHROPIC_API_KEY is set. Continuous evals run
#               against the deployed starter; the exempt fix passes the gate
#               and is Promoted. The RFC-faithful run.
#   mechanics — opt in with E2E_MODE=mechanics when no key is available.
#               Sample generation uses the runner's deterministic built-in
#               `echo` target; every control-plane step (samples → budget →
#               freeze → refusal → exemption → recovery) is identical and real.
#               The gate cannot pass without a key, so the exempt fix is
#               expected to reach the canary (freeze passed) and then be
#               RolledBack (gate enforced) — which is itself the slice's
#               "exemption skips the freeze, never the gate" claim, verified.
#
# Sibling checkouts required: ../agent-operator ../spring-ai-agent-starter
#                             ../agent-evals ../agent-meter
# Optional: RECORD_GIF=1 (needs vhs) records slice/demo.gif at the refusal.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OPERATOR_DIR=${OPERATOR_DIR:-$ROOT/../agent-operator}
STARTER_DIR=${STARTER_DIR:-$ROOT/../spring-ai-agent-starter}
EVALS_DIR=${EVALS_DIR:-$ROOT/../agent-evals}
METER_DIR=${METER_DIR:-$ROOT/../agent-meter}
CLUSTER=${CLUSTER:-agent-slo-e2e}
NS=agents
STARTER_IMAGE=ghcr.io/hhagenbuch/spring-ai-agent-starter:0.3.0
EVALS_IMAGE=ghcr.io/hhagenbuch/agent-evals:0.1.0
COLLECTOR=agent-slo-otel

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODE=full
elif [ "${E2E_MODE:-}" = "mechanics" ]; then
  MODE=mechanics
else
  echo "ANTHROPIC_API_KEY is not set. Either export it (full mode) or opt into"
  echo "the keyless control-plane run explicitly with E2E_MODE=mechanics."
  exit 1
fi
echo "=== agent-slo e2e ($MODE mode) ==="

for d in "$OPERATOR_DIR" "$STARTER_DIR" "$EVALS_DIR" "$METER_DIR"; do
  [ -d "$d" ] || { echo "missing sibling checkout: $d"; exit 1; }
done

say() { printf '\n\033[1m--- %s\033[0m\n' "$*"; }

# Poll a jsonpath until it matches an extended regex. wait_for <what> <timeout-s> <regex> <kubectl args...>
wait_for() {
  local what=$1 timeout=$2 regex=$3; shift 3
  local waited=0 value=""
  while [ "$waited" -lt "$timeout" ]; do
    value=$(kubectl -n "$NS" "$@" 2>/dev/null || true)
    if printf '%s' "$value" | grep -qE "$regex"; then
      echo "OK: $what -> $value"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo "FAIL: timed out waiting for $what (last: '$value')"
  exit 1
}

# Full mode targets the deployed starter through a port-forward. A promotion
# rolls the main Deployment, which kills a port-forward bound to the old pod, so
# the forward is (re)established lazily and health-checked before every eval run.
PF_PID=""
start_pf() {
  [ "$MODE" = full ] || return 0
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl -n "$NS" rollout status deploy/support --timeout=180s >/dev/null 2>&1 || true
  kubectl -n "$NS" port-forward svc/support 18080:8080 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
}
ensure_pf() {
  [ "$MODE" = full ] || return 0
  if curl -sf -o /dev/null --max-time 3 http://localhost:18080/actuator/health 2>/dev/null; then
    return 0
  fi
  echo "  (port-forward stale after a rollout — refreshing)"
  start_pf
}
# One continuous-eval sample, refreshing the forward first in full mode.
sample() {
  ensure_pf
  "$ROOT"/slice/continuous-eval.sh "$@"
}

say "Building (operator jar, evals jar+image, meter install, slo-metrics, starter image)"
(cd "$OPERATOR_DIR" && mvn -q -DskipTests package)
(cd "$EVALS_DIR" && mvn -q -DskipTests package)
EVALS_JAR=$(ls "$EVALS_DIR"/target/agent-evals-*.jar | head -1)
(cd "$METER_DIR" && ./mvnw -q -DskipTests -pl meter-core,meter-spring -am install)
(cd "$ROOT" && mvn -q -DskipTests -f slo-metrics/pom.xml package)
METRICS_JAR=$(ls "$ROOT"/slo-metrics/target/slo-metrics-*.jar | head -1)
docker image inspect "$EVALS_IMAGE" >/dev/null 2>&1 || docker build -q -t "$EVALS_IMAGE" "$EVALS_DIR"
docker image inspect "$STARTER_IMAGE" >/dev/null 2>&1 || \
  (cd "$STARTER_DIR" && mvn -q -DskipTests spring-boot:build-image \
     -Dspring-boot.build-image.imageName="$STARTER_IMAGE")

say "Cluster + CRDs + namespace + images"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER"
kubectl config use-context "kind-$CLUSTER" >/dev/null
kind load docker-image "$STARTER_IMAGE" --name "$CLUSTER"
kind load docker-image "$EVALS_IMAGE" --name "$CLUSTER"
kubectl apply -f "$OPERATOR_DIR"/deploy/crds/ >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl -n "$NS" delete secret anthropic-key --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic anthropic-key \
  --from-literal=api-key="${ANTHROPIC_API_KEY:-sk-ant-placeholder}" >/dev/null
kubectl -n "$NS" delete configmap support-slo-samples --ignore-not-found >/dev/null
kubectl -n "$NS" delete promptversion --all --ignore-not-found >/dev/null 2>&1 || true
# Delete the Agent too: its status.promotionsFrozen persists across runs on a
# reused cluster, and a stale freeze would break Phase A's "not frozen" check.
kubectl -n "$NS" delete agent --all --ignore-not-found >/dev/null 2>&1 || true
kubectl create configmap support-slice-gate -n "$NS" \
  --from-file=dataset.yaml="$ROOT"/slice/datasets/gate.yaml \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

say "OTel collector (docker, debug exporter — the metric-leg witness)"
docker rm -f "$COLLECTOR" >/dev/null 2>&1 || true
docker run -d --name "$COLLECTOR" -p 4317:4317 \
  -v "$ROOT/slice/otel-collector.yaml":/etc/otelcol-contrib/config.yaml \
  otel/opentelemetry-collector-contrib:0.130.1 >/dev/null

say "Operator (local jar against the kind cluster)"
java -jar "$OPERATOR_DIR"/target/agent-operator-*.jar >/tmp/agent-slo-operator.log 2>&1 &
OPERATOR_PID=$!
PF_PID=""
trap 'kill $OPERATOR_PID 2>/dev/null || true; [ -n "$PF_PID" ] && kill $PF_PID 2>/dev/null || true; docker rm -f "$COLLECTOR" >/dev/null 2>&1 || true' EXIT
sleep 5

kubectl apply -f "$ROOT"/slice/manifests/agent.yaml >/dev/null

if [ "$MODE" = full ]; then
  say "Waiting for the deployed starter, then port-forwarding it"
  # The operator creates the Deployment asynchronously; wait for it to exist
  # before rollout status (which errors immediately on NotFound).
  for _ in $(seq 1 24); do
    kubectl -n "$NS" get deploy/support >/dev/null 2>&1 && break
    sleep 5
  done
  start_pf
  TARGET=http://localhost:18080/api/chat
else
  TARGET=echo
fi
export EVALS_JAR METRICS_JAR NS
export SAMPLES_CM=support-slo-samples AGENT_NAME=support

say "Phase A — one degraded run: below minSamples, the SLI must NOT act (RFC §3.3)"
sample "$ROOT"/slice/datasets/sabotaged.yaml "$TARGET"
wait_for "sloMessage reports insufficient data on the 6 recorded events" 75 "insufficient data: 6/20" \
  get agent support -o jsonpath='{.status.sloMessage}'
frozen=$(kubectl -n "$NS" get agent support -o jsonpath='{.status.promotionsFrozen}')
[ "$frozen" != "true" ] || { echo "FAIL: froze on insufficient data"; exit 1; }
echo "OK: not frozen on 6/20 samples"

say "Phase B — three more degraded runs: budget exhausted, freeze must trip"
for i in 2 3 4; do
  sample "$ROOT"/slice/datasets/sabotaged.yaml "$TARGET"
done
wait_for "promotionsFrozen=true" 90 '^true$' \
  get agent support -o jsonpath='{.status.promotionsFrozen}'
kubectl -n "$NS" get agent support -o jsonpath='{.status.sloMessage}'; echo

say "Phase C — a feature PromptVersion is REFUSED while frozen"
kubectl apply -f "$ROOT"/slice/manifests/promptversion-v2.yaml >/dev/null
wait_for "support-v2 phase=Frozen" 60 '^Frozen$' \
  get promptversion support-v2 -o jsonpath='{.status.phase}'
kubectl -n "$NS" get promptversion support-v2 -o jsonpath='{.status.message}'; echo

if [ "${RECORD_GIF:-}" = "1" ] && command -v vhs >/dev/null; then
  say "Recording slice/demo.gif (vhs)"
  (cd "$ROOT" && vhs slice/demo.tape)
fi

say "Phase D — an slo-exempt fix passes the FREEZE (never the GATE)"
kubectl apply -f "$ROOT"/slice/manifests/promptversion-hotfix.yaml >/dev/null
wait_for "hotfix passes the freeze (canary created)" 90 '^(Canary|Evaluating|AwaitingApproval|Promoted|RolledBack)$' \
  get promptversion support-v3-hotfix -o jsonpath='{.status.phase}'
if [ "$MODE" = full ]; then
  wait_for "hotfix Promoted (gate passed)" 420 '^Promoted$' \
    get promptversion support-v3-hotfix -o jsonpath='{.status.phase}'
else
  wait_for "hotfix RolledBack (gate still enforced, keyless canary cannot pass)" 420 '^RolledBack$' \
    get promptversion support-v3-hotfix -o jsonpath='{.status.phase}'
fi

# Note on what this phase proves: that recovery HAPPENS via clean runs rolling
# the window. That it happens through the hysteresis band (holds at 75-100%,
# lifts only below 75%) is asserted precisely by the operator's unit tests
# (SloPolicyCheckTest: hold-in-band, lift-below-threshold) — a wall-clock e2e
# cannot pin the window to an exact consumption value without racing the clock.
say "Phase E — steady runs; the freeze lifts as the bad samples age out of the 5m window"
deadline=$((SECONDS + 600))
while [ "$SECONDS" -lt "$deadline" ]; do
  sample "$ROOT"/slice/datasets/steady.yaml "$TARGET"
  frozen=$(kubectl -n "$NS" get agent support -o jsonpath='{.status.promotionsFrozen}')
  [ "$frozen" = "false" ] && break
  sleep 15
done
[ "$frozen" = "false" ] || { echo "FAIL: freeze never lifted"; exit 1; }
echo "OK: promotions unfrozen"
kubectl -n "$NS" get agent support -o jsonpath='{.status.sloMessage}'; echo

say "Phase F — the parked support-v2 proceeds by itself after recovery"
wait_for "support-v2 leaves Frozen" 120 '^(Canary|Evaluating|AwaitingApproval|Promoted|RolledBack)$' \
  get promptversion support-v2 -o jsonpath='{.status.phase}'
if [ "$MODE" = full ]; then
  wait_for "support-v2 Promoted" 420 '^Promoted$' \
    get promptversion support-v2 -o jsonpath='{.status.phase}'
fi

say "Metric leg — the collector saw the SLI series pushed via meter's instruments"
# grep -c (not -q): -q exits on first match and SIGPIPEs docker logs, which
# set -o pipefail then reports as failure. -c reads the stream to EOF.
[ "$(docker logs "$COLLECTOR" 2>&1 | grep -c "agent.sli.eval_pass_rate")" -gt 0 ] \
  || { echo "FAIL: agent.sli.eval_pass_rate never reached the collector"; exit 1; }
[ "$(docker logs "$COLLECTOR" 2>&1 | grep -c "agent.sli.eval_cases")" -gt 0 ] \
  || { echo "FAIL: agent.sli.eval_cases never reached the collector"; exit 1; }
echo "OK: agent.sli.eval_cases + agent.sli.eval_pass_rate received over OTLP"

say "Result"
kubectl -n "$NS" get agent support
kubectl -n "$NS" get promptversions
echo
echo "=== agent-slo e2e PASSED ($MODE mode) ==="
echo "(kind cluster '$CLUSTER' left running; delete with: kind delete cluster --name $CLUSTER)"
