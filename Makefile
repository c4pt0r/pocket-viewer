# pocket-viewer itself is a Rust program (cargo); everything else here is
# optional. The Swift plugins and pocketctl are macOS-only.
UNAME := $(shell uname -s)
CFLAGS = -O2 -Wall
IOKIT = -framework IOKit -framework CoreFoundation
ifeq ($(OS),Windows_NT)
EXE = .exe
endif

ifeq ($(UNAME),Darwin)
all: pocket-viewer pocketctl plugins
else
all: pocket-viewer
endif

# Cargo decides what to rebuild; the copy keeps ./pocket-viewer working as before.
pocket-viewer:
	cargo build --release
	cp target/release/pocket-viewer$(EXE) ./pocket-viewer$(EXE)

SWIFTC = swiftc -O -parse-as-library
plugins: plugins/bin/face-follow plugins/bin/tracker plugins/bin/gestures plugins/bin/interpreter \
	plugins/bin/voice-control plugins/bin/transcribe plugins/bin/calibrate

SDK = plugins/swift/PocketViewer.swift
FOLLOW = $(SDK) plugins/swift/Follow.swift
SPEECH = $(SDK) plugins/swift/Speech.swift
# Speech recognition needs a usage string in an embedded Info.plist.
plist = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(1)

plugins/bin/face-follow: $(FOLLOW) plugins/swift/FaceFollow.swift
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $^

plugins/bin/tracker: $(FOLLOW) plugins/swift/Tracker.swift
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $^

plugins/bin/gestures: $(FOLLOW) plugins/swift/Gestures.swift
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $^

plugins/bin/calibrate: $(SDK) plugins/swift/Calibrate.swift
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $^

plugins/bin/interpreter: $(SPEECH) plugins/swift/Interpreter.swift plugins/swift/Interpreter-Info.plist
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $(SPEECH) plugins/swift/Interpreter.swift $(call plist,plugins/swift/Interpreter-Info.plist)

plugins/bin/voice-control: $(SPEECH) plugins/swift/VoiceControl.swift plugins/swift/VoiceControl-Info.plist
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $(SPEECH) plugins/swift/VoiceControl.swift $(call plist,plugins/swift/VoiceControl-Info.plist)

plugins/bin/transcribe: $(SPEECH) plugins/swift/Transcribe.swift plugins/swift/Transcribe-Info.plist
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $(SPEECH) plugins/swift/Transcribe.swift $(call plist,plugins/swift/Transcribe-Info.plist)

pocketctl: pocketctl.c gimbal.c gimbal.h
	clang $(CFLAGS) -o $@ pocketctl.c gimbal.c $(IOKIT)

# The voice agent (Node + the pi SDK); needs network for npm install.
ai-agent: plugins/bin/transcribe plugins/node/ai-agent/node_modules

plugins/node/ai-agent/node_modules: plugins/node/ai-agent/package.json plugins/node/ai-agent/package-lock.json
	cd plugins/node/ai-agent && npm ci --no-audit --no-fund
	@touch $@

.PHONY: all pocket-viewer plugins ai-agent clean

clean:
	cargo clean
	rm -rf pocketctl pocket-viewer plugins/bin plugins/node/ai-agent/node_modules
