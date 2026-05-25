#!/bin/sh
# Nix setup script for the `nix` target, run by the sproot nix module after install
# with the nix profile already sourced (nix, NIX_PATH and the SSL cert env are set).
#
# This is the escape hatch for anything the declarative `packages:` list in
# sproot.yaml does not cover: applying a flake, enabling a channel, installing
# home-manager, etc. It runs whenever the nix phase runs, so keep it idempotent.
set -eu

# Example: install a tool from a flake only when it is missing.
# if ! command -v fastfetch >/dev/null 2>&1; then
#   nix profile install nixpkgs#fastfetch
# fi

# Example: apply a personal home-manager flake.
# nix run home-manager/master -- switch --flake "$HOME/repos/dotfiles"

echo "nix setup script complete"
