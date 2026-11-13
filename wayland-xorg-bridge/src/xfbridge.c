/*
 * xfbridge - present a headless Xorg screen as a native Wayland surface.
 *
 * Why
 * ---
 * On legacy NVIDIA drivers (Kepler/Maxwell and other 470.x-era GPUs, EGLStreams
 * only) an X11 app cannot get hardware acceleration inside a Wayland session:
 * Xwayland needs GBM (driver >= 495) or the EGLStream glamor backend (removed
 * from Xwayland 24.1, dropped by Mutter >= 51).
 *
 * Turn it around:
 *
 *     app -> headless Xorg on the NVIDIA DDX   (full HW accel, no Xwayland)
 *         -> xfbridge                          (reads the X framebuffer)
 *         -> native Wayland surface            (your compositor)
 *
 * The app renders on the GPU directly. Only finished pixels cross the boundary,
 * and only the damaged rectangles.
 *
 * How
 * ---
 *  - XDamage tracks changed regions of the root window; MIT-SHM pulls the
 *    changed bounding box out of the server in one call per frame.
 *  - Pixels are memcpy'd into wl_shm buffers (triple buffered) with per-buffer
 *    damage synchronisation, so no stale region can ever reach the compositor.
 *  - The XFX cursor (a hardware overlay, not in the framebuffer) is
 *    alpha-blended in and the compositor cursor is hidden, so you see the real
 *    X cursor of the app.
 *  - Pointer/keyboard from the Wayland seat are injected into X with XTEST.
 *    Wayland keycodes are evdev; Xorg's evdev driver uses evdev+8.
 *
 * Usage:
 *   xfbridge --x-display :1 [--fullscreen] [--fps 60] [--no-input] [-v]
 *   xfbridge --x-display :1 --frames 20 --dump-frame /tmp/f.ppm   # self-test
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/shm.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <xcb/damage.h>
#include <xcb/shm.h>
#include <xcb/xcb.h>
#include <xcb/xfixes.h>
#include <xcb/xtest.h>

#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

#ifndef WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
#define WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION 0
#endif
#ifndef WL_POINTER_AXIS_VALUE120_SINCE_VERSION
#define WL_POINTER_AXIS_VALUE120_SINCE_VERSION 0
#endif

#define MAX_RECTS 96
#define MAX_BUFFERS 3
#define KEYCODE_OFFSET_DEFAULT 8

/* ------------------------------------------------------------------ rects */

struct rect {
	int x, y, w, h;
};

struct rectlist {
	struct rect r[MAX_RECTS];
	int n;
	int overflow;
};

static void rl_clear(struct rectlist *l)
{
	l->n = 0;
	l->overflow = 0;
}

static bool rl_empty(const struct rectlist *l)
{
	return l->n == 0;
}

static struct rect rect_clip(struct rect r, int w, int h)
{
	int x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h;
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x1 > w) x1 = w;
	if (y1 > h) y1 = h;
	if (x1 < x0) x1 = x0;
	if (y1 < y0) y1 = y0;
	r.x = x0; r.y = y0; r.w = x1 - x0; r.h = y1 - y0;
	return r;
}

static void rl_add(struct rectlist *l, struct rect r)
{
	if (r.w <= 0 || r.h <= 0)
		return;
	for (int i = 0; i < l->n; i++) {
		struct rect *o = &l->r[i];
		if (o->x <= r.x && o->y <= r.y &&
		    o->x + o->w >= r.x + r.w && o->y + o->h >= r.y + r.h)
			return;                       /* already covered */
		if (r.x <= o->x && r.y <= o->y &&
		    r.x + r.w >= o->x + o->w && r.y + r.h >= o->y + o->h) {
			*o = r;                       /* absorb */
			return;
		}
	}
	if (l->n < MAX_RECTS) {
		l->r[l->n++] = r;
	} else {
		l->overflow = 1;
	}
}

static struct rect rl_bbox(const struct rectlist *l)
{
	struct rect b = { 0, 0, 0, 0 };
	if (l->n == 0)
		return b;
	int x0 = l->r[0].x, y0 = l->r[0].y;
	int x1 = x0 + l->r[0].w, y1 = y0 + l->r[0].h;
	for (int i = 1; i < l->n; i++) {
		if (l->r[i].x < x0) x0 = l->r[i].x;
		if (l->r[i].y < y0) y0 = l->r[i].y;
		if (l->r[i].x + l->r[i].w > x1) x1 = l->r[i].x + l->r[i].w;
		if (l->r[i].y + l->r[i].h > y1) y1 = l->r[i].y + l->r[i].h;
	}
	b.x = x0; b.y = y0; b.w = x1 - x0; b.h = y1 - y0;
	return b;
}

