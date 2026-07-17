# Dynatrace Monaco Production Deployment Runbook

This runbook describes how to deploy Dynatrace dashboards and alert
configuration from Bitbucket through Jenkins using the official Dynatrace
Monaco CLI.

## Target flow

```text
Bitbucket change
    -> pull request review
    -> Jenkins checkout
    -> build pinned Monaco Docker image
    -> render template.json with env.json
    -> generate dashboard.json
    -> Monaco dry-run validation
    -> production approval
    -> Monaco deployment
    -> Dynatrace dashboard updated
```

For production, use two Jenkins jobs when possible:

1. `monaco-validate` runs for pull requests and performs rendering plus a
   Monaco dry-run.
2. `monaco-prod-deploy` runs after a merge to protected `main` and requires
   approval before deployment.

## 1. Verify the Dynatrace environment type

This implementation uses modern Dynatrace Platform dashboards and expects a
Platform URL in this format:

```text
https://<environment-id>.apps.dynatrace.com
```

It publishes dashboards through the Documents API. Confirm that the production
environment supports this endpoint:

```text
https://<environment-id>.apps.dynatrace.com/platform/document/v1/documents
```

If the production server is Dynatrace Managed or on-premises and has no
Dynatrace Platform URL, confirm Documents API support with Dynatrace before
using this implementation. A server that only supports Classic dashboards
requires a different Monaco configuration type and API.

## 2. Create Dynatrace credentials

Use a dedicated service user owned by the operations team. Do not use a
personal employee account.

### Environment API token

Create an environment API token with the permissions required by the resources
managed by the repository. Dashboard plus Settings 2.0 alert deployments
normally need:

```text
DataExport
ReadConfig
WriteConfig
settings.read
settings.write
```

### OAuth client

In Dynatrace Account Management, go to:

```text
Identity & access management -> OAuth clients -> Create client
```

Use these scopes for dashboard documents and Settings 2.0 resources:

```text
app-engine:apps:run
settings:objects:read
settings:objects:write
settings:schemas:read
document:documents:read
document:documents:write
```

Add these scopes only if the deployment process is allowed to delete documents:

```text
document:documents:delete
document:trash.documents:delete
```

The service user's IAM group policies must grant the same access. Record the
client ID and secret when the client is created because the secret cannot be
displayed again.

Official reference:

<https://docs.dynatrace.com/docs/deliver/configuration-as-code/monaco/guides/create-oauth-client>

Never commit the API token, OAuth client ID, or OAuth client secret to
Bitbucket.

## 3. Add Jenkins credentials

In Jenkins, open:

```text
Manage Jenkins -> Credentials -> System -> Global credentials
```

Create the following Secret Text credentials:

| Jenkins credential ID | Value |
| --- | --- |
| `dynatrace-prod-api-token` | Dynatrace environment API token |
| `dynatrace-prod-oauth-client-id` | Dynatrace OAuth client ID |
| `dynatrace-prod-oauth-client-secret` | Dynatrace OAuth client secret |

Create a separate Bitbucket checkout credential:

```text
ID: bitbucket-monaco-read
Type: SSH private key or username/access token
Repository permission: read only
```

Prefer an SSH deploy key or repository access token over a personal password.

Jenkins credentials reference:

<https://www.jenkins.io/doc/book/pipeline/jenkinsfile/#handling-credentials>

## 4. Prepare the Bitbucket repository

Use this repository structure:

```text
monaco/
|-- .dockerignore
|-- .gitignore
|-- Dockerfile.monaco
|-- Jenkinsfile
|-- manifest.yaml
|-- scripts/
|   `-- render-dashboard.sh
`-- projects/
    `-- production-observability/
        |-- dashboard/
        |   |-- config.yaml
        |   |-- env.json
        |   `-- template.json
        `-- alerts/
            |-- config.yaml
            |-- alert-one.json
            `-- alert-two.json
```

The generated `dashboard.json` is build output and must not be committed.

Add these entries to `.gitignore`:

```gitignore
.env
.logs/
projects/production-observability/dashboard/dashboard.json
```

Add these entries to `.dockerignore`:

```dockerignore
.git
.env
.logs
```

