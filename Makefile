# Snagbook — build, test, install.
#
#   make            build the .app into ./build
#   make run        build and open it
#   make install    build and copy it to /Applications (override with DESTDIR)
#   make test       unit tests (Swift and the note editor)
#   make selftest   drive the real app end to end (needs a logged-in Mac session)
#   make icon       redraw Resources/AppIcon.icns
#   make clean      delete build output

DESTDIR ?= /Applications

.PHONY: all build run install uninstall test selftest icon clean

all: build

build:
	./Scripts/build-app.sh release

run: build
	open build/Snagbook.app

install: build
	rm -rf "$(DESTDIR)/Snagbook.app"
	cp -R build/Snagbook.app "$(DESTDIR)/Snagbook.app"
	@echo "installed: $(DESTDIR)/Snagbook.app"

uninstall:
	rm -rf "$(DESTDIR)/Snagbook.app"

test:
	swift test
	cd web && { [ -d node_modules ] || npm ci --silent; } && npm test

selftest: build
	@tmp=$$(mktemp -d); echo '{"sessionsFolder":"'$$tmp'/sessions"}' > $$tmp/config.json; \
	SNAGBOOK_SELFTEST=1 SNAGBOOK_CONFIG=$$tmp/config.json build/Snagbook.app/Contents/MacOS/Snagbook 2>/dev/null; \
	status=$$?; rm -rf $$tmp; exit $$status

icon:
	swift Scripts/make-icon.swift .build/AppIcon-1024.png
	rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) .build/AppIcon-1024.png --out .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
