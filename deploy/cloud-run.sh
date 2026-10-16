#!/usr/bin/env bash
# Deploy asc-mcp to Google Cloud Run as a remote MCP server.
#
# Usage (from the repository root):
#   deploy/cloud-run.sh <gcp-project-id> <path-to-AuthKey_XXXX.p8> <key-id> <issuer-id>
#
# Optional environment variables:
#   REGION      Cloud Run region (default: europe-north1, Finland)
#   ASC_MCP_ARGS Server flags, e.g. "--read-only" or "--workers apps,versions,builds"
#   FASTLANE_SESSION      Apple ID web session from `fastlane spaceauth -u <apple-id>`; enables apps_create.
#                         Apple expires it after about a month: re-run this script with a fresh one.
#   FASTLANE_ITC_TEAM_ID  App Store Connect team (provider) ID, if your Apple ID has several teams.
#
# Safe to re-run: it adds new secret versions and redeploys. The connector URL stays the same.
set -euo pipefail

PROJECT="$1"; P8_FILE="$2"; KEY_ID="$3"; ISSUER_ID="$4"
REGION="${REGION:-europe-north1}"
SERVICE="asc-mcp"

gcloud config set project "$PROJECT"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com

# printf avoids a trailing newline, which would break the key ID inside the JWT.
put_secret() {
  if gcloud secrets describe "$1" >/dev/null 2>&1; then
    printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=-
  else
    printf '%s' "$2" | gcloud secrets create "$1" --data-file=-
  fi
}

put_secret asc-key-id "$KEY_ID"
put_secret asc-issuer-id "$ISSUER_ID"
put_secret asc-private-key "$(cat "$P8_FILE")"

# The secret URL path is generated once and kept, so the connector URL is stable.
if ! gcloud secrets describe mcp-path >/dev/null 2>&1; then
  put_secret mcp-path "mcp-$(openssl rand -hex 24)"
fi

SECRETS="ASC_KEY_ID=asc-key-id:latest,ASC_ISSUER_ID=asc-issuer-id:latest,ASC_PRIVATE_KEY=asc-private-key:latest,MCP_PATH=mcp-path:latest"
SECRET_NAMES="asc-key-id asc-issuer-id asc-private-key mcp-path"

# Optional Apple ID web session for apps_create. Once stored, later deploys keep using it.
if [ -n "${FASTLANE_SESSION:-}" ]; then
  put_secret fastlane-session "$FASTLANE_SESSION"
fi
if gcloud secrets describe fastlane-session >/dev/null 2>&1; then
  SECRETS="$SECRETS,FASTLANE_SESSION=fastlane-session:latest"
  SECRET_NAMES="$SECRET_NAMES fastlane-session"
fi

# Let Cloud Run's default service account read the secrets.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for s in $SECRET_NAMES; do
  gcloud secrets add-iam-policy-binding "$s" --member="serviceAccount:$SA" \
    --role=roles/secretmanager.secretAccessor >/dev/null
done

# Cloud Build builds the Dockerfile in the repository root.
gcloud run deploy "$SERVICE" \
  --source . \
  --region "$REGION" \
  --allow-unauthenticated \
  --min-instances 0 --max-instances 1 \
  --memory 512Mi --cpu 1 \
  --set-env-vars "^@^ASC_MCP_ARGS=${ASC_MCP_ARGS:-}@FASTLANE_ITC_TEAM_ID=${FASTLANE_ITC_TEAM_ID:-}" \
  --set-secrets "$SECRETS"

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
MCP_PATH="$(gcloud secrets versions access latest --secret=mcp-path)"
echo
echo "Your MCP connector URL (treat it like a password):"
echo "  $URL/$MCP_PATH"
