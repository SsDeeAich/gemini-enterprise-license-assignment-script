#!/bin/bash
# =============================================================================
# Gemini Enterprise License Sync
# Assigns licenses by edition based on Google Group membership
#
# Maps Google Groups → Gemini Enterprise editions (Frontline, Standard, Plus)
# Uses the Discovery Engine batchUpdateUserLicenses API
#
# Usage:
#   ./gemini-license-sync.sh              # Run the sync
#   ./gemini-license-sync.sh --dry-run    # Preview changes without making API calls
#
# Configuration:
#   Copy .env.example to .env and fill in your values, or edit the defaults below.
# =============================================================================

set -euo pipefail

# === PARSE FLAGS ===
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run]"
      echo ""
      echo "  --dry-run   Preview what would happen without making API calls"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg"
      echo "Usage: $0 [--dry-run]"
      exit 1
      ;;
  esac
done

# === LOAD CONFIG ===
# Source .env file if it exists (allows config without editing this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi

# === CONFIGURATION (defaults — override via .env or environment variables) ===
PROJECT_ID="${PROJECT_ID:-your-project-id}"
PROJECT_NUMBER="${PROJECT_NUMBER:-123456789012}"  # Numeric project number (not the ID)
LOCATION="${LOCATION:-global}"                    # or "us" or "eu"
ENDPOINT_LOCATION="${ENDPOINT_LOCATION:-global}"  # Must match LOCATION

# Group → Subscription mapping
# If .env defines GROUP_N_EMAIL / GROUP_N_SUBSCRIPTION pairs, build the map from those.
# Otherwise, fall back to a hardcoded default map (edit these if not using .env).
declare -A GROUP_MAP

if [ -n "${GROUP_1_EMAIL:-}" ] && [ -n "${GROUP_1_SUBSCRIPTION:-}" ]; then
  # Build map from .env numbered pairs
  for i in $(seq 1 20); do
    email_var="GROUP_${i}_EMAIL"
    sub_var="GROUP_${i}_SUBSCRIPTION"
    if [ -n "${!email_var:-}" ] && [ -n "${!sub_var:-}" ]; then
      GROUP_MAP["${!email_var}"]="${!sub_var}"
    fi
  done
else
  # Hardcoded defaults — edit these directly if not using .env
  GROUP_MAP=(
    ["gemini-ent-frontline@yourdomain.com"]="SUBSCRIPTION_ID_FRONTLINE"
    ["gemini-ent-standard@yourdomain.com"]="SUBSCRIPTION_ID_STANDARD"
    ["gemini-ent-plus@yourdomain.com"]="SUBSCRIPTION_ID_PLUS"
  )
fi

# Set to "true" to remove licenses from users NOT in the group for that edition
# WARNING: On first run, keep this "false" to avoid accidentally removing existing users
DELETE_UNASSIGNED="${DELETE_UNASSIGNED:-false}"

# Batch size — split large groups into chunks to avoid payload limits
BATCH_SIZE="${BATCH_SIZE:-100}"

# === PREREQUISITE CHECKS ===

check_prereqs() {
  local ok=true

  if ! command -v gcloud &>/dev/null; then
    echo "ERROR: gcloud is not installed. Install the Google Cloud SDK:"
    echo "       https://cloud.google.com/sdk/docs/install"
    ok=false
  fi

  if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is not installed."
    ok=false
  fi

  if [ "$ok" = false ]; then
    exit 1
  fi

  if ! gcloud auth print-access-token &>/dev/null 2>&1; then
    echo "ERROR: gcloud is not authenticated. Run: gcloud auth login"
    exit 1
  fi
}

