# nutanix-rx

Cluster Manager and admin reservation UI for Nutanix lab operations.

## What this project does

- Provides a web UI to run startup/shutdown automation.
- Exposes granular control actions for cluster components.
- Supports extended uptime reservations from `/cm/admin`.
- Includes recovery helpers (pod refresh and NAI token update).

## Requirements

- Docker and Docker Compose
- Access to the host/environment where scripts can run
- Valid `.env` values for your environment

## Local run (recommended via compose stack)

Create your local environment file first:

```bash
cp .env.example .env
```

Then edit `.env` with real credentials, endpoints, and IPs for your lab.

From your `plex-docker` root:

```bash
docker compose up -d --build ntnx-cm
```

App should be available on:

- `http://localhost:5005`

## Rebuild after UI/code changes

```bash
docker compose up -d --build ntnx-cm
```

## Common operations

- Main dashboard: `/cm/`
- Reservations admin: `/cm/admin`
- Logs are shown in the Live Logs panel in the UI

## Notes

- Do not commit secrets. `.env` is intentionally ignored.
- Reservation and automation state files are environment-specific.
