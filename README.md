# Dynatrace Monaco and Jenkins POC

This repository manages a Dynatrace Platform dashboard and Davis anomaly alerts
as code. Jenkins watches the `main` branch, validates each change with Monaco,
and deploys it to `https://ann36102.apps.dynatrace.com`.

## Managed configuration

- Kafka REDS dashboard with six custom rate and efficiency metrics.
- Consumer throughput alert below 1000 records/sec for five minutes.
- Replication efficiency alert below 80 percent for five minutes.
- Jenkins pipeline provisioned automatically as `monaco-dynatrace-deploy`.
- GitHub push trigger plus two-minute SCM polling fallback.

## Prerequisites

1. Start Docker Desktop and enable WSL integration for this distribution.
2. Create a Dynatrace access token with `DataExport`, `settings.read`, and
   `settings.write` for environment Settings resources.
3. Create a Dynatrace OAuth client with `app-engine:apps:run`,
   `document:documents:read`, `document:documents:write`,
   `settings:objects:read`, `settings:objects:write`, and
   `settings:schemas:read`.
4. Use a GitHub personal access token or authenticated GitHub CLI for pushes.
   GitHub account passwords cannot be used for Git operations over HTTPS.

Dynatrace web usernames and passwords are not accepted by Monaco. The access
token and OAuth client authenticate different APIs and both are required here.

## Start the POC

```bash
cp .env.example .env
```

Edit `.env` and replace the access token and OAuth client placeholders. The file
is ignored by Git. The Dynatrace account URN is not required by Monaco.
Then start Jenkins:

```bash
docker compose up -d --build jenkins
```

If Jenkins reports Docker socket permission errors, discover the socket group
as Docker containers see it and set `DOCKER_GID` to the returned number:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine:3.22 \
  stat -c '%g' /var/run/docker.sock
docker compose up -d --force-recreate jenkins
```

Open <http://localhost:8081> and sign in with `admin` / `admin`, as requested
for this local POC. Change `JENKINS_ADMIN_PASSWORD` in `.env` before exposing
Jenkins beyond localhost.

The job is created automatically. Run `monaco-dynatrace-deploy` once to verify
the token and deploy the initial dashboard and alerts.

## Validate or deploy directly

```bash
docker compose build monaco
docker compose run --rm monaco deploy --dry-run manifest.yaml
docker compose run --rm monaco deploy manifest.yaml
```

## Continuous deployment

The Jenkins job checks the public GitHub repository every two minutes, so no
inbound connection to a local Docker Desktop instance is required. For faster
triggers, expose Jenkins through a secured public endpoint and add this webhook
in GitHub repository settings:

```text
https://YOUR-JENKINS-HOST/github-webhook/
```

Choose content type `application/json` and the push event. Never expose this POC
with the default Jenkins password.

To change Dynatrace, edit the files under
`projects/kafka-reds-observability`, commit, and push to `main`. A failed Monaco
dry run stops the deployment stage.

## Repository initialization

```bash
git init
git add .
git commit -m "Add Dynatrace Monaco Jenkins POC"
git branch -M main
git remote add origin https://github.com/frootima/monaco.git
git push -u origin main
```
# monaco