validate_config() {
  local ok=true

  if [ "$PROJECT_ID" = "your-project-id" ]; then
    echo "ERROR: PROJECT_ID is still set to the placeholder value."
    echo "       Create a .env file (see .env.example) or edit the script."
    ok=false
  fi

  if [ "$PROJECT_NUMBER" = "123456789012" ]; then
    echo "ERROR: PROJECT_NUMBER is still set to the placeholder value."
    echo "       Find it via: ./gemini-helpers.sh get-project-number"
    ok=false
  fi

  if [ ${#GROUP_MAP[@]} -eq 0 ]; then
    echo "ERROR: No group-to-subscription mappings defined."
    ok=false
  fi

  # Check for placeholder subscription IDs
  for group_email in "${!GROUP_MAP[@]}"; do
    local sub_id="${GROUP_MAP[$group_email]}"
    if [[ "$sub_id" == SUBSCRIPTION_ID_* ]]; then
      echo "WARNING: Subscription ID for ${group_email} looks like a placeholder: ${sub_id}"
      echo "         Find real IDs via: ./gemini-helpers.sh list-configs"
      ok=false
    fi
  done

  if [ "$ok" = false ]; then
    exit 1
  fi
}

check_prereqs
validate_config

# === LOGGING ===
LOG_FILE="gemini-license-sync-$(date +%Y%m%d-%H%M%S).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# === CACHE ACCESS TOKEN ===
# Fetch once and reuse — avoids repeated gcloud calls and mid-run expiry risk
ACCESS_TOKEN="$(gcloud auth print-access-token)"

# === FUNCTIONS ===

get_group_members() {
  local group_email="$1"
  gcloud identity groups memberships list \
    --group-email="${group_email}" \
    --format="value(preferredMemberKey.id)" \
    2>/dev/null
}

assign_licenses_batch() {
  local subscription_id="$1"
  shift
  local emails=("$@")

  # Build userLicenses JSON array
  local license_config="projects/${PROJECT_NUMBER}/locations/${LOCATION}/licenseConfigs/${subscription_id}"
  local user_licenses=""

  for email in "${emails[@]}"; do
    if [ -n "$email" ]; then
      user_licenses="${user_licenses}{\"userPrincipal\":\"${email}\",\"licenseConfig\":\"${license_config}\"},"
    fi
  done

  # Remove trailing comma
  user_licenses="${user_licenses%,}"

  if [ "$DRY_RUN" = true ]; then
    log "  [DRY RUN] Would assign ${#emails[@]} licenses with config: ${subscription_id}"
    return 0
  fi

  # Call batchUpdateUserLicenses
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "https://${ENDPOINT_LOCATION}-discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/userStores/default_user_store:batchUpdateUserLicenses" \
    -d "{
      \"inlineSource\": {
        \"userLicenses\": [${user_licenses}],
        \"updateMask\": {
          \"paths\": [\"userPrincipal\", \"licenseConfig\"]
        }
      },
      \"deleteUnassignedUserLicenses\": ${DELETE_UNASSIGNED}
    }")

  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" =~ ^2 ]]; then
    log "  ✓ Batch assigned successfully (HTTP ${http_code})"
    return 0
  else
    log "  ✗ Batch failed (HTTP ${http_code}): ${body}"
    return 1
  fi
}

# === MAIN ===

log "=========================================="
if [ "$DRY_RUN" = true ]; then
  log "*** DRY RUN MODE — no changes will be made ***"
fi
log "Gemini Enterprise License Sync Starting"
log "Project: ${PROJECT_ID} | Location: ${LOCATION}"
log "Delete unassigned: ${DELETE_UNASSIGNED}"
log "=========================================="

TOTAL_ASSIGNED=0
TOTAL_ERRORS=0

for group_email in "${!GROUP_MAP[@]}"; do
  subscription_id="${GROUP_MAP[$group_email]}"
  log ""
  log "Processing group: ${group_email}"
  log "  Subscription ID: ${subscription_id}"

  # Fetch group members
  members_raw=$(get_group_members "$group_email")

  if [ -z "$members_raw" ]; then
    log "  ⚠ No members found in group — skipping"
    continue
  fi

  # Convert to array (compatible with bash 3.2+)
  members=()
  while IFS= read -r line; do
    [ -n "$line" ] && members+=("$line")
  done <<< "$members_raw"

  member_count=${#members[@]}
  log "  Found ${member_count} members"

  # Process in batches
  for ((i = 0; i < member_count; i += BATCH_SIZE)); do
    batch=("${members[@]:i:BATCH_SIZE}")
    batch_num=$(( (i / BATCH_SIZE) + 1 ))
    total_batches=$(( (member_count + BATCH_SIZE - 1) / BATCH_SIZE ))

    log "  Assigning batch ${batch_num}/${total_batches} (${#batch[@]} users)..."
    if assign_licenses_batch "$subscription_id" "${batch[@]}"; then
      TOTAL_ASSIGNED=$((TOTAL_ASSIGNED + ${#batch[@]}))
    else
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    # Small delay between batches to avoid rate limiting
    if [ "$batch_num" -lt "$total_batches" ]; then
      sleep 1
    fi
  done
done

log ""
log "=========================================="
log "Sync complete."
log "  Users assigned:  ${TOTAL_ASSIGNED}"
log "  Batch errors:    ${TOTAL_ERRORS}"
if [ "$DRY_RUN" = true ]; then
  log "  *** This was a dry run — no changes were made ***"
fi
log "Log saved to: ${LOG_FILE}"
log "=========================================="

# Exit with non-zero if there were errors
if [ "$TOTAL_ERRORS" -gt 0 ]; then
  exit 1
fi
