#!/bin/bash
set -euo pipefail

# =============================================================================
# JVB Benchmark Orchestrator
# Runs benchmark scenarios for JVM and/or Native JVB, collects metrics,
# and generates a final comparison report.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Cleanup trap -------------------------------------------------------------
cleanup() {
    echo "[$(date '+%H:%M:%S')] Cleaning up..."
    jobs -p | xargs -r kill 2>/dev/null || true
    docker compose -f "$SCRIPT_DIR/docker-compose.benchmark.yml" --profile native --profile jvm down 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Defaults ----------------------------------------------------------------
MODE="both"
SCENARIO="all"
OUTPUT_DIR=""

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.benchmark.yml"
SELENIUM_HUB="http://localhost:4445/wd/hub"
JVB_HEALTH="http://localhost:8080/about/health"
JVB_COLIBRI="http://localhost:8080/colibri/stats"
JVB_METRICS="http://localhost:8080/metrics"
WEB_URL="https://localhost:8445"
ROOM_BASE_URL="https://web"

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--mode native|jvm|both] [--scenario basic|medium|stress|all] [--output-dir <dir>]"
            exit 1
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/results/$(date +%Y%m%d_%H%M%S)"
fi

# Validate arguments
case "$MODE" in
    native|jvm|both) ;;
    *) echo "ERROR: --mode must be native, jvm, or both"; exit 1 ;;
esac

case "$SCENARIO" in
    basic|medium|stress|all) ;;
    *) echo "ERROR: --scenario must be basic, medium, stress, or all"; exit 1 ;;
esac

# --- Logging helper ----------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# --- Helper: wait_for_service ------------------------------------------------
# Polls a URL until HTTP 200 or timeout (seconds).
wait_for_service() {
    local url="$1"
    local timeout="$2"
    local description="$3"
    local start_time
    start_time=$(date +%s)
    local deadline=$((start_time + timeout))

    log "Waiting for $description at $url (timeout: ${timeout}s)..."
    while true; do
        local now
        now=$(date +%s)
        if (( now >= deadline )); then
            log "ERROR: Timed out waiting for $description after ${timeout}s"
            return 1
        fi
        if curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -q '^200$'; then
            local elapsed=$((now - start_time))
            log "$description is ready (took ${elapsed}s)"
            return 0
        fi
        sleep 2
    done
}

# --- Helper: create_selenium_sessions ----------------------------------------
# Creates Chrome sessions via Selenium WebDriver and navigates to Jitsi rooms.
# Prints session IDs (one per line) to stdout.
create_selenium_sessions() {
    local hub_url="$1"
    local room_url="$2"
    local count="$3"
    local session_ids=()

    local capabilities
    capabilities=$(cat <<'CAPEOF'
{
  "capabilities": {
    "alwaysMatch": {
      "acceptInsecureCerts": true,
      "browserName": "chrome",
      "goog:chromeOptions": {
        "args": ["--headless", "--no-sandbox", "--disable-dev-shm-usage", "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required", "--disable-gpu"]
      }
    }
  }
}
CAPEOF
)

    for i in $(seq 1 "$count"); do
        local response
        response=$(curl -s -X POST "$hub_url/session" \
            -H "Content-Type: application/json" \
            -d "$capabilities" 2>/dev/null) || {
            log "WARNING: Failed to create Selenium session $i/$count"
            continue
        }

        local session_id
        session_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['value']['sessionId'])" 2>/dev/null) || {
            log "WARNING: Could not extract session ID for session $i/$count"
            continue
        }

        # Navigate to the Jitsi room
        curl -s -X POST "$hub_url/session/$session_id/url" \
            -H "Content-Type: application/json" \
            -d "{\"url\": \"$room_url\"}" >/dev/null 2>&1 || {
            log "WARNING: Failed to navigate session $session_id to $room_url"
        }

        session_ids+=("$session_id")
        log "  Created session $i/$count: $session_id -> $room_url"
    done

    printf '%s\n' "${session_ids[@]}"
}

# --- Helper: cleanup_selenium_sessions ---------------------------------------
cleanup_selenium_sessions() {
    local hub_url="$1"
    shift
    local session_ids=("$@")

    log "Cleaning up ${#session_ids[@]} Selenium session(s)..."
    for sid in "${session_ids[@]}"; do
        curl -s -X DELETE "$hub_url/session/$sid" >/dev/null 2>&1 || true
    done
    log "Selenium sessions cleaned up."
}

