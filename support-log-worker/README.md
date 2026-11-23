# Support log service

This Worker accepts user feedback from the macOS and Windows apps, optionally stores privacy-redacted diagnostic logs, and returns a short tracking code plus a private tracking token. Reports are stored in Workers KV for 30 days. `/admin` is protected by HTTP Basic authentication using the `ADMIN_TOKEN` secret.

Deployment:

1. Run `wrangler login` in an interactive terminal.
2. From this directory, run `npm install` and `npm run types`.
3. Set the admin password with `wrangler secret put ADMIN_TOKEN` (enter a long random value at the prompt).
4. Run `npm run deploy`.
5. The production endpoint is `https://interview-assistant-log-upload.zhaopeiyu1507288.workers.dev`; keep the centralized endpoints in `SupportLogUploader.swift` and `SupportLogUploader.cs` in sync if it changes.

Open `https://<worker-url>/admin`; the browser asks for a username and password. The username can be anything and the password is `ADMIN_TOKEN`. The dashboard lists real submissions and supports issue/log search, status filtering, detail inspection, log copy/download, CSV export, and status updates.

Public app API:

- `POST /v1/feedback` creates feedback with optional logs.
- `GET /v1/feedback/:code` requires `X-Feedback-Token` and returns the current status.
- `POST /v1/logs` remains available for older app builds.

Admin API:

- `GET /admin/logs` lists/searches reports.
- `GET /admin/logs/:code` returns full details.
- `PATCH /admin/logs/:code` updates `new`, `review`, or `resolved` status.
