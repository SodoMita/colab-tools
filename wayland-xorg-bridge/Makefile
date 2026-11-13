# xfbridge - headless Xorg screen as a native Wayland surface
#
#   make            build ./xfbridge
#   make protocol   (re)generate the xdg-shell bindings
#   make clean

CC      ?= cc
PKGS     = wayland-client xcb xcb-shm xcb-damage xcb-xfixes xcb-xtest
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -I. -Isrc
CFLAGS  += $(shell pkg-config --cflags $(PKGS))
LDLIBS  += $(shell pkg-config --libs $(PKGS)) -lm

PROTO_DIR ?= $(shell pkg-config --variable=pkgdatadir wayland-protocols)
XDG_XML    = $(PROTO_DIR)/stable/xdg-shell/xdg-shell.xml

all: xfbridge

xdg-shell-client-protocol.h: $(XDG_XML)
	wayland-scanner client-header $< $@

xdg-shell-protocol.c: $(XDG_XML)
	wayland-scanner private-code $< $@

xfbridge: src/xfbridge.c xdg-shell-client-protocol.h xdg-shell-protocol.c
	$(CC) $(CFLAGS) -o $@ src/xfbridge.c xdg-shell-protocol.c $(LDLIBS)

protocol: xdg-shell-client-protocol.h xdg-shell-protocol.c

clean:
	rm -f xfbridge xdg-shell-client-protocol.h xdg-shell-protocol.c

.PHONY: all protocol clean