## 5. Create env.json

`env.json` contains non-secret environment-specific dashboard values:

```json
{
  "dashboardVersion": 20,
  "consumerTitle": "Consumer Throughput Rate",
  "consumerAlias": "consumer_rate",
  "consumerMetric": "custom.kafka.consumer.throughput.rate",
  "producerTitle": "Producer Throughput Rate",
  "producerAlias": "producer_rate",
  "producerMetric": "custom.kafka.producer.throughput.rate",
  "maxResultRecords": 1000,
  "defaultScanLimitGbytes": 500,
  "enableSampling": false
}
```

Do not put API tokens, OAuth secrets, Bitbucket credentials, or Jenkins
passwords in this file.

For multiple Dynatrace environments, use files such as:

```text
env.dev.json
env.test.json
env.prod.json
```

The Jenkins job can pass the selected file to the renderer.

## 6. Create template.json

Placeholders in `template.json` must match keys in `env.json`:

```json
{
  "version": "{{dashboardVersion}}",
  "variables": [],
  "tiles": {
    "0": {
      "type": "data",
      "title": "{{consumerTitle}}",
      "query": "timeseries {{consumerAlias}} = avg({{consumerMetric}})",
      "visualization": "lineChart",
      "visualizationSettings": {},
      "querySettings": {
        "maxResultRecords": "{{maxResultRecords}}",
        "defaultScanLimitGbytes": "{{defaultScanLimitGbytes}}",
        "enableSampling": "{{enableSampling}}"
      }
    },
    "1": {
      "type": "data",
      "title": "{{producerTitle}}",
      "query": "timeseries {{producerAlias}} = avg({{producerMetric}})",
      "visualization": "lineChart",
      "visualizationSettings": {},
      "querySettings": {
        "maxResultRecords": "{{maxResultRecords}}",
        "defaultScanLimitGbytes": "{{defaultScanLimitGbytes}}",
        "enableSampling": "{{enableSampling}}"
      }
    }
  },
  "layouts": {
    "0": { "x": 0, "y": 0, "w": 12, "h": 6 },
    "1": { "x": 12, "y": 0, "w": 12, "h": 6 }
  },
  "settings": {}
}
```

Exact placeholders can be replaced by strings, numbers, Booleans, arrays, or
objects. Placeholders embedded inside larger strings are rendered as text.

## 7. Add the dashboard renderer

Create `scripts/render-dashboard.sh`:

```sh
#!/bin/sh
set -eu

dashboard_dir="${1:-projects/production-observability/dashboard}"
variables_file="${2:-${dashboard_dir}/env.json}"
template_file="${dashboard_dir}/template.json"
output_file="${dashboard_dir}/dashboard.json"
temporary_file="${output_file}.tmp.$$"

trap 'rm -f "$temporary_file"' EXIT

jq -e '
  type == "object"
  and (keys | all(test("^[A-Za-z][A-Za-z0-9_]*$")))
' "$variables_file" >/dev/null

jq --slurpfile variable_files "$variables_file" '
  ($variable_files[0]) as $variables
  | def render:
      if type == "object" then
        with_entries(.value |= render)
      elif type == "array" then
        map(render)
      elif type == "string" then
        . as $text
        | ($variables
          | to_entries
          | map(select($text == ("{{" + .key + "}}")))
          | first) as $exact
        | if $exact == null then
            reduce ($variables | to_entries[]) as $variable
              ($text;
                gsub("\\{\\{" + $variable.key + "\\}\\}";
                  ($variable.value | tostring)))
          else
            $exact.value
          end
      else
        .
      end;
    render
' "$template_file" > "$temporary_file"

if jq -e '.. | strings | select(test("\\{\\{[^{}]+\\}\\}"))' \
  "$temporary_file" >/dev/null; then
  echo "Unresolved dashboard template variable found." >&2
  exit 1
fi

jq -e . "$temporary_file" >/dev/null
mv "$temporary_file" "$output_file"
trap - EXIT

echo "Generated ${output_file}"
```

This script validates the variables file, renders values recursively, preserves
JSON types, fails on unresolved placeholders, validates the generated JSON, and
writes the output atomically.

## 8. Create the Monaco dashboard configuration