# --- Helper: collect_metrics_background --------------------------------------
# Spawns a background process that collects JVB and container metrics every 5s.
# Returns the PID via stdout.
collect_metrics_background() {
    local out_dir="$1"
    local duration="$2"
    local container_name="${3:-}"

    (
        local end_time=$(( $(date +%s) + duration ))
        local tick=0
        while (( $(date +%s) < end_time )); do
            local ts
            ts=$(date +%s)

            # Colibri stats (JSONL — one JSON object per line)
            curl -s "$JVB_COLIBRI" >> "$out_dir/colibri_stats.jsonl" 2>/dev/null && \
                echo "" >> "$out_dir/colibri_stats.jsonl" || true

            # Prometheus metrics
            echo "# ts=$ts" >> "$out_dir/prometheus_metrics.txt"
            curl -s "$JVB_METRICS" >> "$out_dir/prometheus_metrics.txt" 2>/dev/null && \
                echo "" >> "$out_dir/prometheus_metrics.txt" || true

            # Container resources (docker_stats.csv)
            if [[ -n "$container_name" ]]; then
                local stats
                stats=$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$container_name" 2>/dev/null) || stats=","
                echo "$ts,$stats" >> "$out_dir/docker_stats.csv"
            fi

            tick=$((tick + 1))
            sleep 5
        done
    ) &

    echo $!
}

# --- Helper: measure_startup_time --------------------------------------------
# Starts the compose stack for the given profile, measures time to first
# healthy JVB response, and writes the result.
measure_startup_time() {
    local compose_file="$1"
    local profile="$2"
    local out_file="$3"

    local start_ts
    start_ts=$(date +%s%N)

    log "Starting infrastructure with profile '$profile'..."
    docker compose -f "$compose_file" --profile "$profile" up -d

    # Wait for JVB health
    local timeout=120
    local start_s
    start_s=$(date +%s)
    local deadline=$((start_s + timeout))

    while true; do
        local now
        now=$(date +%s)
        if (( now >= deadline )); then
            log "ERROR: JVB did not become healthy within ${timeout}s"
            echo "TIMEOUT" > "$out_file"
            return 1
        fi
        if curl -sk -o /dev/null -w '%{http_code}' "$JVB_HEALTH" 2>/dev/null | grep -q '^200$'; then
            break
        fi
        sleep 1
    done

    local end_ts
    end_ts=$(date +%s%N)
    local elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))

    log "Startup time for $profile: ${elapsed_ms}ms"
    echo "$elapsed_ms" > "$out_file"
}

# --- Helper: measure_container_resources -------------------------------------
measure_container_resources() {
    local container_name="$1"
    local output_file="$2"
    local duration="$3"

    echo "timestamp,cpu_percent,mem_usage" > "$output_file"

    local end_time=$(( $(date +%s) + duration ))
    while (( $(date +%s) < end_time )); do
        local ts
        ts=$(date +%s)
        local stats
        stats=$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$container_name" 2>/dev/null) || stats=","
        echo "$ts,$stats" >> "$output_file"
        sleep 5
    done
}

# =============================================================================
# Scenario definitions
# =============================================================================

# Each scenario: name, participant_count, conference_count, participants_per_conf, duration_s
declare -A SCENARIO_PARTICIPANTS SCENARIO_CONFERENCES SCENARIO_PER_CONF SCENARIO_DURATION
SCENARIO_PARTICIPANTS[basic]=3
SCENARIO_CONFERENCES[basic]=1
SCENARIO_PER_CONF[basic]=3
SCENARIO_DURATION[basic]=60

SCENARIO_PARTICIPANTS[medium]=15
SCENARIO_CONFERENCES[medium]=2
SCENARIO_PER_CONF[medium]=8   # ~8 per room, 15 total across 2
SCENARIO_DURATION[medium]=180

SCENARIO_PARTICIPANTS[stress]=50
SCENARIO_CONFERENCES[stress]=5
SCENARIO_PER_CONF[stress]=10
SCENARIO_DURATION[stress]=300

