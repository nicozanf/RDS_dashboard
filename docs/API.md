For installation commands, see [INSTALL.md](INSTALL.md). For configuration details, see [CONFIG.md](CONFIG.md).


# API endpoints, security and troubleshooting

## API Surface

- `GET /api/data`
  - Returns the latest collector snapshot read from SQLite `snapshot_state.payload_json`
  - Includes lightweight dashboard metadata such as `FarmCatalog`, `FarmServerMap`, `AllServersFarmName`, `NextCycleDelaySeconds`, and `OldestDataTs`
  - Includes collector runspace-pool execution metrics: `InputServersCount`, `StartedWorkersCount`, and `StartFailedServersCount`
  - Does not block on persisted trend-history reads
  - Uses snapshot cache fast-path when `snapshot_state.ts_utc` is unchanged between requests
- `GET /api/server-history?name=<serverShortOrFqdn>`
  - Returns persisted CPU/RAM history for the selected server (2-hour retention window)
- `GET /api/farm-history`
  - Returns persisted farm trend history (up to 70 days)
  - Optional query parameters:
    - `farm=<farmName>` to return only one farm series (for example `All servers`)
    - `days=<1..70>` to bound the returned history window
- `GET /api/server-session-metrics?name=<serverShortOrFqdn>[&debug=1]`
  - Returns live per-session CPU/RAM metrics for the selected server
  - `name` is required and must resolve to a configured server (short name or FQDN)
- `GET /api/server-host-info?name=<serverShortOrFqdn>`
  - Returns on-demand host metadata for the selected server:
    - OS
    - host type (`Virtual` or `Physical` when detectable)
    - total RAM (GB)
    - total CPU cores
    - IP address list
  - `name` is required and must resolve to a configured server (short name or FQDN)
- `GET /api/server-rdp-logins?name=<serverShortOrFqdn>`
  - Returns on-demand successful RDP login events for the selected server from the remote Security log
  - Includes `OldestEventDate`/`OldestEventUtc` (oldest Security event found on that server)
  - Includes `Rows` with: `Username`, `LoginTimeUtc`, `SourceIP`
  - Filters to successful logon events with logon type 10 (RDP)
  - Optional query: `oldestOnly=1` returns only oldest-event metadata without full row scan
  - `name` is required and must resolve to a configured server (short name or FQDN)
- `POST /api/session-action`
  - Form fields:
    - `action`: `disconnect` | `logoff` | `sendmsg`
    - `server`: server FQDN (must be in allowlist)
    - `id`: numeric session id
    - `message`: required only for `sendmsg`
## Server Detail Page

The server detail page is available at:

- `GET /server?name=<serverShortName>`

Where `name` is the server short name used in the dashboard cards/list (for example `RDSAPP01`).

### What it Shows

- Summary stats for the selected server: total sessions, active sessions, disconnected sessions, CPU, RAM, last update time (Europe/Rome)
- On-demand host metadata for the selected server: OS, host type (virtual/physical), total RAM (GB), total cores, and IP address list
- Two live graphs: server CPU and RAM history
- Sortable session table with columns: User, Session, CPU, RAM (GB), ID, State, Idle, Logon

### Page Behavior

- Refresh is cycle-based, not fixed interval: the page schedules next refresh using `NextCycleDelaySeconds` from `/api/data`
- The current snapshot renders first; persisted trend history is loaded in the background from `/api/server-history`
- Session CPU/RAM values are enriched with `/api/server-session-metrics` payload for better per-session accuracy
- Host metadata is fetched on-demand with `/api/server-host-info` only when the server detail page is opened
- `Check last RDP logins` button opens `/server-rdp-logins?name=<serverShortOrFqdn>` on demand
- If session is unauthorized/expired, page APIs return `401` and browser redirects to `/login`

## Server RDP Login Page

The RDP login audit page is available at:

- `GET /server-rdp-logins?name=<serverShortOrFqdn>`

### What it Shows

- Last successful RDP login entries for the selected server (username, login time, source IP)
- `Oldest Security Event Found` value (`yyyy.MM.dd`) from that server
- Read warnings when the remote Security log cannot be fully accessed

### Page Behavior

- No graphs are rendered on this page (table-only view)
- The page first loads `Oldest Security Event Found`, then starts full event loading
- A visual progress bar and percentage indicate loading progress while logs are being queried
- Data is queried on demand from the remote server Security log when the page is opened
- If session is unauthorized/expired, the API returns `401` and browser redirects to `/login`

### Session Actions From Detail Page

- `disconnect` (for active sessions)
- `logoff` (for disconnected sessions)
- `sendmsg` (prompted message text)

