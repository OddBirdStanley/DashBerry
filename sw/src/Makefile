# dashberry-panel — the runtime's single project-compiled C program.
# Plain cc; no libraries beyond libc (no libgpiod, no libsystemd, no libm).

CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -O2
PREFIX  ?= /usr/local
DESTDIR ?=

dashberry-panel: dashberry-panel.c
	$(CC) $(CFLAGS) -o $@ dashberry-panel.c

install: dashberry-panel
	install -D -m 755 dashberry-panel $(DESTDIR)$(PREFIX)/bin/dashberry-panel

clean:
	rm -f dashberry-panel

.PHONY: install clean
