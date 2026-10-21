// vptr X Y W H [left|right|middle|double | drag X2 Y2 | scroll N]
// Puts the pointer on layout pixel X,Y through the wlr virtual-pointer protocol, as one absolute
// jump over a W x H extent (the bounding box of all outputs, which is what niri maps an
// output-less virtual pointer to), then optionally clicks, drags with the left button held to
// X2,Y2, or scrolls N wheel notches (positive is down). No acceleration, no path across windows.
// A drag lives in one process because a virtual pointer's held button ends with the pointer.
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *mgr;

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
        mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, ver < 2 ? ver : 2);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener listener = {global, global_remove};

static uint32_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void click(struct wl_display *dpy, struct zwlr_virtual_pointer_v1 *p, uint32_t btn) {
    zwlr_virtual_pointer_v1_button(p, now_ms(), btn, WL_POINTER_BUTTON_STATE_PRESSED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
    usleep(60000);
    zwlr_virtual_pointer_v1_button(p, now_ms(), btn, WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
}

static void move(struct wl_display *dpy, struct zwlr_virtual_pointer_v1 *p, long x, long y, long w, long h) {
    zwlr_virtual_pointer_v1_motion_absolute(p, now_ms(), x, y, w, h);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
}

static void drag(struct wl_display *dpy, struct zwlr_virtual_pointer_v1 *p,
                 long x, long y, long x2, long y2, long w, long h) {
    zwlr_virtual_pointer_v1_button(p, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
    usleep(100000);
    // Steps, not one jump: toolkits start a drag only after seeing motion with the button held.
    for (int i = 1; i <= 20; i++) {
        move(dpy, p, x + (x2 - x) * i / 20, y + (y2 - y) * i / 20, w, h);
        usleep(15000);
    }
    usleep(100000);
    zwlr_virtual_pointer_v1_button(p, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(dpy);
}

static void scroll(struct wl_display *dpy, struct zwlr_virtual_pointer_v1 *p, int n) {
    int step = n < 0 ? -1 : 1;
    for (int i = 0; i != n; i += step) {
        zwlr_virtual_pointer_v1_axis_source(p, WL_POINTER_AXIS_SOURCE_WHEEL);
        zwlr_virtual_pointer_v1_axis_discrete(p, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
                                              wl_fixed_from_int(15 * step), step);
        zwlr_virtual_pointer_v1_frame(p);
        wl_display_roundtrip(dpy);
        usleep(30000);
    }
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: vptr X Y W H [left|right|middle|double | drag X2 Y2 | scroll N]\n");
        return 2;
    }
    long x = strtol(argv[1], 0, 10), y = strtol(argv[2], 0, 10);
    long w = strtol(argv[3], 0, 10), h = strtol(argv[4], 0, 10);
    if (x < 0 || y < 0 || x >= w || y >= h) {
        fprintf(stderr, "vptr: %ld,%ld is outside the %ldx%ld layout\n", x, y, w, h);
        return 2;
    }
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "vptr: no Wayland display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &listener, NULL);
    wl_display_roundtrip(dpy);
    if (!mgr) { fprintf(stderr, "vptr: compositor lacks zwlr_virtual_pointer_manager_v1\n"); return 1; }

    struct zwlr_virtual_pointer_v1 *p = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, NULL);
    move(dpy, p, x, y, w, h);

    const char *a = argc > 5 ? argv[5] : "";
    if (!strcmp(a, "left")) click(dpy, p, BTN_LEFT);
    else if (!strcmp(a, "right")) click(dpy, p, BTN_RIGHT);
    else if (!strcmp(a, "middle")) click(dpy, p, BTN_MIDDLE);
    else if (!strcmp(a, "double")) { click(dpy, p, BTN_LEFT); usleep(80000); click(dpy, p, BTN_LEFT); }
    else if (!strcmp(a, "drag") && argc > 7) {
        long x2 = strtol(argv[6], 0, 10), y2 = strtol(argv[7], 0, 10);
        if (x2 < 0 || y2 < 0 || x2 >= w || y2 >= h) { fprintf(stderr, "vptr: drag end outside the layout\n"); return 2; }
        drag(dpy, p, x, y, x2, y2, w, h);
    }
    else if (!strcmp(a, "scroll") && argc > 6) scroll(dpy, p, (int)strtol(argv[6], 0, 10));
    else if (*a) { fprintf(stderr, "vptr: unknown action %s\n", a); return 2; }

    zwlr_virtual_pointer_v1_destroy(p);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