Create `projects/production-observability/dashboard/config.yaml`:

```yaml
configs:
  - id: kafka-reds-prod-dashboard
    type:
      document:
        kind: dashboard
        private: false
        id: kafka-reds-prod-dashboard
    config:
      name: Kafka REDS - Production Metrics
      template: dashboard.json
```

The explicit document ID provides a predictable dashboard URL:

```text
https://<environment-id>.apps.dynatrace.com/ui/apps/dynatrace.dashboards/dashboard/kafka-reds-prod-dashboard
```

Custom document IDs require Monaco 2.28.0 or newer. If no document ID is set,
Monaco generates one.

Official document type reference:

<https://docs.dynatrace.com/docs/deliver/configuration-as-code/monaco/configuration/yaml-configuration-saas-type-fields>

Keep the project name, configuration ID, and document ID stable. Changing them
can create another dashboard instead of updating the existing dashboard.

## 9. Create manifest.yaml

The manifest references environment variables instead of containing secrets:

```yaml
manifestVersion: "1.0"

projects:
  - name: production-observability
    path: projects/production-observability

environmentGroups:
  - name: production
    environments:
      - name: prod
        url:
          type: environment
          value: DT_ENV_URL
        auth:
          token:
            name: DT_API_TOKEN
          oAuth:
            clientId:
              name: DT_OAUTH_CLIENT_ID
            clientSecret:
              name: DT_OAUTH_CLIENT_SECRET
```

Official manifest and authentication reference:

<https://docs.dynatrace.com/docs/deliver/configuration-as-code/monaco/configuration/monaco-manage-resources>

## 10. Build a pinned Monaco image

Do not use an unpinned `latest` Monaco release in production. Test a specific
version in non-production and promote the same image to production.

Example `Dockerfile.monaco`:

```dockerfile
FROM alpine:3.22

ARG TARGETARCH
ARG MONACO_VERSION=2.28.12

RUN apk add --no-cache ca-certificates curl jq \
    && DETECTED_ARCH="${TARGETARCH:-$(uname -m)}" \
    && case "${DETECTED_ARCH}" in \
         amd64|x86_64) MONACO_ARCH="amd64" ;; \
         arm64|aarch64) MONACO_ARCH="arm64" ;; \
         386|i386|i686) MONACO_ARCH="386" ;; \
         *) echo "Unsupported architecture: ${DETECTED_ARCH}" >&2; exit 1 ;; \
       esac \
    && RELEASE_URL="https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/${MONACO_VERSION}" \
    && BINARY="monaco-linux-${MONACO_ARCH}" \
    && curl -fsSL "${RELEASE_URL}/${BINARY}" -o "/tmp/${BINARY}" \
    && curl -fsSL "${RELEASE_URL}/${BINARY}.sha256" -o /tmp/monaco.sha256 \
    && cd /tmp \
    && sha256sum -c monaco.sha256 \
    && install -m 0755 "/tmp/${BINARY}" /usr/local/bin/monaco \
    && rm -f "/tmp/${BINARY}" /tmp/monaco.sha256

WORKDIR /workspace
ENTRYPOINT ["monaco"]
CMD ["--help"]
```

For enterprise production, build this image once, scan it, sign it, and push it
to the internal container registry. Deploy the tested image by immutable digest
where possible.

Official Monaco source and releases:

<https://github.com/Dynatrace/dynatrace-configuration-as-code>

## 11. Create the Jenkins pipeline

This example assumes a dedicated Linux Jenkins agent with Docker installed and
a workspace path visible to the Docker daemon:

```groovy
pipeline {
  agent {
    label 'docker-linux'
  }

  options {
    disableConcurrentBuilds()
    skipDefaultCheckout(true)
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  triggers {
    pollSCM('H/5 * * * *')
  }

  environment {
    DT_ENV_URL = 'https://YOUR-PROD-ENV.apps.dynatrace.com'
    MONACO_IMAGE = 'company-monaco:2.28.12'
    DASHBOARD_DIR = 'projects/production-observability/dashboard'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build Monaco image') {
      steps {
        sh '''
          docker build \
            --pull \
            --build-arg MONACO_VERSION=2.28.12 \
            -f Dockerfile.monaco \
            -t "$MONACO_IMAGE" .
        '''
      }
    }

    stage('Render dashboard') {
      steps {
        sh '''
          docker run --rm \
            --user "$(id -u):$(id -g)" \
            --entrypoint sh \
            -v "$WORKSPACE:/workspace" \
            -w /workspace \
            "$MONACO_IMAGE" \
            scripts/render-dashboard.sh "$DASHBOARD_DIR"
        '''

        archiveArtifacts(
          artifacts: 'projects/production-observability/dashboard/dashboard.json',
          fingerprint: true
        )
      }
    }

    stage('Validate') {
      steps {
        withCredentials([
          string(
            credentialsId: 'dynatrace-prod-api-token',
            variable: 'DT_API_TOKEN'
          ),
          string(
            credentialsId: 'dynatrace-prod-oauth-client-id',
            variable: 'DT_OAUTH_CLIENT_ID'
          ),
          string(
            credentialsId: 'dynatrace-prod-oauth-client-secret',
            variable: 'DT_OAUTH_CLIENT_SECRET'
          )
        ]) {
          sh '''
            docker run --rm \
              --user "$(id -u):$(id -g)" \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -e DT_OAUTH_CLIENT_ID \
              -e DT_OAUTH_CLIENT_SECRET \
              -v "$WORKSPACE:/workspace" \
              -w /workspace \
              "$MONACO_IMAGE" \
              deploy --dry-run manifest.yaml
          '''
        }
      }
    }

    stage('Production approval') {
      steps {
        input(
          message: 'Deploy the validated configuration to production Dynatrace?',
          ok: 'Deploy'
        )
      }
    }

    stage('Deploy to Dynatrace') {
      steps {
        withCredentials([
          string(
            credentialsId: 'dynatrace-prod-api-token',
            variable: 'DT_API_TOKEN'
          ),
          string(
            credentialsId: 'dynatrace-prod-oauth-client-id',
            variable: 'DT_OAUTH_CLIENT_ID'
          ),
          string(
            credentialsId: 'dynatrace-prod-oauth-client-secret',
            variable: 'DT_OAUTH_CLIENT_SECRET'
          )
        ]) {
          sh '''
            docker run --rm \
              --user "$(id -u):$(id -g)" \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -e DT_OAUTH_CLIENT_ID \
              -e DT_OAUTH_CLIENT_SECRET \
              -v "$WORKSPACE:/workspace" \
              -w /workspace \
              "$MONACO_IMAGE" \
              deploy manifest.yaml
          '''
        }
      }
    }
  }

  post {
    success {
      echo 'Dynatrace production deployment completed successfully.'
    }
    failure {
      echo 'Deployment failed. Review rendering and Monaco logs.'
    }
  }
}
```

Remove the approval stage only if the organization explicitly approves fully
automatic production deployment.

If Jenkins runs inside Docker, the container workspace path might not exist on
the Docker host. Use a dedicated external agent, a shared workspace volume, or
the `--volumes-from` pattern. Do not run production deployments on the Jenkins
controller.

## 12. Configure the Jenkins job

Install these plugins:

```text
Pipeline
Git
Credentials Binding
Bitbucket
SSH Agent
Workspace Cleanup
```

Create a Pipeline job and select `Pipeline script from SCM`.

Configure:

```text
SCM: Git
Repository URL: <Bitbucket clone URL>
Credentials: bitbucket-monaco-read
Branch: */main
Script Path: Jenkinsfile
```

Enable `Build when a change is pushed to Bitbucket`. Keep the five-minute SCM
polling trigger as a fallback until webhook delivery has been proven reliable.

## 13. Configure the Bitbucket webhook

### Bitbucket Cloud

Open:

```text
Repository -> Repository settings -> Webhooks -> Add webhook
```

Configure:

```text
Title: Jenkins Monaco Production
URL: https://jenkins.company.com/bitbucket-hook/
Trigger: Repository push
```

The Jenkins Bitbucket endpoint requires the trailing slash.

Jenkins Bitbucket plugin reference:

<https://plugins.jenkins.io/bitbucket>