All actions call `POST /api/session-action` and are written to the audit log with actor, server, session id, username, and session name.

## Farm Overview Page

The farm page is available at:

- `GET /farm`

### What it Shows

- Aggregate cards: servers, total sessions, average sessions/server, active, disconnected, average CPU, average RAM, last update (Europe/Rome)
- Live trend graphs: farm average CPU, farm average RAM, average sessions/server
- Persisted trend section for the same 3 metrics with range selector buttons: Today, Yesterday, Select Day, This Week, Last Week, This Month, Last Month
- A label near the range selector shows the oldest available collected date, resolved from current SQLite/cache data
- Horizontal time labels on each graph (left/right boundary timestamps, Europe/Rome)

### Page Behavior

- Uses cycle-based refresh via `NextCycleDelaySeconds` from `/api/data`
- The current snapshot renders first; persisted farm trends are loaded in the background from `/api/farm-history`

## Settings Page

The authenticated `GET /settings` page displays the local configuration as read-only text. See [CONFIG.md](CONFIG.md#settings-page-and-api) for the settings API, editor integration, and deprecated write endpoints.

## Persisted Trend History

- Storage backend: local SQLite DB `webapp/runtime/farm_metrics.sqlite`
- Writer timing: one insert per processed snapshot (collector only; server is read-only for SQLite)
- Farm metrics stored in `farm_metrics`: timestamp, average CPU, average RAM, average sessions/server, server count, total sessions
- Per-server metrics stored in `server_metrics`: timestamp, server short name, CPU, RAM
- Live snapshot stored in `snapshot_state`: single row (`id=1`) with `ts_utc` and `payload_json`
- SQLite retention: farm metrics are retained for 70 days; per-server metrics are retained for 2 hours
- SQLite locking hardening: collector enables WAL mode and busy-timeout handling, and retries transient `database is locked` writes
- API behavior: `/api/data` is the fast snapshot endpoint, `/api/farm-history` exposes farm trend history, and `/api/server-history` exposes the 2-hour per-server history window
- Failure behavior: collector startup is fail-fast if `sqlite3.exe` is missing or SQLite initialization fails

## Audit Log Retention and Cleanup

Audit logs are automatically cleaned at each service startup:

- **Default retention**: 100 days
- **Trigger**: Runs once per service start
- **Action**: Removes all audit log entries with timestamps older than (today - 100 days)
- **Logging**: Cleanup count is written in the `service_start` audit entry details (no separate `cleanup_event` row)
- **Format**: Pipe-delimited entries are preserved; header row (column names) always retained
- **Fail-safe**: Lines with unparseable timestamps are kept to prevent data loss from corruption

This ensures the audit log remains performant and doesn't grow indefinitely while maintaining a full operational history within the retention window.

## Collector Timing Semantics

Collector loop behavior:

1. Start collection cycle
2. Query all monitored servers in parallel runspace-pool workers
3. Wait until all complete or timeout threshold is reached
4. Persist snapshot + metrics to SQLite (`snapshot_state`, `farm_metrics`, `farm_metrics_by_farm`, `server_metrics`)
5. Sleep for `CycleDelaySeconds`
6. Start next cycle

This means polling follows cycle completion, not fixed wall-clock cadence.

Additional collector resilience notes:

- If RAM probe fails for a server in a cycle, CPU and `quser` probes for that server are skipped to preserve time budget for other servers
- SQLite writes are wrapped in a single `BEGIN IMMEDIATE ... COMMIT` transaction per cycle
- SQLite lock retries are counted and emitted in periodic `PERF` lines (`sqliteRetries`, `retryRate`, `sqliteLockErrors`)

## Request Handling and Locks

- HTTP accept loop uses asynchronous `BeginGetContext`/`EndGetContext` polling instead of blocking `GetContext()`
- Session mutations are synchronized with monitor lock (`$script:sessionsLock`)
- In-memory farm/server history updates are synchronized with monitor lock (`$script:historyLock`)
- Snapshot cache updates/reads are synchronized with monitor lock (`$script:snapshotCacheLock`)

## Scheduled Midnight Collector Restart

The watchdog loop in `server.ps1` automatically restarts the collector process once per calendar day, shortly after midnight, to reclaim memory that accumulates in the long-running PowerShell collector process.

- Fires on the first watchdog tick (every 30 s) after midnight crosses a new calendar date
- Uses the same `Restart-CollectorJob` path as all other restarts (cooldown bypass, audit log, restart metrics)
- Logged in `server.log` as `Midnight collector restart: recycling collector to reclaim memory.`
- Does not affect the `Restart Requests 1h` restart-warning counter



## Authentication Behavior

- Login page at `/login`
- Credentials validated against AD using `PrincipalContext.ValidateCredentials`
- Session cookie name: `RDSAUTH`
- Session timeout extends on activity
- The first server startup creates the local `RDS-Dashboard-Admins` access group; see [CONFIG.md](CONFIG.md#dashboard-access-group) and [INSTALL.md](INSTALL.md#first-time-setup) for membership configuration.
- See [CONFIG.md](CONFIG.md#ad-and-service-account-configuration) for `CustomLoginDomain` and AD service-account configuration.
- Unauthorized requests:
  - Browser routes redirect to `/login`
  - API routes return `401`

## Firewall and Trust

### Inbound Rules (Admin → Dashboard Server)

- **TCP 443** from allowed admin networks (HTTPS web interface)

### Outbound Rules (Dashboard Server → RDS Servers)

Session management actions (`disconnect`, `logoff`, `sendmsg`) use native Windows RDS commands that communicate via RPC:

- **TCP 135** – RPC Endpoint Mapper (required for service discovery by `logoff`, `tsdiscon`, `msg`)
- **TCP 445** – SMB (optional, may be used by `msg` for session messaging)
- **TCP 49152-65535** – Dynamic RPC ports (assigned after negotiation on port 135)

These outbound rules must allow traffic from the dashboard server to **all configured RDS servers** in `config.toml`.

### Certificate Trust

- See [CONFIG.md](CONFIG.md#https-certificate-configuration) for certificate selection, binding, and client trust guidance.

## gMSA Notes

See [CONFIG.md](CONFIG.md#ad-and-service-account-configuration) for gMSA installation, validation, service parameters, and URL ACL identity requirements.

## Troubleshooting

- Service fails to start (or pauses immediately after start):
  1. **Check NSSM configuration and script path** — verify `AppParameters` contains quoted paths if the install folder has spaces:
     ```powershell
     nssm status RDSDashboardWeb
     nssm get RDSDashboardWeb Application
     nssm get RDSDashboardWeb AppParameters
     ```
     The `-File` path must be quoted (e.g. `-File "C:\Program Files\...\server.ps1"`). If it is not, reinstall the service using the updated `install_service.ps1`.
  2. **Run the PowerShell command directly** (bypasses NSSM entirely — confirms whether the script itself starts correctly):
     ```powershell
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\RDS_dashboard\webapp\server.ps1" -Port 443 -BindHost +
     ```
     Replace the path with your actual install folder. If this succeeds but the service does not, the problem is in the NSSM registration (path quoting, working directory, or identity). If this also fails, the problem is in the script or environment.
  3. **Check service logs immediately after the pause:**
     ```powershell
     Get-Content webapp\logs\server.log -Tail 50
     Get-Content webapp\logs\collector.log -Tail 20
     ```
  4. **Verify `sqlite3.exe` is present** — collector startup is fail-fast if missing:
     ```powershell
     Test-Path webapp\sqlite3.exe
     ```
  5. **Validate HTTPS binding and certificate:**
     ```powershell
     netsh http show sslcert
     netsh http show urlacl
     # Cert must exist with the configured friendly name (default: tsfarm)
     Get-ChildItem Cert:\LocalMachine\My | Where-Object FriendlyName -eq "tsfarm"
     ```
  6. **Run the server in foreground via `run_webapp.cmd`** (most revealing — prints the exact error to the console):
     ```cmd
     cd webapp
     .\server.ps1 -Port 443 -BindHost +
     ```
  7. **If using a service account or gMSA**, verify the URL ACL identity matches the service identity:
     ```powershell
     netsh http show urlacl | Select-String "443"
     ```
  - Validate that a cert exists with friendly name configured in `-HttpsCertFriendlyName` (default `tsfarm`)
  - Confirm account rights and script path
- Login always fails:
  - Verify domain join and domain controller reachability
  - Test credentials format (`user`, `DOMAIN\user`, `user@domain`)
- No data or partial data:
  - Check permissions for `quser` and CIM on target RDS hosts
  - Check network and name resolution to monitored FQDNs
  - Confirm the configured servers in `config.toml` are valid FQDNs reachable from the collector host
  - For missing farm history graphs, verify `sqlite3.exe` is present and check `server.log` and `collector.log` for SQLite init/write errors
- Actions fail:
  - Confirm session id is valid
  - Confirm operator/service identity has rights on remote hosts

## Security Notes

- Keep access limited to internal admin network/VPN
- Prefer dedicated low-privilege service account with only required permissions
- Consider adding AD group allowlist checks before production rollout
