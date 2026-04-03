# JVB Native Image — Current Status

## What Works

| Component | Status | Details |
|-----------|--------|---------|
| GraalVM Native Build | OK | 238MB image, ~7min build time |
| Startup Time | OK | <2s (vs ~10s JVM) |
| REST API | OK | /about/health, /colibri/stats, /metrics all working |
| XMPP Connection | OK | Connects to Prosody via Smack TCP |
| MUC Brewery Join | OK | `muc_clients_connected: 1` |
| Stress Level | OK | 0.02-0.05 (after load-threshold fix) |
| Memory (idle) | OK | ~47MB RSS (vs ~280MB JVM) |

## What Needs Work

| Component | Status | Root Cause |
|-----------|--------|------------|
| Health Check IQ | TIMEOUT | JVB native doesn't respond to Jicofo health check IQ via XMPP. Smack IQ handler routing fails silently in native. |
| Colibri2 IQ Parsing | PARTIAL | `ConferenceModifyIQ` parsing fails on Jingle RTP elements (PayloadType, etc.) — reflection classes added but still failing |
| /about/version | ERROR | `Version$VersionInfo` serialization missing reflection |
| Conference Allocation | BLOCKED | Jicofo marks bridge as non-operational due to health check timeout → no conference assigned to native JVB |

## Workaround Applied

Disabling Jicofo health checks via `custom-jicofo.conf`:
```
jicofo.bridge.health-checks.enabled = false
```

This keeps the bridge operational, but the Colibri2 IQ parsing still needs to be fixed for conferences to be allocated.

## Reflection Classes Added (since PR #2382)

Total entries in `reflect-config.json`: 509

Key additions:
- **Smack XMPP core**: StartTls, Bind, Session, Mechanisms, StreamManagement (6 classes)
- **Smack extensions**: CapsExtension, DiscoverInfo, Ping, MUC, Delay, Forward (36 classes)
- **Health Check**: HealthCheckIQ, HealthCheckIQProvider, HealthStatusPacketExt (4 classes)
- **Colibri2**: ConferenceModifyIQ, providers, Media, Transport, Sctp, Sources (20 classes)
- **Colibri1**: ColibriStatsExtension, ColibriStatsIQ, ShutdownIQ (7 classes)
- **Jingle RTP**: PayloadType, RtcpFb, RtpHdrExt, IceUdpTransport (12 classes)
- **Smack Providers**: ProviderManager, IQProviderInfo, extension providers (16 classes)
- **JVB XMPP**: Smack.kt, XmppConnection, Videobridge handlers (5 classes)

## Next Steps

1. **Fix Colibri2 IQ handling**: The native JVB needs to correctly parse and respond to `<conference-modify>` IQ stanzas. This requires debugging the Smack IQ routing mechanism in native mode.

2. **Fix Health Check IQ**: Either fix the IQ handler registration in native (preferred) or keep the workaround of disabling health checks.

3. **Run benchmarks**: Once media flows through the native JVB, run the full benchmark suite (`run-benchmarks.sh`) to generate the comparison report.

## Build & Test Commands

```bash
# Build native image
docker build -f Dockerfile.native -t jvb-native:latest .

# Start test stack
cd load-test-env
docker compose -f docker-compose.benchmark.yml --profile native up --no-build -d

# Run Malleus torture test
./run-malleus-quick.sh

# Check JVB stats
curl -s http://localhost:8080/colibri/stats | python3 -m json.tool
```
