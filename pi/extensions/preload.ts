/**
 * RunAI GPU-fractioning preloader compensation.
 *
 * The problem, in two halves:
 *
 *   1. RunAI injects GPU-fractioning .so files via LD_PRELOAD. These segfaulted
 *      OpenCode, and are assumed to threaten any Node process here.
 *   2. Clearing LD_PRELOAD fixes the agent but breaks CUDA in everything the
 *      agent runs -- torch.cuda.is_available() goes False under the agent while
 *      working fine in an interactive shell. That failure mode is confusing and
 *      expensive, because it looks like a broken GPU rather than a broken env.
 *
 * These pull in opposite directions only if you treat the process and its
 * children as one environment. They are not:
 *
 *   libexec/airgap-pi  strips LD_PRELOAD, stashes it in AIRGAP_ORIG_LD_PRELOAD
 *   this extension     restores the stash for every bash tool invocation
 *
 * Node runs clean. Children run exactly as an interactive shell does.
 *
 * Self-disabling: with no stash, or with AIRGAP_PRELOAD_RESTORE=0, the hook is
 * a no-op and the built-in bash tool behavior is unchanged. So if pi turns out
 * to tolerate the preloaders, nothing here needs to be removed or forked.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashTool } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const stashed = process.env.AIRGAP_ORIG_LD_PRELOAD;
  const enabled = process.env.AIRGAP_PRELOAD_RESTORE !== "0";

  // Nothing was stripped -> nothing to restore. Leave the built-in tool alone.
  if (!enabled || stashed === undefined || stashed === "") return;

  const bashTool = createBashTool(process.cwd(), {
    spawnHook: ({ command, cwd, env }) => ({
      command,
      cwd,
      // Byte-for-byte restoration. Do not try to reconstruct or normalize this
      // value: the exact string is what the CUDA stack was configured against.
      env: { ...env, LD_PRELOAD: stashed },
    }),
  });

  pi.registerTool({
    ...bashTool,
    execute: (id, params, signal, onUpdate) =>
      bashTool.execute(id, params, signal, onUpdate),
  });
}
