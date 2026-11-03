// hold: keeps one virtual pointer alive until killed. A headless sway seat has no pointer device,
// so without this it drops its pointer capability when vptr exits and draws no cursor.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *mgr;
static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
        mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener listener = {global, global_remove};

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) return 1;
    wl_registry_add_listener(wl_display_get_registry(dpy), &listener, NULL);
    wl_display_roundtrip(dpy);
    if (!mgr) return 1;
    zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, NULL);
    wl_display_roundtrip(dpy);
    puts("ready");
    fflush(stdout);
    for (;;) pause();
}