static void rl_flatten(struct rectlist *l)
{
	if (l->n > 1 && !l->overflow) {
		/* keep small sets precise; fold only when it grows expensive */
		int area = 0;
		for (int i = 0; i < l->n; i++)
			area += l->r[i].w * l->r[i].h;
		struct rect b = rl_bbox(l);
		if (area * 3 > b.w * b.h) {           /* lots of overlap: use bbox */
			l->n = 0;
			l->r[l->n++] = b;
		}
		return;
	}
	if (!l->overflow)
		return;
	struct rect b = rl_bbox(l);
	l->n = 0;
	l->overflow = 0;
	if (b.w > 0 && b.h > 0)
		l->r[l->n++] = b;
}

/* --------------------------------------------------------------- globals */

struct buffer {
	struct wl_buffer *wl;
	uint8_t *data;
	size_t size;
	bool busy;
	bool has_cursor;
	struct rect cursor;
	/* damage that happened since this buffer was last updated. Kept per
	 * buffer: a buffer that is reused later must still receive everything
	 * that changed in the meantime, otherwise stale pixels reach the
	 * compositor. */
	struct rectlist pending;
};

struct state {
	/* wayland */
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct xdg_wm_base *wm_base;
	struct wl_seat *seat;
	struct wl_pointer *pointer;
	struct wl_keyboard *keyboard;
	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct wl_callback *frame_cb;
	bool frame_pending;
	bool configured;

	struct buffer buf[MAX_BUFFERS];
	int nbuf;
	int last_buf;

	/* X */
	xcb_connection_t *xc;
	xcb_screen_t *screen;
	xcb_drawable_t root;
	int damage_ev_base;
	xcb_damage_damage_t damage;
	bool use_shm;
	xcb_shm_seg_t shmseg;
	int shm_id;
	uint8_t *shm_data;
	size_t shm_size;
	bool use_xfixes;
	bool use_xtest;

	/* bookkeeping */
	int width, height;
	unsigned long stat_frames, stat_bytes, total_frames;
	bool running;

	/* options */
	bool opt_fullscreen;
	bool opt_input;
	bool opt_verbose;
	bool opt_no_damage;
	int opt_fps;
	int opt_frames;
	int opt_keymap_offset;
	const char *opt_dump;
	const char *opt_title;
};

static struct state S = {
	.opt_input = true,
	.opt_fps = 60,
	.opt_keymap_offset = KEYCODE_OFFSET_DEFAULT,
	.opt_title = "X11 (xfbridge)",
	.shm_id = -1,
};

static void die(const char *msg)
{
	fprintf(stderr, "xfbridge: %s: %s\n", msg, strerror(errno));
	exit(1);
}

static void logv(const char *fmt, ...)
{
	if (!S.opt_verbose)
		return;
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "xfbridge: ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* ------------------------------------------------------------------- shm */

static int create_anon_file(size_t size)
{
	int fd = memfd_create("xfbridge", MFD_CLOEXEC);
	if (fd < 0) {
		char tmpl[] = "/tmp/xfbridge-XXXXXX";
		fd = mkostemp(tmpl, O_CLOEXEC);
		if (fd < 0)
			die("cannot create shared memory file");
		unlink(tmpl);
	}
	if (ftruncate(fd, (off_t)size) < 0)
		die("ftruncate");
	return fd;
}

static void buffer_release(void *data, struct wl_buffer *wl_buffer)
{
	struct buffer *b = data;
	(void)wl_buffer;
	b->busy = false;
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static void create_buffers(void)
{
	size_t stride = (size_t)S.width * 4;
	size_t size = stride * (size_t)S.height;

	for (int i = 0; i < MAX_BUFFERS; i++) {
		int fd = create_anon_file(size);
		uint8_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, 0);
		if (data == MAP_FAILED)
			die("mmap");
		struct wl_shm_pool *pool = wl_shm_create_pool(S.shm, fd, (int)size);
		struct wl_buffer *wb = wl_shm_pool_create_buffer(
			pool, 0, S.width, S.height, (int)stride,
			WL_SHM_FORMAT_XRGB8888);
		wl_shm_pool_destroy(pool);
		close(fd);
		if (!wb)
			die("wl_shm_pool_create_buffer");

		S.buf[i].wl = wb;
		S.buf[i].data = data;
		S.buf[i].size = size;
		S.buf[i].busy = false;
		S.buf[i].has_cursor = false;
		S.buf[i].pending = (struct rectlist){ .n = 0, .overflow = 0 };
		wl_buffer_add_listener(wb, &buffer_listener, &S.buf[i]);
	}
	S.nbuf = MAX_BUFFERS;
}

/* --------------------------------------------------------------- wayland */

static void wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_base_ping };

static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial)
{
	(void)data;
	xdg_surface_ack_configure(xs, serial);
	S.configured = true;
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *tl, int32_t w,
			       int32_t h, struct wl_array *states)
{
	(void)data; (void)tl; (void)states;
	logv("toplevel configure %dx%d (buffer is %dx%d)", w, h, S.width, S.height);
}

