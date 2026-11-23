# GamePort Telemetry Worker (Free Cloudflare Tier)

Zero-PII Cloudflare Worker + D1 SQLite backend for GamePort's anonymous compatibility reports.
Stores no IP addresses, usernames, or Steam IDs.

## Deploy in 4 commands (free Cloudflare account)

```sh
cd Tools/telemetry-worker
npx wrangler login
npx wrangler d1 create gameport-telemetry
# Paste the printed database_id into wrangler.toml, then:
npx wrangler d1 execute gameport-telemetry --remote --file=schema.sql
npx wrangler deploy
```

Then paste your deployed `https://gameport-telemetry.<subdomain>.workers.dev/v1/report` URL into
`Brand.telemetryEndpoint` in `Sources/GamePortKit/Brand.swift`.

### Upgrading an existing deployment

Reports now say how the game was started (`launchMethod`: `windowsSteam`, `bridge` or `lab`).
Migrate the database first, then deploy the new worker:

```sh
npx wrangler d1 execute gameport-telemetry --remote --file=migrations/0002_launch_method.sql
npx wrangler deploy
```

Until then the old worker keeps accepting reports and ignores the new field.

Read aggregated community results anytime at:
`GET https://gameport-telemetry.<subdomain>.workers.dev/v1/verdicts.json`
