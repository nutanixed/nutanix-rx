# nutanix-rx

Cluster Manager web app and automation toolkit for Nutanix lab operations.

This service provides:

- cluster startup/shutdown orchestration from a web UI
- granular component-level power/control actions
- reservation-based extended uptime management (`/cm/admin`)
- recovery tools (pod refresh and NAI token update)

## Deployment runbook

## 1) Prerequisites

- Linux host with network access to your Nutanix environment
- Docker Engine + Docker Compose plugin
- Access to required endpoints (PE/PC/CVM/PCVM/FSVM/CIMC/LDAP as applicable)
- Correct credentials and topology values for your lab

Verify Docker:

```bash
docker --version
docker compose version
```

## 2) Project layout

This repository is designed to run as an `ntnx-cm` service inside your existing Docker Compose stack.

Typical layout:

- `<stack-root>/docker-compose.yml`
- `<stack-root>/ntnx-cm/` (this repo)

## 3) Environment configuration

From this repository directory:

```bash
cp .env.example .env
```

Edit `.env` and set all required values for your environment:

- connectivity (`PE_IP`, `PC_IP`, `CONSOLE_BASE_URL`)
- credentials (API/SSH/LDAP/CIMC/local auth)
- topology lists (`AHV_IPS`, `CVM_IPS`, `PCVM_IPS`, `FSVM_IPS`, etc.)
- automation timing and behavior values
- Flask/session settings
- optional integrations (Slack webhook, logout redirect)

`MGMT_VM_NAMES` supports a comma-separated mix of selectors:
- entries ending with `_` are prefix matches (example: `system_` matches all VMs whose names start with `system_`)
- entries not ending with `_` are exact VM names (example: `auto_DND_calm_policy_engine_1f4dfdb8`)

Do **not** commit `.env`.

## 4) Build and deploy

From your Compose stack root (where `docker-compose.yml` lives):

```bash
docker compose up -d --build ntnx-cm
```

Check status:

```bash
docker compose ps ntnx-cm
```

## 5) Access and first validation

- App root: `http://<host>:5005/` (or proxied `/cm/`)
- Admin reservations: `http://<host>:5005/admin` (or proxied `/cm/admin`)

Smoke test checklist:

- dashboard loads without JS errors
- Live Logs panel updates and scrolls
- Help and Console modals open/close correctly
- admin page loads reservations list
- booking modal opens, validates, and saves reservation

Container logs:

```bash
docker compose logs -f ntnx-cm
```

## 6) Reverse proxy notes

If exposing behind a reverse proxy under `/cm`:

- route `/cm/*` to service port `5005`
- preserve headers (`X-Forwarded-*`) as needed
- keep session cookie settings in `.env` aligned with HTTPS deployment:
  - `SESSION_COOKIE_SECURE=true`
  - `SESSION_COOKIE_PATH=/`

## 7) Update procedure

From this repository:

```bash
git pull
```

From your Compose stack root:

```bash
docker compose up -d --build ntnx-cm
```

Re-run smoke tests after each update.

## 8) Rollback procedure

Options:

- redeploy prior git commit in `ntnx-cm` and rebuild
- or restore from your backup/snapshot process and rebuild

After rollback:

```bash
docker compose up -d --build ntnx-cm
docker compose ps ntnx-cm
```

## 9) Troubleshooting

- **UI loads but actions fail:** verify `.env` credentials and endpoint reachability.
- **Automation buttons disabled unexpectedly:** check active reservation state and pause flags.
- **Login issues:** verify LDAP/local auth settings and `SECRET_KEY`.
- **No logs in UI:** inspect browser console + container logs.
- **Script failures:** run script manually in container to isolate env/input issues.

Useful check:

```bash
docker compose exec ntnx-cm bash
```

## Security reminders

- Never commit secrets (`.env`, tokens, private credentials).
- Rotate any credential/token that was ever shared in plaintext.
