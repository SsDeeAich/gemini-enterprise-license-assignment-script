# Gemini Enterprise License Assignment Script

Programmatically assign Gemini Enterprise licenses by edition using Google Group membership as the source of truth.

This script bridges Google Groups and the Gemini Enterprise Discovery Engine API. Define a mapping of Google Group → subscription edition, and the script will:

1. Pull members from each group via `gcloud identity`
2. Assign the correct license edition to each member via `batchUpdateUserLicenses`
3. Optionally remove licenses from users no longer in the group

This gives you group-based license management where the group is the single source of truth for each edition tier.

## Quick Start

```bash
# 1. Check prerequisites
./gemini-helpers.sh check-prereqs

# 2. Copy and fill in your config
cp .env.example .env
# Edit .env with your project ID, project number, group emails, and subscription IDs

# 3. Find your subscription IDs
./gemini-helpers.sh list-configs

# 4. Preview what the sync will do (no changes made)
./gemini-license-sync.sh --dry-run

# 5. Run the sync
./gemini-license-sync.sh
```

## How It Works

```
┌─────────────────────────┐
│   Google Groups           │
│                           │
│  gemini-plus@company.com  │──► Plus licenses
│  gemini-std@company.com   │──► Standard licenses
│  gemini-fl@company.com    │──► Frontline licenses
└─────────────────────────┘
            │
            ▼
    gcloud identity groups
    memberships list
            │
            ▼
┌─────────────────────────┐
│  batchUpdateUserLicenses  │
│  (Discovery Engine API)   │
│                           │
│  Each user gets the       │
│  licenseConfig matching   │
│  their group's edition    │
└─────────────────────────┘
```

Each Gemini Enterprise subscription has a unique `licenseConfig` path. The script maps each group to its corresponding config, so users in the Plus group get Plus licenses, Standard group members get Standard licenses, and so on.

## Files in This Repo

| File | Purpose |
|------|---------|
| `gemini-license-sync.sh` | Main sync script — reads group membership and assigns licenses |
| `gemini-helpers.sh` | Helper utilities — discover subscription IDs, check prerequisites, list assigned licenses |
| `.env.example` | Configuration template — copy to `.env` and fill in your values |
| `.gitignore` | Prevents committing `.env` (secrets) and log files |
| `README.md` | This file |

## Prerequisites

- **Google Cloud SDK** (`gcloud`) installed and authenticated
- **Bash 4.0+** (for associative arrays — macOS users may need `brew install bash`)
- **IAM permissions** on the target project:
  - `discoveryengine.userLicenses.batchUpdate` (or Discovery Engine Admin role)
  - Billing Account Administrator (to manage subscriptions)
- **Cloud Identity API** enabled (for group membership queries)
- **Active Gemini Enterprise subscriptions** for each edition you want to assign (Frontline, Standard, Plus)
- The authenticated user must have permission to list group memberships

Run `./gemini-helpers.sh check-prereqs` to verify your environment is ready.

## Setup

### 1. Find Your Subscription IDs

Each edition has a unique subscription ID. You can find these in the Cloud Console under **Gemini Enterprise → Manage Subscriptions**, or use the helper script:

```bash
./gemini-helpers.sh list-configs
```

You can also look up your numeric project number:

```bash
./gemini-helpers.sh get-project-number
```

### 2. Create Your Google Groups

Create one group per edition in Google Workspace Admin or Cloud Identity:

| Group | Purpose |
|-------|---------| 
| `gemini-ent-plus@yourdomain.com` | Users who should receive **Plus** licenses |
| `gemini-ent-standard@yourdomain.com` | Users who should receive **Standard** licenses |
| `gemini-ent-frontline@yourdomain.com` | Users who should receive **Frontline** licenses |

Use whatever naming convention works for your org. The group emails are configurable.

### 3. Configure

Copy the example config and fill in your values:

```bash
cp .env.example .env
```

Edit `.env` with your project details and group-to-subscription mappings:

```bash
PROJECT_ID="my-gcp-project"
PROJECT_NUMBER="123456789012"
LOCATION="global"
ENDPOINT_LOCATION="global"

GROUP_1_EMAIL="gemini-ent-plus@yourdomain.com"
GROUP_1_SUBSCRIPTION="your-plus-subscription-id"

GROUP_2_EMAIL="gemini-ent-standard@yourdomain.com"
GROUP_2_SUBSCRIPTION="your-standard-subscription-id"

GROUP_3_EMAIL="gemini-ent-frontline@yourdomain.com"
GROUP_3_SUBSCRIPTION="your-frontline-subscription-id"
```