static void toplevel_close(void *data, struct xdg_toplevel *tl)
{
	(void)data; (void)tl;
	S.running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
};

static void frame_done(void *data, struct wl_callback *cb, uint32_t t)
{
	(void)data; (void)t;
	wl_callback_destroy(cb);
	S.frame_cb = NULL;
	S.frame_pending = false;
}

static const struct wl_callback_listener frame_listener = { .done = frame_done };

/* ----------------------------------------------------------------- input */

static void xinject_key(uint32_t key, bool press)
{
	if (!S.opt_input || !S.use_xtest)
		return;
	int kc = (int)key + S.opt_keymap_offset;
	if (kc < 8 || kc > 255)
		return;
	xcb_test_fake_input(S.xc, press ? XCB_KEY_PRESS : XCB_KEY_RELEASE,
			    (uint8_t)kc, XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0);
	xcb_flush(S.xc);
}

static void xinject_motion(int x, int y)
{
	if (!S.opt_input || !S.use_xtest)
		return;
	xcb_test_fake_input(S.xc, XCB_MOTION_NOTIFY, 0, XCB_CURRENT_TIME,
			    XCB_NONE, (int16_t)x, (int16_t)y, 0);
	xcb_flush(S.xc);
}

static void xinject_button(uint32_t wl_button, bool press)
{
	if (!S.opt_input || !S.use_xtest)
		return;
	if (wl_button < 0x110 || wl_button > 0x117)
		return;                              /* BTN_LEFT..BTN_TASK only */
	uint8_t xb = (uint8_t)(wl_button - 0x110 + 1);
	xcb_test_fake_input(S.xc, press ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE,
			    xb, XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0);
	xcb_flush(S.xc);
}

static void xinject_wheel(bool up, bool horizontal, bool negative)
{
	if (!S.opt_input || !S.use_xtest)
		return;
	int8_t b = (int8_t)((horizontal ? 6 : 4) + (negative ? 1 : 0));
	xcb_test_fake_input(S.xc, up ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE,
			    b, XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0);
	xcb_flush(S.xc);
}

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface, wl_fixed_t sx, wl_fixed_t sy)
{
	(void)data; (void)surface;
	if (p)
		wl_pointer_set_cursor(p, serial, NULL, 0, 0);   /* hide compositor cursor */
	xinject_motion(wl_fixed_to_int(sx), wl_fixed_to_int(sy));
}

static void pointer_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf)
{ (void)d; (void)p; (void)s; (void)sf; }

static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t,
			   wl_fixed_t sx, wl_fixed_t sy)
{ (void)d; (void)p; (void)t; xinject_motion(wl_fixed_to_int(sx), wl_fixed_to_int(sy)); }

static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial,
			   uint32_t t, uint32_t button, uint32_t state)
{
	(void)d; (void)p; (void)serial; (void)t;
	xinject_button(button, state == WL_POINTER_BUTTON_STATE_PRESSED);
}

static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t axis,
			 wl_fixed_t value)
{
	(void)d; (void)p; (void)t;
	bool horizontal = axis != WL_POINTER_AXIS_VERTICAL_SCROLL;
	double v = wl_fixed_to_double(value);
	int steps = (int)((v < 0 ? -v : v) / 15.0);
	if (steps < 1)
		steps = 1;
	for (int i = 0; i < steps; i++) {
		xinject_wheel(true, horizontal, v > 0);
		xinject_wheel(false, horizontal, v > 0);
	}
}

static void pointer_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void pointer_axis_source(void *d, struct wl_pointer *p, uint32_t s)
{ (void)d; (void)p; (void)s; }
static void pointer_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a)
{ (void)d; (void)p; (void)t; (void)a; }
static void pointer_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v)
{ (void)d; (void)p; (void)a; (void)v; }
#if WL_POINTER_AXIS_VALUE120_SINCE_VERSION
static void pointer_axis_value120(void *d, struct wl_pointer *p, uint32_t a, int32_t v)
{ (void)d; (void)p; (void)a; (void)v; }
#endif
#if WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
static void pointer_axis_relative_direction(void *d, struct wl_pointer *p, uint32_t a, uint32_t dir)
{ (void)d; (void)p; (void)a; (void)dir; }
#endif

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
	.frame = pointer_frame,
	.axis_source = pointer_axis_source,
	.axis_stop = pointer_axis_stop,
	.axis_discrete = pointer_axis_discrete,
#if WL_POINTER_AXIS_VALUE120_SINCE_VERSION
	.axis_value120 = pointer_axis_value120,
#endif
#if WL_POINTER_AXIS_RELATIVE_DIRECTION_SINCE_VERSION
	.axis_relative_direction = pointer_axis_relative_direction,
