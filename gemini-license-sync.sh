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
#   Copy config.json.example to config.json and fill in your values
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Configuration file not found at ${CONFIG_FILE}"
  echo "       Please copy config.json.example to config.json and fill in your values."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed. Please install jq to parse the config file."
  echo "       macOS: brew install jq"
  echo "       Linux: sudo apt install jq"
  exit 1
fi

# === CONFIGURATION (Parsed from JSON) ===
PROJECT_ID=$(jq -r '.project_id // "your-project-id"' "$CONFIG_FILE")
PROJECT_NUMBER=$(jq -r '.project_number // "123456789012"' "$CONFIG_FILE")
LOCATION=$(jq -r '.location // "global"' "$CONFIG_FILE")
ENDPOINT_LOCATION=$(jq -r '.endpoint_location // "global"' "$CONFIG_FILE")
DELETE_UNASSIGNED=$(jq -r '.delete_unassigned // false' "$CONFIG_FILE")
BATCH_SIZE=$(jq -r '.batch_size // 100' "$CONFIG_FILE")

# Group → Subscription mapping
GROUP_EMAILS=()
GROUP_SUBSCRIPTIONS=()

while IFS="=" read -r group sub; do
  if [ -n "$group" ] && [ -n "$sub" ]; then
    GROUP_EMAILS+=("$group")
    GROUP_SUBSCRIPTIONS+=("$sub")
  fi
done < <(jq -r '.group_mappings | to_entries | .[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || echo "")

# If no mappings found in JSON, fall back to hardcoded defaults for safety
if [ ${#GROUP_EMAILS[@]} -eq 0 ]; then
  GROUP_EMAILS=(
    "gemini-ent-frontline@yourdomain.com"
    "gemini-ent-standard@yourdomain.com"
    "gemini-ent-plus@yourdomain.com"
  )
  GROUP_SUBSCRIPTIONS=(
    "SUBSCRIPTION_ID_FRONTLINE"
    "SUBSCRIPTION_ID_STANDARD"
    "SUBSCRIPTION_ID_PLUS"
  )
fi

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
    echo "       Edit the config.json file."
    ok=false
  fi

  if [ "$PROJECT_NUMBER" = "123456789012" ]; then
    echo "ERROR: PROJECT_NUMBER is still set to the placeholder value."
    echo "       Find it via: ./gemini-helpers.sh get-project-number"
    ok=false
  fi

  if [ ${#GROUP_EMAILS[@]} -eq 0 ]; then
    echo "ERROR: No group-to-subscription mappings defined."
    ok=false
  fi

  # Check for placeholder subscription IDs
  for i in "${!GROUP_EMAILS[@]}"; do
    local group_email="${GROUP_EMAILS[$i]}"
    local sub_id="${GROUP_SUBSCRIPTIONS[$i]}"
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

for i in "${!GROUP_EMAILS[@]}"; do
  group_email="${GROUP_EMAILS[$i]}"
  subscription_id="${GROUP_SUBSCRIPTIONS[$i]}"
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