> **Note:** `PROJECT_NUMBER` is the numeric project number, not the alphanumeric project ID. Find it via `./gemini-helpers.sh get-project-number` or `gcloud projects describe $PROJECT_ID --format="value(projectNumber)"`.

Alternatively, you can skip the `.env` file and edit the `GROUP_MAP` directly inside `gemini-license-sync.sh`.

### 4. Preview with Dry Run

Before making any changes, preview what the script would do:

```bash
./gemini-license-sync.sh --dry-run
```

This fetches group members and logs all actions without making any API calls to assign licenses.

### 5. Run the Sync

```bash
chmod +x gemini-license-sync.sh gemini-helpers.sh
./gemini-license-sync.sh
```

The script logs all operations to a timestamped log file (`gemini-license-sync-YYYYMMDD-HHMMSS.log`).

## Configuration Options

### `DELETE_UNASSIGNED`

Controls whether users **not** in the group payload lose their license for that edition.

| Value | Behavior |
|-------|----------|
| `false` (default) | Only adds/updates licenses. Existing users not in the group keep their licenses. Safe for first runs. |
| `true` | Removes licenses from users not present in the group for that edition. Makes the group the authoritative source. |

> **Warning:** On your first run, keep this `false` until you've verified the script assigns correctly. Flipping to `true` prematurely could revoke licenses from existing users who aren't yet in the group.

### `BATCH_SIZE`

Users are processed in chunks to avoid API payload limits. Default is `100`. Adjust if you encounter issues with very large groups.

## Helper Script

`gemini-helpers.sh` provides standalone utilities for discovery and verification:

```bash
./gemini-helpers.sh check-prereqs        # Verify gcloud, curl, and authentication
./gemini-helpers.sh get-project-number    # Look up numeric project number
./gemini-helpers.sh list-configs          # List license config IDs and edition info
./gemini-helpers.sh list-licenses         # List currently assigned user licenses
```

These commands read configuration from `.env` (if present) or you can export `PROJECT_ID`, `LOCATION`, etc. as environment variables.

## Scheduling for Ongoing Sync

For continuous group-to-license sync, run the script on a schedule:

**Cloud Scheduler + Cloud Function:**
Deploy the logic as a Cloud Function triggered on a cron schedule (e.g., every hour). This keeps licenses in sync as users join and leave groups.

**Cron job:**
On any machine with `gcloud` authenticated:

```bash
# Run every hour
0 * * * * /path/to/gemini-license-sync.sh >> /var/log/gemini-sync.log 2>&1
```

**Systemd timer:**
For more robust scheduling on Linux servers.

When running on a schedule, consider setting `DELETE_UNASSIGNED="true"` so that removing a user from the group automatically revokes their license.

## API Reference

The script uses two main APIs:

**Cloud Identity — List Group Members**
```
gcloud identity groups memberships list --group-email=GROUP
```
Returns all members of a Google Group with their email addresses.

**Discovery Engine — Batch Update User Licenses**
```
POST https://{LOCATION}-discoveryengine.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/userStores/default_user_store:batchUpdateUserLicenses
```
Accepts an array of `userLicenses` objects, each containing a `userPrincipal` (email) and `licenseConfig` (edition-specific subscription path).

The `licenseConfig` path format:
```
projects/{PROJECT_NUMBER}/locations/{LOCATION}/licenseConfigs/{SUBSCRIPTION_ID}
```

## Verifying Assignments

List all currently assigned licenses to confirm the sync worked:

```bash
./gemini-helpers.sh list-licenses
```

## Troubleshooting

**"No members found in group"** — Ensure the authenticated `gcloud` account has permission to list group memberships. You may need the Groups Reader or Groups Admin role in Cloud Identity.

**HTTP 403 on license assignment** — Verify the account has `discoveryengine.userLicenses.batchUpdate` permission and Billing Account Administrator on the billing account tied to the subscriptions.

**HTTP 400 / invalid licenseConfig** — Double-check your `PROJECT_NUMBER` (not project ID) and `SUBSCRIPTION_ID`. Use `./gemini-helpers.sh list-configs` to list valid configs.

**Users not gaining access after assignment** — License propagation can take up to 30 minutes. Ensure users also have the Discovery Engine User IAM role on the project.

**Config validation errors** — The script validates configuration before running. If you see placeholder errors, ensure your `.env` file has real values. Run `./gemini-helpers.sh get-project-number` and `./gemini-helpers.sh list-configs` to find the correct values.

## License

MIT
