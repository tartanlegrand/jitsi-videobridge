# JVB GraalVM Native Image — Benchmark Suite

## Overview

This suite compares Jitsi Videobridge (JVB) running as a standard JVM application versus a GraalVM Native Image. It measures startup time, CPU usage, memory consumption, and media routing performance across multiple scenarios using real browser participants powered by Selenium Grid.

The goal is to provide reproducible, evidence-based benchmarks that demonstrate the viability of a native-image JVB — including proof that media actually flows through the bridge.

## Prerequisites

- **Docker & Docker Compose v2+**
- **16 GB+ RAM** recommended for stress tests
- **8+ CPU cores** recommended
- **`jq`** (for report generation)
- **`curl`**
- The following ports must be available:
  - `8445` — Jitsi Meet web UI
  - `8080` — JVB metrics / Colibri REST
  - `4445` — Selenium Grid Hub
  - `10000/udp` — JVB media (RTP/RTCP)

## Quick Start

```bash
cd load-test-env

# Run all benchmarks (JVM + Native, all scenarios)
./run-benchmarks.sh

# Run only native benchmarks
./run-benchmarks.sh --mode native

# Run specific scenario
./run-benchmarks.sh --mode both --scenario basic

# Custom output directory
./run-benchmarks.sh --output-dir ./my-results
```

## Architecture

The `docker-compose.benchmark.yml` file defines a self-contained test environment with the following services:

| Service | Role |
|---------|------|
| **Prosody** | XMPP server — handles signaling between Jicofo, JVB, and clients |
| **Jicofo** | Jitsi Conference Focus — allocates conferences and assigns participants to JVBs |
| **Web** | Jitsi Meet frontend — serves the web application that Chrome nodes connect to |
| **JVB Native** | Jitsi Videobridge built from `Dockerfile.native` (GraalVM native image) |
| **JVB JVM** | Jitsi Videobridge from `jitsi/jvb:stable` (standard JVM) |
| **Selenium Hub** | Grid hub coordinating browser sessions |
| **Chrome Nodes (x6)** | Headless Chrome instances, 10 sessions each = **60 max concurrent participants** |

All services run on a shared bridge network. **P2P is disabled** to force all media through the JVB, ensuring the bridge is always in the data path.

## Test Scenarios

### Basic (US-003)

- **Participants**: 3 in 1 conference
- **Duration**: 60 seconds
- **Purpose**: Validate that media routing works end-to-end through the native image. This is the smoke test — if this fails, nothing else matters.

### Medium (US-004)

- **Participants**: 15 across 2 conferences
- **Duration**: 180 seconds
- **Purpose**: Simulate a realistic team meeting workload. This scenario stresses the bridge with multiple simultaneous conferences and a moderate participant count.

### Stress (US-005)

- **Participants**: 50+ across 5 conferences
- **Duration**: 300 seconds
- **Purpose**: High-load performance comparison. This pushes both JVM and native builds to their limits, revealing differences in CPU efficiency, memory footprint, and media quality under pressure.

## Metrics Collected

| Metric | Source | Description |
|--------|--------|-------------|
| **Startup time** | Script timer | Time from container start to first successful `/about/health` response |
| **CPU usage** | `docker stats` | Sampled every 5 seconds throughout the test |
| **Memory (RSS)** | `docker stats` | Resident Set Size, sampled every 5 seconds |
| **Colibri stats** | `/colibri/stats` | `conferences`, `participants`, `bit_rate_download`, `bit_rate_upload`, `packet_rate_download`, `packet_rate_upload`, `jitter_aggregate`, `packet_loss` |
| **Prometheus metrics** | `/metrics` | Full JVB metrics dump including `jitsi_jvb_bit_rate_download`, `jitsi_jvb_packet_rate_upload`, and all other exported counters/gauges |

## How Media Flow Is Proven

A key concern raised by bgrozev (Jitsi maintainer) is that benchmarks must prove media actually flows through the bridge — not just that participants join a conference. This suite addresses that concern through multiple layers of evidence:

