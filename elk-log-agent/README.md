# ELK Log Analysis Agent

Agentic CLI tool that retrieves logs from Elasticsearch via curl, classifies errors, detects patterns, and generates reports with actionable recommendations.

## Prerequisites

- `bash` (4.0+)
- `curl`
- `jq`

## Quick Start

```bash
# 1. Configure
cp config.env.example config.env
# Edit config.env with your Elasticsearch endpoint and credentials

# 2. Run
./elk-agent.sh

# Or pass options directly:
./elk-agent.sh -e https://my-elk:9200 -i "app-logs-*" -t 6h -l error
```

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `-c, --config FILE` | Config file path | `config.env` |
| `-e, --endpoint URL` | Elasticsearch endpoint | (from config) |
| `-i, --index PATTERN` | Index pattern | `filebeat-*` |
| `-t, --time-range RANGE` | Time range (e.g., `15m`, `1h`, `7d`) | `1h` |
| `-l, --level LEVEL` | Log level: `error`, `warn`, `info`, `debug`, `all` | `error` |
| `-n, --max-results N` | Max log entries to retrieve | `500` |
| `-q, --query QUERY` | Custom Lucene query filter | (none) |
| `-o, --output FILE` | Output report file path | auto-generated |
| `-j, --json` | Output raw analysis JSON | `false` |
| `--skip-health` | Skip cluster health check | `false` |
| `--debug` | Enable debug output | `false` |

## Examples

```bash
# Analyze errors from the last 24 hours for a specific service
./elk-agent.sh -t 24h -q "service.name:payment-api"

# Get JSON output for piping to other tools
./elk-agent.sh -j | jq '.summary'

# Use API key auth via environment variables
ELK_ENDPOINT="https://elk:9200" ELK_API_KEY="base64key" ./elk-agent.sh

# Analyze warnings and errors, save to specific file
./elk-agent.sh -l warn -o /tmp/incident-report.md
```

## Output

The agent produces:
- **Terminal summary** — quick overview of findings
- **Markdown report** (`reports/elk_report_YYYYMMDD_HHMMSS.md`) — full analysis with recommendations
- **JSON data** (`reports/elk_report_YYYYMMDD_HHMMSS.json`) — structured analysis for programmatic use

## Agent Workflow

1. **Configure** — Load endpoint, auth, and query parameters
2. **Health Check** — Verify Elasticsearch cluster is reachable
3. **Retrieve** — Query logs via `curl` to the `_search` API
4. **Analyze** — Classify errors into categories, detect patterns (bursts, repeats, cross-service failures)
5. **Report** — Generate markdown report with severity assessment, recommendations, and next steps checklist

## Error Categories

The agent classifies errors into: Connection/Network, Memory, Disk/Storage, Auth, Database, HTTP 5xx/4xx, Application, Configuration, and Resource Limits.

## Authentication

Supports three methods (configure in `config.env`):
- **Basic auth** — `ELK_USERNAME` + `ELK_PASSWORD`
- **API key** — `ELK_API_KEY` (base64-encoded `id:api_key`)
- **Bearer token** — `ELK_BEARER_TOKEN`
