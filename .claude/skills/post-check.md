---
description: Run the post-setup verification script (post.sh) after setup.sh finishes and highlight any failures.
---

# Post-setup verification

Verify that `setup.sh` completed successfully by running the post-install check.

## Steps

1. Ensure `post.sh` is executable:
   ```bash
   chmod +x post.sh
   ```

2. Run the verification:
   ```bash
   ./post.sh | tee /tmp/post-check.txt
   ```

3. Review the results section by section and report:

   **Tool versions** — list each tool with its version. Flag any `NOT FOUND` entries.

   **Docker** — check that:
   - `docker version` returns both client and server info (daemon is running)
   - `docker info` succeeds (permissions OK)
   - `/etc/docker/daemon.json` is present with log-rotation config
   - The current user is in the `docker` group
   - The sprite `dockerd` Service is registered (if on a sprite)

   **Git config** — confirm `user.name`, `user.email`, `init.defaultBranch`, and at least the `lg` alias are set.

   **SSH** — confirm `id_ed25519.pub` is present and `github.com` is in `known_hosts`.

   **GitHub SSH auth** — confirm the test returned "successfully authenticated".

   **rc sentinels** — confirm `dev-env-setup` sentinels are present in both `.bashrc` and `.zshrc`.

   **Smoke tests** — list each test result. Flag any `-` (failure) lines.

   **Disk** — report free space on `/` and `$HOME` usage.

4. Summarise:
   - **Pass**: all tools found, Docker reachable, smoke tests pass, sentinels present
   - **Partial**: list what failed with a suggested fix
   - **Fail**: describe the blocking issue and next steps