#endif
};

static void kb_keymap(void *d, struct wl_keyboard *kb, uint32_t format, int fd, uint32_t size)
{
	(void)d; (void)kb; (void)format; (void)size;
	if (fd >= 0)
		close(fd);        /* raw evdev keycodes are injected, map not needed */
}

static void kb_enter(void *d, struct wl_keyboard *kb, uint32_t s, struct wl_surface *sf,
		     struct wl_array *keys)
{ (void)d; (void)kb; (void)s; (void)sf; (void)keys; }

static void kb_leave(void *d, struct wl_keyboard *kb, uint32_t s, struct wl_surface *sf)
{ (void)d; (void)kb; (void)s; (void)sf; }

static void kb_key(void *d, struct wl_keyboard *kb, uint32_t serial, uint32_t t,
		   uint32_t key, uint32_t state)
{
	(void)d; (void)kb; (void)serial; (void)t;
	xinject_key(key, state == WL_KEYBOARD_KEY_STATE_PRESSED);
}

static void kb_modifiers(void *d, struct wl_keyboard *kb, uint32_t s, uint32_t dep,
			 uint32_t lat, uint32_t lock, uint32_t grp)
{ (void)d; (void)kb; (void)s; (void)dep; (void)lat; (void)lock; (void)grp; }

static void kb_repeat(void *d, struct wl_keyboard *kb, int32_t rate, int32_t delay)
{ (void)d; (void)kb; (void)rate; (void)delay; }

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap = kb_keymap,
	.enter = kb_enter,
	.leave = kb_leave,
	.key = kb_key,
	.modifiers = kb_modifiers,
	.repeat_info = kb_repeat,
};

static void seat_capabilities(void *d, struct wl_seat *seat, uint32_t caps)
{
	(void)d;
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && !S.pointer) {
		S.pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(S.pointer, &pointer_listener, NULL);
	}
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !S.keyboard) {
		S.keyboard = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(S.keyboard, &keyboard_listener, NULL);
	}
}

static void seat_name(void *d, struct wl_seat *seat, const char *name)
{ (void)d; (void)seat; (void)name; }

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void registry_global(void *d, struct wl_registry *reg, uint32_t name,
			    const char *iface, uint32_t version)
{
	(void)d;
	if (strcmp(iface, wl_compositor_interface.name) == 0)
		S.compositor = wl_registry_bind(reg, name, &wl_compositor_interface,
						version < 4 ? version : 4);
	else if (strcmp(iface, wl_shm_interface.name) == 0)
		S.shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
		S.wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(S.wm_base, &wm_base_listener, NULL);
	} else if (strcmp(iface, wl_seat_interface.name) == 0) {
		S.seat = wl_registry_bind(reg, name, &wl_seat_interface,
					  version < 7 ? version : 7);
		wl_seat_add_listener(S.seat, &seat_listener, NULL);
	}
}

static void registry_remove(void *d, struct wl_registry *reg, uint32_t name)
{ (void)d; (void)reg; (void)name; }

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

/* ---------------------------------------------------------------- X init */

