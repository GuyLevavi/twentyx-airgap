#!/usr/bin/env bash
# GPU test (opt-in; needs an NVIDIA host). Verifies what a CPU box cannot:
#
#   1. the image passes GPUs through and torch.cuda works in it at all
#   2. doctor's two-sided torch check (shell vs restored-preload env) is sane
#
# What this deliberately does NOT claim: whether CUDA survives a REAL GPU
# fractioning pod (where the RunAI preloaders must be restored for children)
# can only be observed in the gap -- the fractioning .so files are
# proprietary and not available locally. tests/test-container.sh covers the
# preload mechanics with a synthetic stand-in.
#
# Needs: nvidia-smi, a CDI-enabled podman, and a torch image (~6 GB, pulled
# once). One-time CDI setup, as root:
#
#   NixOS:  hardware.nvidia-container-toolkit.enable = true;   # then rebuild
#           nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
#   else:   nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
#
#   TEST_TORCH_IMAGE=pytorch/pytorch:latest ./tests/test-gpu-cuda.sh
#   TEST_TORCH_IMAGE=pytorch/pytorch:latest \
#     TEST_ASSEMBLED_IMAGE=<assembled workspace image> ./tests/test-gpu-cuda.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/lib.sh

need podman
need nvidia-smi

# Default: run the check inside the upstream torch image itself (proves the
# host's GPU container stack). Point TEST_ASSEMBLED_IMAGE at an
# assembled workspace image to prove OUR image passes GPUs through.
TORCH_IMAGE="${TEST_ASSEMBLED_IMAGE:-${TEST_TORCH_IMAGE:?set TEST_TORCH_IMAGE, e.g. pytorch/pytorch:latest}}"

say "host GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi failed" >&2; exit 1; }

run_gpu() {
    podman run --rm --tls-verify=false --user 10001:0 --tmpfs /data \
        --gpus all -e SESSION_USER=jensen "$@" "$TORCH_IMAGE"
}

say "torch.cuda inside the container"
check "torch.cuda.is_available() is true" \
    "run_gpu python -c 'import torch; assert torch.cuda.is_available()'"
check "a CUDA tensor actually computes on device" \
    "run_gpu python -c 'import torch; assert (torch.ones(4, device=\"cuda\") + 1).sum().item() == 8'"

if [ -n "$TEST_ASSEMBLED_IMAGE" ]; then
    say "assembled image: doctor's two-sided torch check"
    check "doctor reports torch.cuda true in both envs" \
        "run_gpu /opt/twentyx/libexec/doctor 2>&1 | grep 'torch.cuda' | grep -c True | grep -q 2"
fi

exit "$(summary && echo 0 || echo 1)"
