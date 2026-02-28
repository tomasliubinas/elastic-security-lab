# Elastic Security Lab

## What is this?

This project sets up a fully functional **endpoint security and monitoring solution** on your Mac using the Elastic Stack — the same technology used by security teams in large enterprises. It serves two purposes simultaneously: it is a **hands-on research lab** for exploring how modern security tooling works, and a **practical security solution** that actively monitors your Mac for threats, suspicious behaviour, and security events.

Think of it as running your own antivirus and security operations centre (SOC) locally — with full visibility into what is happening on your machine, real-time threat detection, and a professional-grade UI to investigate events.

## Stack Components

The solution is built from four components, all running locally:

- **Elasticsearch** — the database at the heart of the stack. All security events (process launches, file access, network connections, login attempts) are stored and indexed here for fast search and analysis. If you have heard of Elasticsearch for log search or observability, this is the same engine — here used specifically for security data.

- **Kibana** — the web UI you open in your browser. It provides the Security dashboard, alerts, an event explorer (Discover), and the Fleet management console. This is where you investigate incidents, write detection queries, and see what your Mac is doing in real time.

- **Fleet Server** — a lightweight coordination service that manages the Elastic Agent running on your Mac. It delivers configuration policies to the agent and keeps it up to date. You do not interact with it directly.

- **Elastic Agent** — installed directly on your Mac (not in Docker). It is the data collector and enforcer. It runs two sub-components:
  - **Elastic Defend** — the EDR (Endpoint Detection and Response) engine. Functions as an antivirus and behavioural threat detector: monitors processes, memory, file changes, and network activity for malicious patterns.
  - **System integration** — collects operating system logs such as authentication events, sudo usage, and syslog for broader visibility.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Docker (elastic-security network)                           │
│                                                              │
│  ┌───────────────┐          ┌──────────┐                    │
│  │ Elasticsearch │◄─────────│  Kibana  │                    │
│  │  :9200 (HTTP) │          │  :5601   │                    │
│  └───────────────┘          └──────────┘                    │
│         ▲                                                    │
│         │ reads policies / writes check-ins & events         │
│  ┌───────────────┐                                           │
│  │ Fleet Server  │                                           │
│  │  :8220 (HTTP) │                                           │
│  └───────────────┘                                           │
└──────────────────────────────────────────────────────────────┘
         ▲                        ▲
         │ events (logs/EDR)      │ policy / check-in
┌─────────────────────────────────────────────────────────────┐
│  Mac Host                                                   │
│  Elastic Agent (/Library/Elastic/Agent)                     │
│   ├── Elastic Defend  (EDR / malware detection)             │
│   └── System          (auth logs, syslog, metrics)          │
└─────────────────────────────────────────────────────────────┘
```

## Requirements

- macOS (Intel or Apple Silicon)
- Docker Desktop
- ~6 GB RAM available for Docker

## Quick Start

### First time setup

```bash
cp .env.example .env     # create your local config (gitignored)
# edit .env to change passwords if desired
docker compose down -v   # wipe any previous data (skip on a fresh clone)
./setup.sh               # full setup: stack + agent install (~10 min)
```

`setup.sh` will:
1. Start Elasticsearch and Kibana
2. Create Fleet service token and Fleet Server agent policy
3. Start Fleet Server
4. Download Elastic Agent for your Mac architecture (Intel or Apple Silicon)
5. Attempt to automatically install and enroll the agent (requires sudo)

> **If auto-enroll fails** (e.g. script was interrupted), complete it manually — see [Enrolling the Mac Agent](#enrolling-the-mac-agent) below.

### Day-to-day

```bash
# Stop
docker compose down

# Start again (data preserved, no re-setup needed)
./restart.sh
```

> `restart.sh` also fixes a known issue where Kibana resets the Fleet Server URL on restart — this is handled automatically.

---

## Enrolling the Mac Agent

After `setup.sh` completes (or if you need to re-enroll manually):

1. Open Kibana → **☰ → Management → Fleet → Agents → Add agent**
2. Select **Create a new agent policy** → name it `Mac Monitoring Policy` → Create
3. `setup.sh` downloads Elastic Agent automatically into this directory — find it with:
```bash
ls -d elastic-agent-*/
```
4. Kibana shows an install command. **Do not use it as-is** — replace the URL with `http://localhost:8220` and add `--insecure`:

```bash
cd /path/to/ElasticSecurity

sudo ./<agent-dir>/elastic-agent install \
  --url=http://localhost:8220 \
  --enrollment-token=<TOKEN FROM KIBANA> \
  --insecure
```

