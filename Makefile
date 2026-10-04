# canvas-browser -- a web browser in an Emacs buffer, drawn on a canvas.

EMACS   ?= emacs
DIAGRAM ?= ../canvas-diagram
KEYS    ?= ../canvas-keys
ELPACA  ?= $(HOME)/.emacs.d/elpaca/builds
MATCH   ?=

# The cairo and pango module lives with canvas-diagram.
LOAD    = -L . -L $(DIAGRAM) -L $(KEYS) -L tests -L $(ELPACA)/websocket \
          -L $(ELPACA)/transient -L $(ELPACA)/cond-let
SUITES  = tests/canvas-browser-cdp-tests.el tests/canvas-browser-tests.el

.PHONY: test live display clean

test:
	ERT_MATCH='$(MATCH)' $(EMACS) -Q --batch --eval "(setq load-prefer-newer t)" $(LOAD) \
	  $(addprefix -l ,$(SUITES)) \
	  --eval '(ert-run-tests-batch-and-exit (getenv "ERT_MATCH"))'

# Needs chromium, and opens a page from tests/fixtures.
live:
	$(EMACS) -Q --batch --eval "(setq load-prefer-newer t)" $(LOAD) -l tests/canvas-browser-live-tests.el \
	  --eval '(ert-run-tests-batch-and-exit)'

# The virtual display chromium draws on, out of sight, on macOS.
display: canvas-browser-display

canvas-browser-display: canvas-browser-display.swift canvas-browser-display.h
	swiftc -O -import-objc-header canvas-browser-display.h -o $@ canvas-browser-display.swift

clean:
	rm -f *.elc tests/*.elc canvas-browser-display
