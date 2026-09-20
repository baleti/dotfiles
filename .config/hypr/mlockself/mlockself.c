// LD_PRELOAD shim: pin the hot processes of the alt-tab path in RAM.
//
// Alt-tab is used every few hours, so under memory pressure the kernel has
// long since swapped out Hyprland's and Quickshell's pages by the time it is
// used, and the first press pays for hundreds of swap-ins (measured cold
// start: ~12s). No amount of UI restructuring helps, because the stall is
// before any of our code runs. Locking the two processes (~120MB + ~500MB)
// keeps them resident.
//
// MCL_ONFAULT rather than plain mlockall(): plain MCL_CURRENT populates every
// mapping, including large reserved-but-untouched ones (Qt/Mesa arenas), and
// would balloon RSS. ONFAULT locks pages as they are first touched.
//
// Only acts in processes whose comm is in MLOCKSELF_COMMS (default
// "Hyprland,qs"), so it can sit in the whole session's environment; a matching
// process removes LD_PRELOAD from its own environment, so nothing it spawns
// loads the shim or gets locked.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#ifndef MCL_ONFAULT
#define MCL_ONFAULT 4
#endif

__attribute__((constructor)) static void mlockself_init(void) {
    char comm[32] = {0};
    FILE *f = fopen("/proc/self/comm", "r");
    if (!f)
        return;
    if (!fgets(comm, sizeof comm, f))
        comm[0] = 0;
    fclose(f);
    comm[strcspn(comm, "\n")] = 0;

    const char *env = getenv("MLOCKSELF_COMMS");
    char list[256];
    snprintf(list, sizeof list, "%s", env ? env : "Hyprland,qs");
    int match = 0;
    for (char *save, *tok = strtok_r(list, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
        if (strcmp(tok, comm) == 0)
            match = 1;
    if (!match)
        return;

    unsetenv("LD_PRELOAD");
    if (mlockall(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT) != 0)
        perror("mlockself: mlockall");
}
