# RDS Dashboard Installation

## Before You Begin

Run all commands in an elevated PowerShell session from the application folder:

```powershell
Set-Location .\webapp
```

For configuration details, see [CONFIG.md](CONFIG.md). For authentication behavior, API reference, and firewall requirements, see [README.md](README.md).

## Prerequisites

- Windows Server with PowerShell 5.1+
- Server joined to an AD domain
- NSSM available offline (`nssm.exe` in `webapp` or supplied through `-NssmPath`)
- `sqlite3.exe` available offline (in `webapp` or in `PATH`); collector startup requires it
- Network access from the dashboard server to monitored RDS servers:
  - TCP 135 (RPC Endpoint Mapper for session management)
  - TCP 445 (SMB, optional for `msg`)
  - TCP 49152-65535 (Dynamic RPC ports)
  - Permission for `quser` and `Get-CimInstance` calls
- Account running the app has rights for:
  - `quser /server:<fqdn>`
  - `Get-CimInstance` (Win32_Processor, Win32_OperatingSystem) on monitored servers
  - `Get-WinEvent -ComputerName <server> -LogName Security` for on-demand RDP login audit
  - `logoff`, `tsdiscon`, and `msg` on target session hosts
- Local administrator rights to run certificate setup and service installation scripts

## Offline Constraint

No external PowerShell module download is required. The application uses built-in PowerShell and .NET assemblies.

## Getting NSSM (Offline)

Download NSSM on an internet-connected workstation, then copy it to the server.

1. Official download page: https://nssm.cc/download
2. Extract the archive and choose the binary by architecture:
   - `win64\nssm.exe` for 64-bit Windows Server
   - `win32\nssm.exe` only for 32-bit systems
3. Copy `nssm.exe` to the `webapp` folder or another approved tools path.
4. Verify it on the server:

```powershell
.\nssm.exe version
```

If internet downloads are blocked, request an internally mirrored or approved NSSM package and pass its path with `-NssmPath`.

## Getting SQLite (Offline)

Download SQLite on an internet-connected workstation, then copy it to the server.

1. Official download page: https://www.sqlite.org/download.html
2. Download the current Windows 64-bit tools archive (`sqlite-tools-win-x64-*.zip`).
3. Extract the archive and copy `sqlite3.exe` to the `webapp` folder or another approved tools path in `PATH`.
4. Verify it on the server:

```powershell
.\sqlite3.exe --version
```

If internet downloads are blocked, request an internally mirrored or approved SQLite package. The collector requires `sqlite3.exe` at startup.

## First-Time Setup

1. Create the local configuration, then edit it with the dashboard title, farms, server FQDNs, and optional login domain. See [CONFIG.md](CONFIG.md#local-configuration-file) for field details:

```powershell
Copy-Item .\config-example.toml .\config.toml
notepad .\config.toml
```

2. Create and bind an HTTPS certificate on port 443. See [CONFIG.md](CONFIG.md#https-certificate-configuration) for certificate options:

```powershell
.\setup_https_443.ps1 -DnsName "your-server-fqdn"
```

To use an existing certificate by friendly name:

```powershell
.\setup_https_443.ps1 -PreferredCertFriendlyName "tsfarm"
```

If using a gMSA, grant the URL ACL to that identity during setup:

```powershell
.\setup_https_443.ps1 -DnsName "your-server-fqdn" -UrlAclUser "DOMAIN\gmsa-rds-dashboard$"
```

3. Install the service as LocalSystem. See [CONFIG.md](CONFIG.md#ad-and-service-account-configuration) for service-account and gMSA options:

```powershell
.\install_service.ps1 -NssmPath .\nssm.exe
```

Or install with a dedicated service account:

```powershell
$svcPwd = Read-Host "Service account password" -AsSecureString
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "DOMAIN\svc-rds-dashboard" -ServicePassword $svcPwd
```

Or install with a gMSA:

```powershell
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "DOMAIN\gmsa-rds-dashboard$" -UseGmsa
```

To enforce a certificate at service startup, add `-HttpsCertFriendlyName "tsfarm"` to the install command.

4. Start the service:

```powershell
sc.exe start RDSDashboardWeb
```

The first server startup creates the local `RDS-Dashboard-Admins` group. Add an authorized AD user or group before signing in:

```powershell
Add-LocalGroupMember -Group 'RDS-Dashboard-Admins' -Member 'DOMAIN\authorized-group'
```

Replace `DOMAIN\authorized-group` with the AD user or group authorized to access the dashboard. Domain Admins and local `Administrators` members must also be added to `RDS-Dashboard-Admins` unless their membership is provided through a nested group. See [CONFIG.md](CONFIG.md#dashboard-access-group) for access behavior.

5. Open the dashboard:

```text
https://your-server-fqdn/
```

## Manual Foreground Run

```cmd
run_webapp.cmd
```

Or:

```powershell
.\server.ps1 -Port 443 -BindHost +
```
## Full install_service.ps1 parameters

`webapp/install_service.ps1` parameters:

- `-ServiceName`: default `RDSDashboardWeb`.
- `-DisplayName`: default `RDS Dashboard Web App`.
- `-Description`: service description.
- `-StartupType`: default `auto`.
- `-HttpsCertFriendlyName`: optional certificate friendly name to enforce at service startup.
- `-ServiceUser`: optional domain or service account.
- `-ServicePassword`: required `SecureString` when `ServiceUser` is set and `-UseGmsa` is not used.
- `-UseGmsa`: use with a gMSA account ending in `$`.
- `-NssmPath`: optional path to `nssm.exe`.

For a gMSA, install and verify it on the web server before service installation:

```powershell
Install-ADServiceAccount gmsa-rds-dashboard
Test-ADServiceAccount gmsa-rds-dashboard
```

`Test-ADServiceAccount` must return `True`. Use `DOMAIN\gmsa-rds-dashboard$` for `-ServiceUser`, do not pass `-ServicePassword`, and ensure the URL ACL identity set with `-UrlAclUser` matches the service identity.

## Validation Scripts

Run the pre-publish scan before committing or publishing. It exits with a non-zero code when it finds likely secrets or internal identifiers:

```powershell
.\PrePublish-Scan.ps1
```

Run farm validation after deployment. It prompts for dashboard credentials and delegates to endpoint checks; pass a configured server for persisted server-history validation:

```powershell
.\test-farm.ps1 -BaseUrl "https://your-server-fqdn" -HistoryServerName "rds-a01.example.local"
```

Run endpoint checks directly when credentials or a session token must be supplied explicitly. It verifies authenticated routes, API responses, and optional SQLite/history checks:

```powershell
.\Test-HealthEndpoints.ps1 -BaseUrl "https://your-server-fqdn" -Credential (Get-Credential) -HistoryServerName "rds-a01.example.local"
```
