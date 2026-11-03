// vidle IDLE_MS MAX_MS
// Waits until the seat has had no input for IDLE_MS (ext-idle-notify-v1, the input-only variant
// that idle inhibitors such as a playing video do not hold off), for at most MAX_MS. Prints the
// milliseconds waited and exits 0 when idle, 4 on timeout, 1 when the compositor lacks the
// protocol, 2 on bad usage.
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "ext-idle-notify-v1-client-protocol.h"

static struct ext_idle_notifier_v1 *notifier;
static struct wl_seat *seat;
static uint32_t notifier_ver;
static int idle;

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    if (!strcmp(iface, ext_idle_notifier_v1_interface.name)) {
        notifier_ver = ver < 2 ? ver : 2;
        notifier = wl_registry_bind(r, name, &ext_idle_notifier_v1_interface, notifier_ver);
    } else if (!strcmp(iface, "wl_seat") && !seat)
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener reg_listener = {global, global_remove};

static void idled(void *d, struct ext_idle_notification_v1 *n) { idle = 1; }
static void resumed(void *d, struct ext_idle_notification_v1 *n) { idle = 0; }
static const struct ext_idle_notification_v1_listener note_listener = {idled, resumed};

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: vidle IDLE_MS MAX_MS\n"); return 2; }
    char *e1, *e2;
    long idle_ms = strtol(argv[1], &e1, 10), max_ms = strtol(argv[2], &e2, 10);
    if (*e1 || *e2 || idle_ms < 0 || max_ms < 0) { fprintf(stderr, "usage: vidle IDLE_MS MAX_MS\n"); return 2; }
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "vidle: no Wayland display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!notifier || !seat) { fprintf(stderr, "vidle: compositor lacks ext_idle_notifier_v1\n"); return 1; }
    struct ext_idle_notification_v1 *n = notifier_ver >= 2
        ? ext_idle_notifier_v1_get_input_idle_notification(notifier, idle_ms, seat)
        : ext_idle_notifier_v1_get_idle_notification(notifier, idle_ms, seat);
    ext_idle_notification_v1_add_listener(n, &note_listener, NULL);
    long start = now_ms();
    wl_display_flush(dpy);
    while (!idle) {
        long left = start + max_ms - now_ms();
        if (left <= 0) { printf("%ld\n", now_ms() - start); return 4; }
        wl_display_flush(dpy);
        while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
        struct pollfd p = {wl_display_get_fd(dpy), POLLIN, 0};
        if (poll(&p, 1, left > 100 ? 100 : (int)left) > 0) wl_display_read_events(dpy);
        else wl_display_cancel_read(dpy);
        wl_display_dispatch_pending(dpy);
    }
    printf("%ld\n", now_ms() - start);
    return 0;
}
