# Gemini Enterprise License Assignment Script

## The Problem

Gemini Enterprise does not support group-based license assignment natively currently. The console and API require individual email addresses, and the auto-assign feature only works for a single edition — it can't differentiate between Frontline, Standard, and Plus users.
If you're managing multiple editions across different user populations, you're stuck manually assigning licenses one by one.

## The Solution

Programmatically assign Gemini Enterprise licenses by edition using Google Group membership as the source of truth.

This script bridges Google Groups and the Gemini Enterprise Discovery Engine API. Define a mapping of Google Group → subscription edition, and the script will:

1. Pull members from each group via `gcloud identity`
2. Assign the correct license edition to each member via `batchUpdateUserLicenses`
3. Optionally remove licenses from users no longer in the group

This gives you group-based license management where the group is the single source of truth for each edition tier.

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

### Required APIs & Permissions

Before running the scripts, ensure the following APIs and permissions are configured for your Google Cloud Project.

#### 1. Enabled APIs

You must enable the following APIs in your Google Cloud Project:
* **Cloud Identity API** (`cloudidentity.googleapis.com`) – Required to query Google Groups memberships.
* **Discovery Engine API** (`discoveryengine.googleapis.com`) – Required to retrieve license configurations and assign licenses to users.

#### 2. IAM Roles

To run these scripts, the authenticated user (or service account) must have the following permissions:

**A. Cloud Identity / Workspace Admin Roles**
Required to list the members of Google Groups (`gcloud identity groups memberships list`).
* **Google Workspace Admin** with Groups Reader privileges, OR
* **Groups Admin** role, OR
* **Groups Reader** role in Cloud Identity

**B. Google Cloud IAM Roles**
Required to query and assign licenses via the Discovery Engine API.
* **Discovery Engine Admin** (`roles/discoveryengine.admin`) on the target project, OR
* **Discovery Engine Editor** (`roles/discoveryengine.editor`)

## Quick Start (Cloud Shell)

This script is optimized to run inside Google Cloud Shell. When run in Cloud Shell, it automatically discovers your current project ID and project number, meaning **zero project configuration is required**—you only need to define your group mappings!

```bash
# 1. Verify your environment is ready
./gemini-helpers.sh check-prereqs

# 2. Copy the config template
cp config.json.example config.json
```

### 3. Edit your Configuration

You can easily edit `config.json` using the built-in Cloud Shell Editor. Simply click the **Open Editor** button at the top of your Cloud Shell window, navigate to `config.json`, and define your group mappings:

```json
{
  "project_id": "",
  "project_number": "",
  "location": "global",
  "endpoint_location": "global",
  "delete_unassigned": false,
  "batch_size": 100,
  "group_mappings": {
    "marketing-team@example.com": "YOUR_SUBSCRIPTION_ID"
  }
}
```

> **Note:** Leave `project_id` and `project_number` as empty strings `""` and the script will automatically discover them from your Cloud Shell environment.

### 4. Find Your Subscription IDs

If you don't know your subscription IDs, you can list them via:

```bash
./gemini-helpers.sh list-configs
```

### 5. Preview with Dry Run

Before making any changes, preview what the script would do:

```bash
./gemini-license-sync.sh --dry-run
```

This fetches group members and logs all actions without making any API calls to assign licenses.

### 6. Run the Sync

```bash
./gemini-license-sync.sh
```

The script logs all operations to a timestamped log file (`gemini-license-sync-YYYYMMDD-HHMMSS.log`).

## Local Execution (Optional)

If you prefer to run this script locally on your own terminal instead of Cloud Shell, you will need to manually set `project_id` and `project_number` in `config.json`.

You can find your numeric project number by running:

```bash
./gemini-helpers.sh get-project-number my-gcp-project
```

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

These commands read configuration from `config.json` (if present) or you can export `PROJECT_ID`, `LOCATION`, etc. as environment variables.

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

**Config validation errors** — The script validates configuration before running. If you see placeholder errors, ensure your `config.json` file has real values. Run `./gemini-helpers.sh get-project-number` and `./gemini-helpers.sh list-configs` to find the correct values.

## License

MIT
