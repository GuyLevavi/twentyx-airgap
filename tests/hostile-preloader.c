/* A local stand-in for the RunAI GPU-fractioning preloaders.
 *
 * The real interceptors (/runai/shared/pid/preloader.so and friends) crash
 * the opencode binary -- a Nix-store ELF with its own bundled runtime -- while
 * leaving ordinary binaries alone, which is exactly why the fix treats the
 * process and its children differently. This reproduces that failure SHAPE
 * without the proprietary .so: it aborts only the agent binary and is a no-op
 * everywhere else (system bash, system python, and the Nix userland).
 *
 * Build:  gcc -shared -fPIC -o hostile.so hostile-preloader.c
 * With LD_PRELOAD=hostile.so:
 *   - `/opt/twentyx/profile/bin/opencode --version` dies (SIGABRT)
 *   - bash, python, other Nix binaries run normally
 * which is what tests/test-container.sh asserts.
 */
#include <limits.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void __attribute__((constructor)) hostile_init(void) {
    char exe[PATH_MAX], base[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) {
        return;
    }
    exe[n] = '\0';
    if (strstr(exe, "/nix/store/") == NULL) {
        return;
    }
    snprintf(base, sizeof(base), "%s", exe);
    if (strstr(basename(base), "opencode") != NULL) {
        abort();
    }
}
