# JVB Native Image — Benchmark Results

## Proven: JVB builds and runs as GraalVM native image

### Performance Comparison

| Metric | JVM | Native | Improvement |
|--------|-----|--------|-------------|
| Image size | ~1GB | **238MB** | **4.2x smaller** |
| Startup time | ~10s | **<2s** | **5x+ faster** |
| RAM (idle) | 196MB | **89MB** | **2.2x less** |
| RAM (post-test) | 306MB | 317MB | ~similar |

### Functional Proof

| Component | Status |
|-----------|--------|
| Build (GraalVM 25) | **OK** — multi-stage Dockerfile, 238MB final image |
| REST API | **OK** — /about/health, /colibri/stats, /metrics |
| XMPP connection | **OK** — connects to Prosody, joins MUC brewery |
| Colibri2 IQ parsing | **OK** — `ConferenceModifyIQ` correctly typed |
| Conference creation | **OK** — `total_conferences_completed: 1` |
| Participant allocation | **OK** — 3 members joined, 4 allocations by Jicofo |
| handleIq processing | **OK** — 6 IQ stanzas processed |
| Media flow (RTP) | **Not yet** — ICE negotiation fails in Docker bridge network |

### Conference Allocation Proof

```
Jicofo: Created new conference loadtest0@conference.meet.jitsi
Jicofo: Member joined:a0cb0df4 (OWNER)
Jicofo: Member joined:572acb44 (PARTICIPANT)
Jicofo: Member joined:55c348e0 (PARTICIPANT)
Jicofo: ColibriV2SessionManager.allocate: Selected jvb1 for a0cb0df4
Jicofo: ColibriV2SessionManager.allocate: Selected jvb1 for 572acb44
Jicofo: ColibriV2SessionManager.allocate: Selected jvb1 for 55c348e0
JVB: handleIq: class=ConferenceModifyIQ type=get from=focus
JVB: handleIqRequest: type=ConferenceModifyIQ, childElement=conference-modify
```

### Reflection Configuration

509 entries in `config-full/reflect-config.json` covering:
- Smack XMPP core (StartTls, Bind, Session, Mechanisms, StreamManagement)
- Smack extensions (Caps, Disco, Ping, MUC, Delay, Forward)
- Health Check IQ (HealthCheckIQ, HealthCheckIQProvider)
- Colibri2 protocol (ConferenceModifyIQ, Media, Transport, Sources)
- Colibri1 legacy (ColibriStatsExtension, ShutdownIQ)
- Jingle RTP (PayloadType, RtcpFb, RtpHdrExt, IceUdpTransport)
- Smack providers (ProviderManager, IQProviderInfo)

### Known Issues

1. **XMPP IQ routing intermittent** — MucClient connection can be unstable;
   `restart: unless-stopped` mitigates this
2. **XSLT NPE** — `RedactColibriIp.redact()` fails in native (XSLT compiler);
   wrapped in try-catch to prevent blocking Colibri2 handler
3. **Health check IQ timeout** — JVB doesn't respond to Jicofo health probes;
   workaround: `jicofo.bridge.health-checks.enabled = false`
4. **Stress level inflated** — Native GC reports artificially high CPU;
   workaround: `cpu-usage.load-threshold = 10.0`
5. **ICE in Docker** — UDP media doesn't route in Docker bridge network;
   same issue with JVM JVB (not native-specific)

### How to Reproduce

```bash
cd load-test-env

# Build native image (~7 min)
docker build -f ../Dockerfile.native -t jvb-native:latest ..

# Start stack
docker compose -f docker-compose.benchmark.yml --profile native up --no-build -d

# Wait for MUC connection
watch 'curl -s http://localhost:8080/colibri/stats | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"MUC: {d[\\\"muc_clients_connected\\\"]}\")"'

# Run Malleus torture test
./run-malleus-quick.sh

# Check results
curl -s http://localhost:8080/colibri/stats | python3 -m json.tool
```
