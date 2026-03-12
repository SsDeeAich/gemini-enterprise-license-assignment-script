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

# === LOGGING & VISUALS ===
LOG_FILE="gemini-license-sync-$(date +%Y%m%d-%H%M%S).log"

# ANSI Colors
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"
C_BOLD="\033[1m"

log() {
  local level="$1"
  shift
  local color=""
  local prefix=""
  
  case "$level" in
    SUCCESS) color="$C_GREEN"; prefix="  ✓ " ;;
    ERROR)   color="$C_RED"; prefix="  ✗ " ;;
    INFO)    color="$C_BLUE"; prefix="  ℹ " ;;
    WARN)    color="$C_YELLOW"; prefix="  ⚠ " ;;
    HEADER)  color="$C_CYAN$C_BOLD"; prefix="" ;;
    *)       color="$C_RESET"; prefix="    " ;; # Default/None
  esac

  echo -e "${color}${prefix}$*${C_RESET}"
  # Strip ANSI codes for the log file
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# === CONFIGURATION (Parsed from JSON) ===
PROJECT_ID=$(jq -r '.project_id // ""' "$CONFIG_FILE")
PROJECT_NUMBER=$(jq -r '.project_number // ""' "$CONFIG_FILE")
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

  # Auto-discover PROJECT_ID if empty
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "your-project-id" ]; then
    log INFO "Project ID not provided in config.json. Attempting auto-discovery..."
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
    if [ -z "$PROJECT_ID" ]; then
      log ERROR "Could not auto-discover PROJECT_ID."
      log ERROR "Please set it in config.json or run: gcloud config set project YOUR_PROJECT"
      ok=false
    else
      log SUCCESS "Auto-discovered Project ID: $PROJECT_ID"
    fi
  fi

  # Auto-discover PROJECT_NUMBER if empty
  if [ -z "$PROJECT_NUMBER" ] || [ "$PROJECT_NUMBER" = "123456789012" ]; then
    if [ -n "$PROJECT_ID" ]; then
      log INFO "Project Number not provided in config.json. Attempting auto-discovery..."
      PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || echo "")
      if [ -z "$PROJECT_NUMBER" ]; then
        log ERROR "Could not auto-discover PROJECT_NUMBER for project $PROJECT_ID."
        log ERROR "Check your IAM permissions or set it manually in config.json."
        ok=false
      else
        log SUCCESS "Auto-discovered Project Number: $PROJECT_NUMBER"
      fi
    else
      ok=false
    fi
  fi

  if [ ${#GROUP_EMAILS[@]} -eq 0 ]; then
    log ERROR "No group-to-subscription mappings defined."
    ok=false
  fi

  # Check for placeholder subscription IDs
  for i in "${!GROUP_EMAILS[@]}"; do
    local group_email="${GROUP_EMAILS[$i]}"
    local sub_id="${GROUP_SUBSCRIPTIONS[$i]}"
    if [[ "$sub_id" == SUBSCRIPTION_ID_* ]]; then
      log WARN "Subscription ID for ${group_email} looks like a placeholder: ${sub_id}"
      log WARN "Find real IDs via: ./gemini-helpers.sh list-configs"
      ok=false
    fi
  done

  if [ "$ok" = false ]; then
    exit 1
  fi
}

# Check prereqs before validation so gcloud commands work
check_prereqs
validate_config



# === CACHE ACCESS TOKEN ===
# Fetch once and reuse — avoids repeated gcloud calls and mid-run expiry risk
ACCESS_TOKEN="$(gcloud auth print-access-token)"

# === FUNCTIONS ===

get_group_members() {
  local group_email="$1"
  gcloud identity groups memberships list \
    --group-email="${group_email}" \
    --format="value(preferredMemberKey.id)" \
    2>/dev/null || echo ""
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
    log NONE "[DRY RUN] Would assign ${#emails[@]} licenses with config: ${subscription_id}"
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
    log SUCCESS "Batch assigned successfully (HTTP ${http_code})"
    return 0
  else
    log ERROR "Batch failed (HTTP ${http_code}): ${body}"
    return 1
  fi
}

# === MAIN ===

echo ""
log HEADER "=========================================="
if [ "$DRY_RUN" = true ]; then
  log WARN "*** DRY RUN MODE — no changes will be made ***"
fi
log HEADER "Gemini Enterprise License Sync Starting"
log NONE "Project: ${PROJECT_ID} | Location: ${LOCATION}"
log NONE "Delete unassigned: ${DELETE_UNASSIGNED}"
log HEADER "=========================================="

TOTAL_ASSIGNED=0
TOTAL_ERRORS=0

for i in "${!GROUP_EMAILS[@]}"; do
  group_email="${GROUP_EMAILS[$i]}"
  subscription_id="${GROUP_SUBSCRIPTIONS[$i]}"
  log HEADER ""
  log HEADER "Processing group: ${group_email}"
  log NONE "  Subscription ID: ${subscription_id}"

  # Fetch group members
  members_raw=$(get_group_members "$group_email")

  # Convert to array (compatible with both bash 3.2+ and Cloud Shell)
  members=()
  while IFS= read -r line; do
    [ -n "$line" ] && members+=("$line")
  done <<< "$members_raw"

  member_count=${#members[@]}
  if [ "$member_count" -eq 0 ]; then
    log WARN "No members found in group — skipping"
    continue
  fi

  log INFO "Found ${member_count} members"

  # Process in batches
  for ((j = 0; j < member_count; j += BATCH_SIZE)); do
    batch=("${members[@]:j:BATCH_SIZE}")
    batch_num=$(( (j / BATCH_SIZE) + 1 ))
    total_batches=$(( (member_count + BATCH_SIZE - 1) / BATCH_SIZE ))

    log INFO "Assigning batch ${batch_num}/${total_batches} (${#batch[@]} users)..."
    if assign_licenses_batch "$subscription_id" "${batch[@]}"; then
      TOTAL_ASSIGNED=$((TOTAL_ASSIGNED + ${#batch[@]}))
    else
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    if [ "$batch_num" -lt "$total_batches" ]; then
      sleep 1
    fi
  done
done

echo ""
log HEADER "=========================================="
log HEADER "Sync complete."
log SUCCESS "Users assigned:  ${TOTAL_ASSIGNED}"
log ERROR   "Batch errors:    ${TOTAL_ERRORS}"
if [ "$DRY_RUN" = true ]; then
  log WARN "*** This was a dry run — no changes were made ***"
fi
log INFO "Log saved to: ${LOG_FILE}"
log HEADER "=========================================="

# Exit with non-zero if there were errors
if [ "$TOTAL_ERRORS" -gt 0 ]; then
  exit 1
fi
