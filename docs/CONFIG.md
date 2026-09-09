# RDS Dashboard Configuration

This guide describes deployment configuration. For installation commands, see [INSTALL.md](INSTALL.md). For authentication behavior, API reference, and firewall requirements, see [API.md](API.md).

## Local Configuration File

`webapp/config-example.toml` is the tracked generic template. Copy it to `webapp/config.toml` before first run and configure the local file for the deployment. `config.toml` is intentionally ignored by Git because it contains site-specific farm, server, and optional login-domain settings.

```powershell
Set-Location .\webapp
Copy-Item .\config-example.toml .\config.toml
notepad .\config.toml
```

### TOML Fields

- `Title`: dashboard title shown in the UI.
- `CollectorTimeoutSeconds`: global deadline for one full collection cycle, in seconds.
- `CycleDelaySeconds`: sleep between successive collection cycles, in seconds.
- `CollectorDebugMode`: set to `true` for per-cycle diagnostics in `collector.log`, including probe timings, errors, and timed-out servers. Default: `false`.
- `CustomLoginDomain`: optional Windows domain for user authentication and AD user search. When set, unqualified credentials are validated against this domain instead of the server's domain. Default: empty.
- `Farms`: named farm map; each farm contains its active server list.
- `PendingServers`: named farm map; each farm contains pending or unreachable servers.

Example:

```toml
Title = "RDS Dashboard"
CollectorTimeoutSeconds = 60
CycleDelaySeconds = 20
CollectorDebugMode = false

# CustomLoginDomain = "users.example.local"

[Farms]
First = ["srv-a.domain.local", "srv-b.domain.local"]
Second = ["srv-c.domain.local", "srv-d.domain.local"]

[PendingServers]
First = []
Second = []
```

## Server and Collector Parameters

### webapp/server.ps1

- `-Port`: default `443`.
- `-BindHost`: default `+`.
- `-HttpsCertFriendlyName`: optional certificate friendly name in `Cert:\LocalMachine\My` to enforce at startup.
- `-RuntimeDir`: default `webapp\runtime`.
- `-DataFile`: legacy alias; if it is a file path, its parent folder becomes the runtime directory.
- `-CollectorTimeoutSeconds`: default `15`.
- `-CycleDelaySeconds`: default `15`.
- `-SessionTimeoutMinutes`: default `720`.
- `-DefaultDomain`: defaults to the server's AD-domain environment information.
- `-ConfigFile`: default `webapp\config.toml`.

### webapp/collector.ps1

- `-RuntimeDir`: required.
- `-OutputPath`: legacy alias retained for backward compatibility.
- `-CollectorTimeoutSeconds`: default `15` when run directly.
- `-CycleDelaySeconds`: default `10`.
- `-ConfigFile`: default `webapp\config.toml`.
- Performance counters are logged every 20 cycles in `collector.log`.

The TOML `CollectorTimeoutSeconds` and `CycleDelaySeconds` values override the corresponding runtime defaults when configured.

## HTTPS Certificate Configuration

`webapp/setup_https_443.ps1` creates or selects a certificate and configures the HTTPS binding and URL ACL.

- `-DnsName`: defaults to the server hostname.
- `-Port`: default `443`.
- `-AppId`: fixed application GUID for the SSL binding.
- `-UrlAclUser`: default `NT AUTHORITY\SYSTEM`.
- `-PreferredCertFriendlyName`: optional existing certificate to bind instead of creating or reusing one by DNS name.

A self-signed certificate causes browser trust warnings until client machines trust it. Use an internal PKI or GPO trust deployment where available. See [INSTALL.md](INSTALL.md#first-time-setup) for certificate setup commands.

## AD and Service Account Configuration

The dashboard server must be joined to an AD domain. Authentication and session management use Active Directory.

`CustomLoginDomain` supports an environment where dashboard users belong to a different AD domain than RDS servers. Credentials with explicit `DOMAIN\user` or `user@domain` prefixes use the specified domain.

### Dashboard Access Group

At first server startup, the application creates the local `RDS-Dashboard-Admins` group when it is missing, with the description `Users authorized to login on RDS-Dashboard web app`. Startup fails if the group cannot be created. Add authorized AD users or groups after it exists. A successful AD sign-in is allowed only when the user is a direct or nested member of this local group; all other users receive an access-denied response. Domain Admins and members of the server's local `Administrators` group do not bypass this requirement unless they are also members, directly or through a nested group, of `RDS-Dashboard-Admins`. This group grants dashboard access only. The `/settings` page additionally requires membership in the server's local `Administrators` group.



## Settings Page and API

The authenticated settings page is available at `GET /settings`. It displays the current local `config.toml` as read-only text, its resolved path, and an editor link.

`GET /api/settings` returns configuration metadata:

- `ConfigPath`
- `ConfigText`
- `ConfigReadError`, empty when the configuration is read successfully

Configuration write endpoints are deprecated and return `410 Gone`:

- `POST /api/settings/add-server`
- `POST /api/settings/remove-server`
- `POST /api/settings/recheck-pending`
- `POST /api/settings/activate-pending`

## Logo and Favicon Customization

The UI loads `/logo.png`, which serves `webapp/logo-company.png` when that optional local file is present; otherwise it serves the tracked `webapp/logo-generic.png`. If neither file exists, the UI displays its built-in text fallback. Keep company branding in `logo-company.png`, which is excluded from Git, and retain `logo-generic.png` for public releases.

Browsers load `/favicon.ico`, which serves the optional local `webapp/favicon-company.ico` when present; otherwise it serves the tracked `webapp/favicon-generic.ico`. Keep company branding in `favicon-company.ico`, which is excluded from Git, and retain `favicon-generic.ico` for public releases.

## Configuration

Configure the local TOML file, script parameters, HTTPS certificate, and AD service identity as described in [CONFIG.md](CONFIG.md).

## Configuration Troubleshooting

- If the service cannot start, confirm `webapp/config.toml` was copied from `config-example.toml`, contains reachable server FQDNs, and is readable by the service identity.
- Verify the certificate binding with `netsh http show sslcert` and URL ACLs with `netsh http show urlacl`.
- Confirm a configured `-HttpsCertFriendlyName` matches a certificate with a private key in `Cert:\LocalMachine\My`.
- With a service account or gMSA, ensure the URL ACL identity matches the service identity.
- For missing data, check configured server reachability and the dashboard identity's `quser`, CIM, event-log, and session-action permissions.