Where `<agent-dir>` is the directory from step 3, e.g. `elastic-agent-8.17.0-darwin-aarch64` (Apple Silicon) or `elastic-agent-8.17.0-darwin-x86_64` (Intel).

> The `--insecure` flag is required because Fleet Server runs without TLS in this lab setup.

4. Click **Confirm agent enrollment** in Kibana
5. Your Mac should appear in **Fleet → Agents** with status **Healthy** within ~30 seconds

## Access

| Service | URL | Credentials |
|---|---|---|
| Kibana | http://localhost:5601 | elastic / ElasticLab2024! |
| Elasticsearch | http://localhost:9200 | elastic / ElasticLab2024! |
| Fleet Server | http://localhost:8220 | — |

## Scripts

| File | Purpose |
|---|---|
| `.env.example` | Template for environment config — copy to `.env` before first run |
| `./setup.sh` | Full first-time setup (or after data wipe) |
| `./restart.sh` | Start an already-configured stack |
| `./stop.sh` | Stop containers, preserve data |
| `./uninstall-agent.sh` | Remove Elastic Agent from this Mac |

## Post-Setup: Adding Integrations

After the Mac agent is enrolled and showing **Healthy**, add integrations to its policy:

**☰ → Management → Fleet → Agent Policies → Mac Monitoring Policy → Add integration**

### 1. Elastic Defend (EDR)
- Search: `Elastic Defend` → select it → **Add Elastic Defend**
- **Protection mode**: `Detect` (alerts only, does not block — recommended for research)
- Leave all other defaults → **Save and deploy changes**
- Enables: malware detection, process trees, memory threat analysis, file monitoring

### 2. System
- Search: `System` → select it → **Add System**
- Leave all defaults → **Save and deploy changes**
- Collects: auth logs (`/var/log/auth.log`), syslog, process and disk metrics

> After deploying, wait ~60 seconds for the agent to apply the new policy. Events will start appearing in Discover shortly after.

## Viewing Events

| Where | What |
|---|---|
| ☰ → Analytics → Discover → `logs-*` | All raw events from your Mac |
| ☰ → Analytics → Discover → `logs-system.auth-*` | Login attempts, sudo |
| ☰ → Analytics → Discover → `logs-endpoint.*` | EDR process/file/network events |
| ☰ → Security → Alerts | Triggered detection rules |
| ☰ → Security → Events | Endpoint event explorer |

## Enabling Detection Rules

**☰ → Security → Rules → Detection rules (SIEM)**

1. Click **Load Elastic prebuilt rules**
2. Filter by tag **macOS** → select all → **Enable**
3. Filter by tag **Endpoint** → select all → **Enable**

## Wazuh Comparison

| Feature | Elastic Security | Wazuh |
|---|---|---|
| Log collection | Elastic Agent / Beats | Wazuh Agent |
| EDR | Elastic Defend (process trees, memory) | Basic FIM + syscall |
| SIEM UI | Kibana Security | OpenSearch Dashboards |
| Threat hunting | KQL / ES\|QL | Custom query language |
| Prebuilt rules | 1000+ (MITRE ATT&CK) | ~3000 (different coverage) |
| Free tier | Basic license | Open source |

## Troubleshooting

### Kibana not loading
```bash
docker compose up -d kibana
docker logs -f kibana | grep -E '"level":"(available|error)"'
```

### Agent unhealthy — "lookup host.docker.internal: no such host"
Kibana resets the Fleet Server URL to `host.docker.internal` on every restart. This hostname is only resolvable inside Docker containers, not on the Mac host. `restart.sh` fixes this automatically. If you need to fix it manually:
```bash
./restart.sh   # fixes Fleet Server host URL automatically
```
When enrolling an agent via the Kibana wizard, always replace `host.docker.internal` with `localhost` in the install command.

### No events in Discover
1. Check agent is healthy: Fleet → Agents
2. Confirm integrations are added: Fleet → Agent Policies → your policy
3. Check indices exist:
```bash
source .env
curl -s -u "elastic:${ELASTIC_PASSWORD}" \
  "http://localhost:9200/_cat/indices?h=index,docs.count" \
  | grep -v "^\." | sort -k2 -rn | head -20
```

### Full reset
```bash
./uninstall-agent.sh      # remove agent from Mac
docker compose down -v    # wipe all data
./setup.sh                # start fresh
```

## Stack Versions

- Elastic Stack: **8.17.0**
- Elastic Agent: **8.17.x** (downloaded by setup.sh for your Mac architecture)
