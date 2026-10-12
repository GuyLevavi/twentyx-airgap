# env/ -- cluster files for WSL

Files that differ per site and rotate, so they are never baked into the
closure. `wsl/link.sh` stages the known names into `/var/lib/airgap-env/` and
restarts `airgap-ca`:

- `ca-bundle.crt` -- the internal CA (PEM), appended to the system bundle.
- `pip.conf` -- staged as-is; Python index settings live wherever the site
  keeps them (e.g. a `uv.toml` in `dotfiles/`).

Pods do not read this directory: their base image or the env-injection mount
(`/opt/airgap-env`, `/data/.airgap-env`) supplies CA and index config.