Use HTTPS with a trusted certificate. Configure a high-entropy webhook secret
and HMAC verification when supported by the installed integration. Restrict
inbound network access to approved Bitbucket addresses.

Bitbucket webhook reference:

<https://support.atlassian.com/bitbucket-cloud/docs/manage-webhooks/>

### Bitbucket Data Center

Confirm the supported integration with the Bitbucket administrator. Depending
on installed versions, the organization may use native Bitbucket webhooks, Post
Webhooks for Bitbucket, or Bitbucket Branch Source. Do not expose Jenkins to an
untrusted network solely to receive webhooks.

## 14. Perform the first deployment

1. Back up any existing production dashboard and alert configuration.
2. Commit the Monaco repository without credentials or generated files.
3. Push the change to a feature branch.
4. Run the pull-request validation job.
5. Confirm Jenkins archived the generated `dashboard.json`.
6. Confirm Monaco printed `Validation finished without errors`.
7. Review the generated dashboard artifact.
8. Merge through an approved pull request.
9. Let the production job start from `main`.
10. Approve the production stage.
11. Confirm Monaco reports successful deployment for the environment.
12. Open the dashboard using its stable document ID.

Expected URL:

```text
https://YOUR-PROD-ENV.apps.dynatrace.com/ui/apps/dynatrace.dashboards/dashboard/kafka-reds-prod-dashboard
```

## 15. Normal change process

For metric names, aliases, titles, and limits:

```text
edit env.json
    -> create pull request
    -> Jenkins renders and validates
    -> review generated dashboard.json
    -> merge to main
    -> approve production deployment
    -> Monaco updates the dashboard
```

For tile structure or layout changes, edit `template.json`. Never edit or
commit generated `dashboard.json`.

## 16. Rollback

Revert the change in Bitbucket:

```bash
git revert <bad-commit>
git push origin main
```

Jenkins renders the previous configuration and Monaco updates Dynatrace back to
the previous definition.

Removing a configuration file from Git does not by itself guarantee deletion
of the Dynatrace object. Use a Monaco delete file and a separate approval stage
for controlled deletion.

## 17. Troubleshooting

### Manifest file does not exist

The Jenkins workspace is not mounted at the same path inside the Monaco
container. Fix the bind mount, shared volume, or `--volumes-from` configuration.

### Unsupported architecture with an empty value

The legacy Docker builder did not populate `TARGETARCH`. Keep the `uname -m`
fallback in `Dockerfile.monaco`.

### OAuth 401 or 403

Check the OAuth client scopes and the service user's IAM group policies. Both
must allow access to the target environment.

### Settings schema returns 404

Do not copy a schema identifier or version blindly from another tenant. Query
the production tenant and use the schema that it actually exposes.

### Classic dashboard endpoint is unavailable

Use the Dynatrace Platform URL and Monaco `document` dashboard type for modern
dashboards. Do not use the Classic dashboard API on a tenant where it is
disabled.

### Unresolved dashboard template variable

A placeholder in `template.json` has no matching key in the selected
environment JSON file. Correct the key or add the missing value.

### Bitbucket push does not trigger Jenkins

Check the trailing slash in `/bitbucket-hook/`, repository URL matching,
firewall rules, webhook delivery history, job trigger configuration, and
Bitbucket plugin compatibility.

## 18. Production controls

- Protect `main` and require pull-request approval.
- Require a successful Jenkins validation check before merge.
- Keep manual approval before production deployment.
- Use a dedicated Jenkins deployment agent, not the controller.
- Pin Monaco, Alpine, and Jenkins versions.
- Build and scan the Monaco image before production promotion.
- Store images in an internal registry.
- Store secrets only in Jenkins Credentials or an enterprise vault.
- Rotate Dynatrace and Bitbucket credentials regularly.
- Use service identities instead of personal accounts.
- Use HTTPS and webhook signature validation.
- Retain generated dashboard artifacts for audit purposes.
- Back up existing Dynatrace resources before Monaco onboarding.
- Test changes against a non-production Dynatrace environment first.
- Keep project names, configuration IDs, and document IDs stable.
- Disable concurrent production deployments.
- Use explicit, approved delete operations rather than implicit deletion.
