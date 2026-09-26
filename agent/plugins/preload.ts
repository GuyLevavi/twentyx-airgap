/**
 * RunAI GPU-fractioning preloader compensation for opencode.
 *
 * The problem, in two halves:
 *
 *   1. RunAI injects GPU-fractioning .so files via LD_PRELOAD. These crash the
 *      opencode process itself.
 *   2. The original preload is what makes CUDA work -- strip it everywhere and
 *      torch.cuda.is_available() goes False in every command the agent runs.
 *
 * libexec/run-opencode neutralizes LD_PRELOAD for the opencode process and
 * stashes the original in PRELOAD_ORIGINAL. This plugin puts it back on
 * every shell execution (agent tools and user terminals), so opencode runs
 * clean while everything it spawns sees exactly what an interactive shell
 * sees.
 *
 * Belt and suspenders: agent/restore-preload.sh (via BASH_ENV) does the same
 * for any bash the plugin path does not cover. Disable both with
 * PRELOAD_RESTORE_AGENT_BASH=0.
 */

export const Preload = async () => {
  const stashed = process.env.PRELOAD_ORIGINAL
  const enabled = process.env.PRELOAD_RESTORE_AGENT_BASH !== "0"

  // Nothing was stripped -> nothing to restore. Stay a no-op so the plugin is
  // safe on a workstation or a non-fractioned pod.
  if (!enabled || !stashed) return {}

  return {
    "shell.env": async (_input, output) => {
      // Byte-for-byte. Do not try to reconstruct or normalize this value: the
      // exact string is what the CUDA stack was configured against.
      output.env.LD_PRELOAD = stashed
    },
  }
}
