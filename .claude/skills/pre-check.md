---
description: Run the pre-setup inspection script (pre.sh) on a fresh sprite and summarise the baseline state before running setup.sh.
---

# Pre-setup check

Run the pre-setup inspection on the current sprite and report what you find.

## Steps

1. Ensure `pre.sh` is executable:
   ```bash
   chmod +x pre.sh
   ```

2. Run the script and capture output:
   ```bash
   ./pre.sh | tee /tmp/pre-check.txt
   ```

3. Parse the output and summarise:
   - **Identity**: user, home, shell
   - **OS**: distro and version
   - **Pre-installed tools**: list what's present vs missing (focus on the tools setup.sh installs)
   - **Network reachability**: flag any blocked hosts (github.com, download.docker.com, astral.sh, fly.io)
   - **Existing rc/git/ssh state**: note anything that might cause `setup.sh` to behave unexpectedly
   - **sprite Services**: list any existing services
   - **Warnings**: highlight anything that could cause setup.sh to fail or produce unexpected results

4. Conclude with a go/no-go recommendation for running `setup.sh`.
