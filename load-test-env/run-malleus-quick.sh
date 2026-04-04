#!/bin/bash
set -euo pipefail

# Quick Malleus test: 1 conference, 3 participants, 60s
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[$(date +%H:%M:%S)] Starting Malleus: 1 conference, 3 participants, 60s..."

docker volume create maven-cache 2>/dev/null || true

# Run Malleus via Maven directly with ALL required properties
# The pom.xml references ${argLine} (for jacoco) which must be set to empty
docker run --rm --name malleus-test \
  --network load-test-env_benchmark-net \
  -v "$SCRIPT_DIR/torture:/app:Z" \
  -v maven-cache:/root/.m2 \
  -w /app \
  maven:3.9.9-eclipse-temurin-21 \
  mvn test \
    -Dthreadcount=3 \
    -Djitsi-meet.tests.toRun=MalleusJitsificus \
    -Djitsi-meet.instance.url=https://benchmark-web \
    -Djitsi-meet.isRemote=true \
    -Dremote.address=http://benchmark-selenium-hub:4444/wd/hub \
    -DallowInsecureCerts=true \
    -Dorg.jitsi.malleus.conferences=1 \
    -Dorg.jitsi.malleus.participants=3 \
    -Dorg.jitsi.malleus.senders=3 \
    -Dorg.jitsi.malleus.audio_senders=3 \
    -Dorg.jitsi.malleus.duration=60 \
    -Dorg.jitsi.malleus.join_delay=0 \
    -Dorg.jitsi.malleus.room_name_prefix=loadtest \
    -Dorg.jitsi.malleus.enable_p2p=false \
    -Dorg.jitsi.malleus.enable.headless=true \
    -Dorg.jitsi.malleus.use_load_test=false \
    -Dorg.jitsi.malleus.use_lite_mode=false \
    -Dorg.jitsi.malleus.use_node_types=false \
    -Dorg.jitsi.malleus.switch_speakers=false \
    -Dorg.jitsi.malleus.use_stage_view=false \
    -Dorg.jitsi.malleus.set.saveLogs=false \
    -Dorg.jitsi.malleus.max_disrupted_bridges_pct=0 \
    -Dorg.jitsi.malleus.sender_tabs_per_browser=1 \
    -Dorg.jitsi.malleus.receiver_tabs_per_browser=1 \
    -Dorg.jitsi.malleus.senders_per_tab=1 \
    -Dorg.jitsi.malleus.receivers_per_tab=1 \
    -Dchrome.disable.nosanbox=true \
  2>&1 | tee "$SCRIPT_DIR/logs/malleus_output.log"

echo ""
echo "[$(date +%H:%M:%S)] Malleus finished."
echo ""
echo "=== JVB Stats after test ==="
docker exec benchmark-jvb-native curl -s http://localhost:8080/colibri/stats 2>/dev/null | python3 -m json.tool || echo "Could not fetch stats"
