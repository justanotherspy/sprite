---
description: Bootstrap a new sprite by running setup.sh. Guides through the interactive prompts and monitors for errors.
---

# Bootstrap sprite

Run the dev-environment setup on the current sprite.

## Before you start

- Confirm `pre.sh` has been run (or run `/pre-check` first) and there are no blocking issues.
- Make sure you have the following ready:
  - Git name and email
  - (Optional) A GitHub PAT with `repo` and `read:org` scopes for `GH_TOKEN`
  - (Optional) Decision on whether to generate a new SSH key

## Steps

1. Make the script executable:
   ```bash
   chmod +x setup.sh
   ```

2. Run setup (this takes several minutes):
   ```bash
   ./setup.sh
   ```

3. The script will prompt for:
   - **Git user.name** — enter your name or press Enter to keep the existing value
   - **Git user.email** — enter your email or press Enter to keep the existing value
   - **Generate SSH key?** — `Y` (recommended for GitHub pushes) or `n`
   - **Add SSH key to GitHub** — press Enter after adding the public key at github.com/settings/ssh/new
   - **GitHub PAT** — paste a token or press Enter to skip

4. Monitor for errors (lines starting with `x`). Common issues:
   - APT lock held by another process — wait and re-run
   - Docker repo codename missing — the script falls back to `noble` automatically
   - `sprite-env not on PATH` — expected if running outside a sprite; dockerd Service won't be registered

5. After setup completes, run `/post-check` to verify.

## If setup.sh was interrupted

The script is idempotent — just re-run it. APT and install steps are conditional; rc edits use sentinel markers to avoid duplication.