1. **Real Chrome browsers** connect to Jitsi Meet with fake media streams (`--use-fake-device-for-media-stream`), producing actual audio and video RTP packets.
2. **P2P is disabled** (`ENABLE_P2P=false`), which forces all media to route through the JVB. There is no direct peer-to-peer path.
3. **Colibri stats** are checked for `bit_rate_download > 0` and `packet_rate_upload > 0`, confirming the bridge is actively receiving and forwarding media.
4. **Prometheus metrics** are scraped and verified — `jitsi_jvb_bit_rate_download` and `jitsi_jvb_packet_rate_upload` must be non-zero.
5. **Raw metric excerpts** are included in the generated report so reviewers can independently verify the numbers without re-running the tests.

## Report Generation

Reports are automatically generated at the end of `run-benchmarks.sh`. To regenerate or generate manually:

```bash
./generate-report.sh ./results/TIMESTAMP
```

The report is saved as `BENCHMARK_REPORT.md` inside the results directory. It includes side-by-side JVM vs Native comparisons, metric tables, and the raw evidence of media flow.

## GraalVM Native Image Build

### How it works

1. **Maven** builds a fat JAR using the shade plugin (`-P buildFatJar`), packaging all dependencies into a single artifact.
2. **GraalVM `native-image`** performs ahead-of-time compilation, producing a standalone Linux binary with no JVM dependency.
3. The **runtime image** is based on `debian:bookworm-slim`, keeping the final container minimal.

### Configuration files (`config-full/`)

GraalVM native image requires explicit metadata for dynamic JVM features. These files live in `config-full/` at the repository root:

| File | Purpose |
|------|---------|
| `reflect-config.json` | Reflection metadata for Jackson, Jersey, Kotlin, BouncyCastle, and other libraries |
| `proxy-config.json` | HK2 dynamic proxy interface definitions for Jersey dependency injection |
| `reachability-metadata.json` | Auto-generated reachability metadata from the native-image agent |
| `resource-config.json` | Resource inclusion patterns (XML, properties, `META-INF/services`) |
| `serialization-config.json` | Java serialization class registrations |
| `jvb.conf` | XMPP/Prosody connection configuration for the test environment |

### Regenerating reflection metadata

If dependencies change or new reflection errors appear at runtime, regenerate the metadata:

```bash
# Build and run with the native-image tracing agent
docker build -f Dockerfile.agent -t jvb-agent .
docker run --network host jvb-agent

# The agent writes config-output/ with observed metadata
# Copy to config-full/ and merge with existing entries
# Use convert_metadata.py to deduplicate and merge
```

## Known Limitations

- **WebSocket transport** has not been validated in the native image.
- **SCTP data channels** have not been validated.
- Only tested on **x86_64 Linux**.
- Native image build takes **5-10 minutes** and requires **8 GB+ RAM** for the `native-image` compiler.
- This is a **proof of concept**, not production-ready.

## Troubleshooting

### JVB does not start

- Check logs: `docker compose -f docker-compose.benchmark.yml logs jvb-native`
- Verify `config-full/` directory exists at the repository root with all required config files.
- Ensure Prosody is healthy first — JVB cannot connect without a running XMPP server.

### Selenium sessions fail

- Check hub status: `curl http://localhost:4445/wd/hub/status | jq`
- Verify Chrome nodes are registered and have available sessions.
- Increase `shm_size` in the compose file if browsers crash (shared memory exhaustion).

### No media flow detected

- Verify P2P is disabled (`ENABLE_P2P=false` in the compose environment).
- Ensure at least 2 participants have joined the **same** room.
- Wait 10-15 seconds after join for ICE negotiation and media to stabilize.
- Check JVB logs for ICE connectivity issues.

### Build fails

- Ensure Maven can download dependencies (network access required).
- GraalVM `native-image` needs **8 GB+ RAM** — increase the Docker daemon memory limit if building inside Docker Desktop.

## File Structure

```
load-test-env/
├── docker-compose.benchmark.yml  # Unified benchmark compose
├── run-benchmarks.sh             # Main orchestrator
├── generate-report.sh            # Report generator
├── README.md                     # This file
└── results/                      # Generated benchmark results
    └── YYYYMMDD_HHMMSS/
        ├── native/
        │   ├── startup_time.txt
        │   ├── basic/
        │   ├── medium/
        │   └── stress/
        ├── jvm/
        │   └── (same structure)
        └── BENCHMARK_REPORT.md
```