static bool x_init(void)
{
	int screen_num = 0;
	S.xc = xcb_connect(NULL, &screen_num);
	if (xcb_connection_has_error(S.xc)) {
		fprintf(stderr, "xfbridge: cannot open X display %s\n",
			getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
		return false;
	}
	xcb_screen_iterator_t it = xcb_setup_roots_iterator(xcb_get_setup(S.xc));
	for (int i = 0; i < screen_num; i++)
		xcb_screen_next(&it);
	S.screen = it.data;
	if (!S.screen) {
		fprintf(stderr, "xfbridge: no X screen\n");
		return false;
	}
	S.root = S.screen->root;
	S.width = S.screen->width_in_pixels;
	S.height = S.screen->height_in_pixels;

	const xcb_query_extension_reply_t *ext;

	ext = xcb_get_extension_data(S.xc, &xcb_shm_id);
	if (ext && ext->present) {
		xcb_shm_query_version_reply_t *v =
			xcb_shm_query_version_reply(S.xc, xcb_shm_query_version(S.xc), NULL);
		if (v) { S.use_shm = true; free(v); }
	}
	if (S.use_shm) {
		S.shm_size = (size_t)S.width * (size_t)S.height * 4;
		S.shm_id = shmget(IPC_PRIVATE, S.shm_size, IPC_CREAT | 0600);
		if (S.shm_id < 0) {
			S.use_shm = false;
		} else {
			S.shm_data = shmat(S.shm_id, NULL, 0);
			if (S.shm_data == (void *)-1) {
				shmctl(S.shm_id, IPC_RMID, NULL);
				S.shm_id = -1;
				S.shm_data = NULL;
				S.use_shm = false;
			} else {
				S.shmseg = xcb_generate_id(S.xc);
				xcb_shm_attach(S.xc, S.shmseg, S.shm_id, 0);
			}
		}
	}
	if (!S.use_shm)
		logv("MIT-SHM unavailable: falling back to XGetImage");

	ext = xcb_get_extension_data(S.xc, &xcb_damage_id);
	if (ext && ext->present) {
		xcb_damage_query_version_reply_t *v =
			xcb_damage_query_version_reply(S.xc,
				xcb_damage_query_version(S.xc, XCB_DAMAGE_MAJOR_VERSION,
							 XCB_DAMAGE_MINOR_VERSION), NULL);
		if (v) {
			S.damage_ev_base = ext->first_event;
			S.damage = xcb_generate_id(S.xc);
			xcb_damage_create(S.xc, S.damage, S.root,
					  XCB_DAMAGE_REPORT_LEVEL_NON_EMPTY);
			free(v);
		}
	}

	ext = xcb_get_extension_data(S.xc, &xcb_xfixes_id);
	if (ext && ext->present) {
		xcb_xfixes_query_version_reply_t *v =
			xcb_xfixes_query_version_reply(S.xc,
				xcb_xfixes_query_version(S.xc, 1, 0), NULL);
		if (v) { S.use_xfixes = true; free(v); }
	}

	ext = xcb_get_extension_data(S.xc, &xcb_test_id);
	if (ext && ext->present) {
		xcb_test_get_version_reply_t *v =
			xcb_test_get_version_reply(S.xc,
				xcb_test_get_version(S.xc, 2, 2), NULL);
		if (v) { S.use_xtest = true; free(v); }
	}

	xcb_flush(S.xc);
	logv("X screen %dx%d  shm=%d damage=%d xfixes=%d xtest=%d",
	     S.width, S.height, S.use_shm, S.damage_ev_base != 0,
	     S.use_xfixes, S.use_xtest);
	return true;
}

/* Pull a box out of the X server. Result must be released with cap_release(). */
struct capture {
	uint8_t *data;
	int stride;
	void *owner;      /* reply to free, or NULL for the persistent SHM area */
};

static bool x_capture(struct rect box, struct capture *cap)
{
	cap->data = NULL;
	cap->stride = 0;
	cap->owner = NULL;
	if (box.w <= 0 || box.h <= 0)
		return false;

	if (S.use_shm) {
		xcb_shm_get_image_cookie_t ck = xcb_shm_get_image(
			S.xc, S.root, (int16_t)box.x, (int16_t)box.y,
			(uint16_t)box.w, (uint16_t)box.h, ~0u,
			XCB_IMAGE_FORMAT_Z_PIXMAP, S.shmseg, 0);
		xcb_generic_error_t *err = NULL;
		xcb_shm_get_image_reply_t *rep = xcb_shm_get_image_reply(S.xc, ck, &err);
		free(err);
		if (rep) {
			free(rep);
			cap->data = S.shm_data;
			cap->stride = box.w * 4;
			return true;
		}
		logv("shm_get_image failed: disabling SHM");
		S.use_shm = false;
	}

	xcb_get_image_reply_t *r = xcb_get_image_reply(S.xc,
		xcb_get_image(S.xc, XCB_IMAGE_FORMAT_Z_PIXMAP, S.root,
			      (int16_t)box.x, (int16_t)box.y,
			      (uint16_t)box.w, (uint16_t)box.h, ~0u), NULL);
	if (!r)
		return false;
	cap->data = xcb_get_image_data(r);
	cap->stride = box.w * 4;
	cap->owner = r;
	return true;
}

static void cap_release(struct capture *cap)
{
	if (cap->owner)
		free(cap->owner);
	cap->owner = NULL;
	cap->data = NULL;
}

/* Cursor image: caller frees *owner. */
static bool x_cursor(struct rect *where, uint32_t **pixels, void **owner)
{
	*owner = NULL;
	*pixels = NULL;
	*where = (struct rect){ 0, 0, 0, 0 };
	if (!S.use_xfixes)
		return false;
	xcb_xfixes_get_cursor_image_reply_t *r =
		xcb_xfixes_get_cursor_image_reply(S.xc,
			xcb_xfixes_get_cursor_image(S.xc), NULL);
	if (!r)
		return false;
	if (r->width == 0 || r->height == 0) {
		free(r);
		return false;
	}
	where->x = (int)r->x - (int)r->xhot;
	where->y = (int)r->y - (int)r->yhot;
	where->w = (int)r->width;
	where->h = (int)r->height;
	*pixels = (uint32_t *)xcb_xfixes_get_cursor_image_cursor_image(r);
	*owner = r;
	return true;
}

/* --------------------------------------------------------- damage events */

static void drain_x_events(bool *dirty)
{
	xcb_generic_event_t *ev;
	while ((ev = xcb_poll_for_event(S.xc))) {
		uint8_t type = ev->response_type & 0x7f;
		if (S.damage_ev_base && type == S.damage_ev_base + XCB_DAMAGE_NOTIFY) {
			xcb_damage_notify_event_t *de = (xcb_damage_notify_event_t *)ev;
			struct rect r = { de->area.x, de->area.y,
					  de->area.width, de->area.height };
			struct rect cr = rect_clip(r, S.width, S.height);
			for (int i = 0; i < S.nbuf; i++)
				rl_add(&S.buf[i].pending, cr);
			xcb_damage_subtract(S.xc, de->damage, XCB_NONE, XCB_NONE);
			*dirty = true;
		} else if (type == 0) {          /* X error */
			xcb_generic_error_t *ge = (xcb_generic_error_t *)ev;
			logv("X error %d on request %d", ge->error_code, ge->major_code);
		}
		free(ev);
	}
	xcb_flush(S.xc);
}

/* ------------------------------------------------------------- presenter */

static void copy_rect(uint8_t *dst, int dst_stride, const uint8_t *src,
		      int src_stride, struct rect r, struct rect box)
{
	int sx = r.x - box.x, sy = r.y - box.y;
	if (sx < 0 || sy < 0)
		return;
	for (int row = 0; row < r.h; row++)
		memcpy(dst + (size_t)(r.y + row) * dst_stride + (size_t)r.x * 4,
		       src + (size_t)(sy + row) * src_stride + (size_t)sx * 4,
		       (size_t)r.w * 4);
}

static void blend_cursor(uint8_t *dst, int stride, struct rect where, const uint32_t *px)
{
	struct rect c = rect_clip(where, S.width, S.height);
	for (int y = 0; y < c.h; y++) {
		uint8_t *d = dst + (size_t)(c.y + y) * stride + (size_t)c.x * 4;
		const uint32_t *s = px + (size_t)(c.y - where.y) * where.w +
				    (size_t)(c.x - where.x);
		for (int x = 0; x < c.w; x++) {
			uint32_t sp = s[x];              /* premultiplied ARGB */
			unsigned a = sp >> 24;
			if (a == 0)
				continue;
			uint32_t *dp = &((uint32_t *)d)[x];
			if (a == 0xff) {
				*dp = sp;
				continue;
			}
			uint32_t d0 = *dp;
			unsigned ia = 255 - a;
			unsigned r = ((sp >> 16) & 0xff) + (((d0 >> 16) & 0xff) * ia) / 255;
			unsigned g = ((sp >> 8) & 0xff) + (((d0 >> 8) & 0xff) * ia) / 255;
			unsigned b = (sp & 0xff) + ((d0 & 0xff) * ia) / 255;
			if (r > 255) r = 255;
			if (g > 255) g = 255;
			if (b > 255) b = 255;
			*dp = (0xffu << 24) | (r << 16) | (g << 8) | b;
		}
	}
}

static void damage_all(void)
{
	struct rect full = { 0, 0, S.width, S.height };
	for (int i = 0; i < S.nbuf; i++)
		rl_add(&S.buf[i].pending, full);
}

static bool present(void)
{
	if (!S.configured || S.frame_pending)
		return false;

	/* Prefer the free buffer with the least pending damage: that is usually
	 * the one the compositor just released, which needs the fewest copies. */
	struct buffer *b = NULL;
	long best = -1;
	for (int i = 0; i < S.nbuf; i++) {
		if (S.buf[i].busy)
			continue;
		long area = 1;
		if (S.buf[i].pending.n > 0) {
			struct rect bb = rl_bbox(&S.buf[i].pending);
			area = (long)bb.w * bb.h;
		}
		if (best < 0 || area < best) {
			best = area;
			b = &S.buf[i];
		}
	}
	if (!b)
		return false;        /* compositor holds every buffer: skip frame */

	rl_flatten(&b->pending);
	if (rl_empty(&b->pending) && !b->has_cursor)
		return false;        /* nothing changed for this buffer */

	struct rectlist work = { .n = 0, .overflow = 0 };
	for (int i = 0; i < b->pending.n; i++)
		rl_add(&work, b->pending.r[i]);
	if (b->has_cursor)
		rl_add(&work, rect_clip(b->cursor, S.width, S.height));

	struct rect crect;
	uint32_t *cpix = NULL;
	void *cowner = NULL;
	bool cursor = x_cursor(&crect, &cpix, &cowner);
	if (cursor)
		rl_add(&work, rect_clip(crect, S.width, S.height));

	rl_flatten(&work);
	struct rect box = rl_bbox(&work);
	if (box.w <= 0 || box.h <= 0) {
		free(cowner);
		return false;
	}

	struct capture cap;
	if (!x_capture(box, &cap)) {
		free(cowner);
		return false;
	}

	int dst_stride = S.width * 4;
	for (int i = 0; i < work.n; i++)
		copy_rect(b->data, dst_stride, cap.data, cap.stride, work.r[i], box);

	if (cursor) {
		blend_cursor(b->data, dst_stride, crect, cpix);
		b->has_cursor = true;
		b->cursor = crect;
	} else {
		b->has_cursor = false;
	}

	b->busy = true;
	wl_surface_attach(S.surface, b->wl, 0, 0);
	for (int i = 0; i < work.n; i++)
		wl_surface_damage_buffer(S.surface, work.r[i].x, work.r[i].y,
					 work.r[i].w, work.r[i].h);
	S.frame_cb = wl_surface_frame(S.surface);
	wl_callback_add_listener(S.frame_cb, &frame_listener, NULL);
	S.frame_pending = true;
	wl_surface_commit(S.surface);

	S.stat_bytes += (unsigned long)box.w * (unsigned long)box.h * 4;
	S.stat_frames++;

	cap_release(&cap);
	free(cowner);

	S.last_buf = (int)(b - S.buf);
	rl_clear(&b->pending);       /* this buffer is now fully in sync */
	return true;
}

static void stats(void)
{
	static struct timespec t0;
	struct timespec t1;
	clock_gettime(CLOCK_MONOTONIC, &t1);
	if (t0.tv_sec == 0) { t0 = t1; return; }
	double dt = (double)(t1.tv_sec - t0.tv_sec) +
		    (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
	if (dt < 5.0)
		return;
	fprintf(stderr, "xfbridge: %.1f fps  %.1f MB/s  (%lu frames total)\n",
		(double)S.stat_frames / dt, (double)S.stat_bytes / dt / 1e6,
		S.total_frames);
	t0 = t1;
	S.stat_frames = 0;
	S.stat_bytes = 0;
}

static bool dump_ppm(const char *path)
{
	int idx = S.last_buf;
	FILE *f = fopen(path, "wb");
	if (!f) {
		fprintf(stderr, "xfbridge: cannot write %s: %s\n", path, strerror(errno));
		return false;
	}
	fprintf(f, "P6\n%d %d\n255\n", S.width, S.height);
	uint8_t *d = S.buf[idx].data;
	uint8_t *row = malloc((size_t)S.width * 3);
	if (!row) { fclose(f); return false; }
	for (int y = 0; y < S.height; y++) {
		for (int x = 0; x < S.width; x++) {
			uint8_t *p = d + (size_t)y * S.width * 4 + (size_t)x * 4;
			row[x * 3 + 0] = p[2];   /* BGRX -> RGB */
			row[x * 3 + 1] = p[1];
			row[x * 3 + 2] = p[0];
		}
		fwrite(row, 1, (size_t)S.width * 3, f);
	}
	free(row);
	fclose(f);
	logv("wrote %s", path);
	return true;
}

/* ------------------------------------------------------------------- main */

static void on_signal(int sig) { (void)sig; S.running = false; }

static void usage(const char *argv0)
{
	fprintf(stderr,
"usage: %s [options] [--x-display :N]\n"
"  --x-display DISP     X display to mirror (default: $DISPLAY)\n"
"  --title TITLE        window title\n"
"  --fullscreen         start fullscreen\n"
"  --fps N              frame timer rate (default 60)\n"
"  --no-input           do not forward pointer/keyboard to X\n"
"  --keymap-offset N    X keycode = evdev keycode + N (default 8)\n"
"  --no-damage          ignore XDamage, rescan the screen every tick\n"
"  --frames N           exit after N committed frames\n"
"  --dump-frame PATH    write the last presented frame as binary PPM\n"
"  -v, --verbose\n", argv0);
}

int main(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "x-display",     required_argument, NULL, 'd' },
		{ "title",         required_argument, NULL, 't' },
		{ "fullscreen",    no_argument,       NULL, 'f' },
		{ "fps",           required_argument, NULL, 'r' },
		{ "no-input",      no_argument,       NULL, 'i' },
		{ "keymap-offset", required_argument, NULL, 'k' },
		{ "no-damage",     no_argument,       NULL, 'D' },
		{ "frames",        required_argument, NULL, 'n' },
		{ "dump-frame",    required_argument, NULL, 'o' },
		{ "verbose",       no_argument,       NULL, 'v' },
		{ "help",          no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	const char *xdisplay = NULL;
	int c;
	while ((c = getopt_long(argc, argv, "vd:t:fr:ik:Dn:o:h", longopts, NULL)) != -1) {
		switch (c) {
		case 'd': xdisplay = optarg; break;
		case 't': S.opt_title = optarg; break;
		case 'f': S.opt_fullscreen = true; break;
		case 'r': S.opt_fps = atoi(optarg); break;
		case 'i': S.opt_input = false; break;
		case 'k': S.opt_keymap_offset = atoi(optarg); break;
		case 'D': S.opt_no_damage = true; break;
		case 'n': S.opt_frames = atoi(optarg); break;
		case 'o': S.opt_dump = optarg; break;
		case 'v': S.opt_verbose = true; break;
		case 'h': usage(argv[0]); return 0;
		default: usage(argv[0]); return 2;
		}
	}
	if (xdisplay)
		setenv("DISPLAY", xdisplay, 1);
	if (S.opt_fps <= 0) S.opt_fps = 60;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (!x_init())
		return 1;

	if (S.opt_no_damage && S.damage_ev_base) {
		xcb_damage_destroy(S.xc, S.damage);
		S.damage_ev_base = 0;
	}

	S.display = wl_display_connect(NULL);
	if (!S.display) {
		fprintf(stderr, "xfbridge: cannot connect to a Wayland compositor "
			"(WAYLAND_DISPLAY=%s)\n",
			getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(unset)");
		return 1;
	}
	S.registry = wl_display_get_registry(S.display);
	wl_registry_add_listener(S.registry, &registry_listener, NULL);
	wl_display_roundtrip(S.display);
	wl_display_roundtrip(S.display);
	if (!S.compositor || !S.shm || !S.wm_base) {
		fprintf(stderr, "xfbridge: compositor is missing "
			"wl_compositor / wl_shm / xdg_wm_base\n");
		return 1;
	}

	create_buffers();

	S.surface = wl_compositor_create_surface(S.compositor);
	S.xdg_surface = xdg_wm_base_get_xdg_surface(S.wm_base, S.surface);
	xdg_surface_add_listener(S.xdg_surface, &xdg_surface_listener, NULL);
	S.toplevel = xdg_surface_get_toplevel(S.xdg_surface);
	xdg_toplevel_add_listener(S.toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_title(S.toplevel, S.opt_title);
	xdg_toplevel_set_app_id(S.toplevel, "xfbridge");
	if (S.opt_fullscreen)
		xdg_toplevel_set_fullscreen(S.toplevel, NULL);
	wl_surface_commit(S.surface);

	damage_all();

	int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	struct itimerspec its = {
		.it_value = { 0, 1000000000L / S.opt_fps },
		.it_interval = { 0, 1000000000L / S.opt_fps },
	};
	timerfd_settime(tfd, 0, &its, NULL);

	S.running = true;
	int xfd = xcb_get_file_descriptor(S.xc);
	int wfd = wl_display_get_fd(S.display);

	while (S.running) {
		bool dirty = false;

		while (wl_display_prepare_read(S.display) != 0)
			wl_display_dispatch_pending(S.display);
		wl_display_flush(S.display);

		struct pollfd pfd[3] = {
			{ wfd, POLLIN, 0 },
			{ xfd, POLLIN, 0 },
			{ tfd, POLLIN, 0 },
		};
		if (poll(pfd, 3, 1000) < 0 && errno != EINTR) {
			wl_display_cancel_read(S.display);
			break;
		}
		if (pfd[0].revents & POLLIN)
			wl_display_read_events(S.display);
		else
			wl_display_cancel_read(S.display);
		wl_display_dispatch_pending(S.display);

		if (pfd[1].revents & POLLIN)
			drain_x_events(&dirty);

		if (pfd[2].revents & POLLIN) {
			uint64_t exp;
			while (read(tfd, &exp, sizeof(exp)) < 0 && errno == EINTR)
				;
			if (!S.damage_ev_base)
				damage_all();
			if (present()) {
				S.total_frames++;
				stats();
			}
			if (S.opt_frames && S.total_frames >= (unsigned long)S.opt_frames)
				S.running = false;
		}
	}

	if (S.opt_dump)
		dump_ppm(S.opt_dump);

	if (S.pointer) wl_pointer_destroy(S.pointer);
	if (S.keyboard) wl_keyboard_destroy(S.keyboard);
	if (S.seat) wl_seat_destroy(S.seat);
	if (S.toplevel) xdg_toplevel_destroy(S.toplevel);
	if (S.xdg_surface) xdg_surface_destroy(S.xdg_surface);
	if (S.surface) wl_surface_destroy(S.surface);
	for (int i = 0; i < S.nbuf; i++) {
		wl_buffer_destroy(S.buf[i].wl);
		munmap(S.buf[i].data, S.buf[i].size);
	}
	wl_shm_destroy(S.shm);
	wl_compositor_destroy(S.compositor);
	wl_registry_destroy(S.registry);
	wl_display_disconnect(S.display);
	if (S.shm_data) shmdt(S.shm_data);
	if (S.shm_id >= 0) shmctl(S.shm_id, IPC_RMID, NULL);
	xcb_disconnect(S.xc);
	return 0;
}