# =============================================================================
# Run a single scenario for a given mode
# =============================================================================
run_scenario() {
    local mode="$1"
    local scenario="$2"
    local base_dir="$OUTPUT_DIR/$mode/$scenario"

    local total_participants=${SCENARIO_PARTICIPANTS[$scenario]}
    local num_conferences=${SCENARIO_CONFERENCES[$scenario]}
    local per_conf=${SCENARIO_PER_CONF[$scenario]}
    local duration=${SCENARIO_DURATION[$scenario]}

    log "=========================================="
    log "Running scenario: $scenario (mode=$mode)"
    log "  Participants: $total_participants across $num_conferences conference(s)"
    log "  Duration: ${duration}s"
    log "=========================================="

    mkdir -p "$base_dir"

    # Initialize container resource CSV
    echo "timestamp,cpu_percent,mem_usage" > "$base_dir/docker_stats.csv"

    # Determine JVB container name
    local jvb_container
    jvb_container=$(docker compose -f "$COMPOSE_FILE" --profile "$mode" ps --format '{{.Name}}' 2>/dev/null | grep -i jvb | head -1) || jvb_container=""

    # Start background metrics collection
    local metrics_pid
    metrics_pid=$(collect_metrics_background "$base_dir" "$duration" "$jvb_container")
    log "Metrics collector started (PID: $metrics_pid)"

    # Create Selenium sessions across conferences
    local all_session_ids=()
    local remaining=$total_participants

    for c in $(seq 1 "$num_conferences"); do
        local room_name="benchmark-${scenario}-room-${c}"
        local room_url="${ROOM_BASE_URL}/${room_name}#config.p2p.enabled=false"

        local count=$per_conf
        if (( remaining < per_conf )); then
            count=$remaining
        fi
        if (( count <= 0 )); then
            break
        fi

        log "Creating $count participant(s) in room: $room_name"
        local sids
        sids=$(create_selenium_sessions "$SELENIUM_HUB" "$room_url" "$count")
        while IFS= read -r sid; do
            [[ -n "$sid" ]] && all_session_ids+=("$sid")
        done <<< "$sids"

        remaining=$((remaining - count))
    done

    log "Total active sessions: ${#all_session_ids[@]}"
    log "Holding for ${duration}s while collecting metrics..."
    sleep "$duration"

    # Take final snapshot
    log "Collecting final metric snapshot..."
    curl -s "$JVB_COLIBRI" > "$base_dir/final_colibri_stats.json" 2>/dev/null || true
    curl -s "$JVB_METRICS" > "$base_dir/final_prometheus_metrics.txt" 2>/dev/null || true
    if [[ -n "$jvb_container" ]]; then
        docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$jvb_container" \
            > "$base_dir/final_container_stats.txt" 2>/dev/null || true
    fi

    # Stop background metrics collection
    if kill -0 "$metrics_pid" 2>/dev/null; then
        kill "$metrics_pid" 2>/dev/null || true
        wait "$metrics_pid" 2>/dev/null || true
    fi
    log "Metrics collector stopped."

    # Cleanup Selenium sessions
    if (( ${#all_session_ids[@]} > 0 )); then
        cleanup_selenium_sessions "$SELENIUM_HUB" "${all_session_ids[@]}"
    fi

    log "Scenario '$scenario' complete for mode '$mode'."
}

# =============================================================================
# Run all scenarios for a given mode
# =============================================================================
run_mode() {
    local mode="$1"

    log "============================================================"
    log "Starting benchmarks for mode: $mode"
    log "============================================================"

    # Create directory structure
    local scenarios_to_run=()
    if [[ "$SCENARIO" == "all" ]]; then
        scenarios_to_run=(basic medium stress)
    else
        scenarios_to_run=("$SCENARIO")
    fi

    for s in "${scenarios_to_run[@]}"; do
        mkdir -p "$OUTPUT_DIR/$mode/$s"
    done

    # Measure startup time (starts infrastructure)
    measure_startup_time "$COMPOSE_FILE" "$mode" "$OUTPUT_DIR/$mode/startup_time.txt"

    # Wait for all required services
    wait_for_service "$WEB_URL" 120 "Jitsi Web" || { log "ERROR: Web not reachable, skipping mode $mode"; docker compose -f "$COMPOSE_FILE" --profile "$mode" down; return 1; }
    wait_for_service "${SELENIUM_HUB}/status" 120 "Selenium Hub" || { log "ERROR: Selenium not reachable, skipping mode $mode"; docker compose -f "$COMPOSE_FILE" --profile "$mode" down; return 1; }
    wait_for_service "$JVB_HEALTH" 120 "JVB Health" || { log "ERROR: JVB not healthy, skipping mode $mode"; docker compose -f "$COMPOSE_FILE" --profile "$mode" down; return 1; }

    log "All services are ready."

    # Run each scenario
    for s in "${scenarios_to_run[@]}"; do
        run_scenario "$mode" "$s" || {
            log "WARNING: Scenario '$s' failed for mode '$mode', continuing..."
        }
    done

    # Tear down infrastructure
    log "Stopping infrastructure for mode '$mode'..."
    docker compose -f "$COMPOSE_FILE" --profile "$mode" down
    log "Infrastructure stopped for mode '$mode'."
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "============================================================"
    log "JVB Benchmark Orchestrator"
    log "  Mode:       $MODE"
    log "  Scenario:   $SCENARIO"
    log "  Output dir: $OUTPUT_DIR"
    log "============================================================"

    mkdir -p "$OUTPUT_DIR"

    local modes_to_run=()
    if [[ "$MODE" == "both" ]]; then
        modes_to_run=(jvm native)
    else
        modes_to_run=("$MODE")
    fi

    for m in "${modes_to_run[@]}"; do
        run_mode "$m" || {
            log "ERROR: Mode '$m' encountered errors."
        }
    done

    # Generate comparison report
    log "Generating final report..."
    if [[ -x "$SCRIPT_DIR/generate-report.sh" ]]; then
        "$SCRIPT_DIR/generate-report.sh" "$OUTPUT_DIR"
    elif [[ -f "$SCRIPT_DIR/generate-report.sh" ]]; then
        bash "$SCRIPT_DIR/generate-report.sh" "$OUTPUT_DIR"
    else
        log "WARNING: generate-report.sh not found, skipping report generation."
    fi

    log "============================================================"
    log "Benchmarks complete. Results saved to: $OUTPUT_DIR"
    log "============================================================"
}

main
