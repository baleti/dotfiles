// LD_PRELOAD shim: pin the hot process's *steady-state* memory in RAM, once.
//
// Alt-tab is used every few hours, so under memory pressure the kernel has
// long since swapped out Hyprland's/Quickshell's pages by the time it is
// used, and the first press pays for hundreds of swap-ins (measured cold
// start: ~12s). No amount of UI restructuring helps, because the stall is
// before any of our code runs.
//
// First version of this (2026-09-20, mlockall(MCL_CURRENT|MCL_FUTURE|ONFAULT)
// at process start) was wrong: MCL_FUTURE locks every mapping the process
// EVER makes afterwards, forever, including one-off transient stuff like
// alt-tab's own thumbnail capture buffers. Over 64h uptime that grew
// Quickshell's locked memory to 2.8GB on a box that runs at ~29/31GB used
// with 33GB in swap, and locked pages can't be reclaimed by anyone -- so it
// was trading an occasional bounded cold-start stall for an ever-growing,
// permanent memory squeeze on the whole session (plausible cause of
// "stutters a few moments after opening it", reported 2026-09-23).
//
// Fix: lock only MCL_CURRENT, once, after a delay long enough for the
// process's real steady-state working set to have loaded (Quickshell's
// QML/JS engine warming up; Hyprland's own startup). No MCL_FUTURE, and the
// lock is never reissued, so later transient allocations (thumbnails, IPC
// buffers) stay freely swappable like normal memory. The delay runs on a
// detached thread so it doesn't block the process's own startup.
//
// MCL_ONFAULT rather than plain mlockall(): plain MCL_CURRENT populates every
// mapping, including large reserved-but-untouched ones (Qt/Mesa arenas), and
// would balloon RSS. ONFAULT locks pages as they are first touched, so only
// what actually gets used ends up resident.
//
// Only acts in processes whose comm is in MLOCKSELF_COMMS (default
// "Hyprland,qs"), so it can sit in the whole session's environment; a matching
// process removes LD_PRELOAD from its own environment, so nothing it spawns
// loads the shim or gets locked.
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#ifndef MCL_ONFAULT
#define MCL_ONFAULT 4
#endif

// How long to let the process warm up before taking the one-shot lock.
// Default covers Quickshell loading/compiling all of shell.qml's imports
// (winswitch included -- it's a singleton + always-active view, not lazily
// instantiated on first Alt+Tab) and Hyprland finishing its own startup.
#define DEFAULT_DELAY_MS 15000

static void *lock_after_delay(void *arg) {
    long delay_ms = (long)(size_t)arg;
    struct timespec ts = { .tv_sec = delay_ms / 1000, .tv_nsec = (delay_ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
    if (mlockall(MCL_CURRENT | MCL_ONFAULT) != 0)
        perror("mlockself: mlockall");
    return NULL;
}

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

    long delay_ms = DEFAULT_DELAY_MS;
    const char *delay_env = getenv("MLOCKSELF_DELAY_MS");
    if (delay_env && *delay_env)
        delay_ms = atol(delay_env);

    unsetenv("LD_PRELOAD");
    unsetenv("MLOCKSELF_DELAY_MS");

    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&tid, &attr, lock_after_delay, (void *)(size_t)delay_ms) != 0) {
        // Fallback: lock immediately rather than not at all.
        if (mlockall(MCL_CURRENT | MCL_ONFAULT) != 0)
            perror("mlockself: mlockall (fallback)");
    }
    pthread_attr_destroy(&attr);
}
