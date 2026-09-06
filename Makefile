# Heed -- build, package, install. See README.md.

BUNDLE_ID   := io.github.rbstp.heed
CERT_NAME   := Heed Local Signing
APP_NAME    := Heed
# Latest tag, or 0.0.0 when none is reachable (a shallow CI clone). The release workflow overrides it.
VERSION     := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
ifeq ($(VERSION),)
VERSION     := 0.0.0
endif

INSTALL_DIR := $(HOME)/Applications
APP         := $(INSTALL_DIR)/$(APP_NAME).app
EXECUTABLE  := $(APP)/Contents/MacOS/$(APP_NAME)
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LOG         := $(HOME)/Library/Logs/heed.log
DOMAIN      := gui/$(shell id -u)
# The certificate's hash, or empty: not found, but also a locked keychain or a missing tool.
# Signing refuses rather than silently going ad-hoc; ADHOC=1 forces ad-hoc on purpose.
SIGN_ID     := $(shell security find-identity -v -p codesigning 2>/dev/null \
                 | grep -F '"$(CERT_NAME)"' | head -1 | awk '{print $$2}')
ifeq ($(ADHOC),1)
CODESIGN_ID := -
SIGNED_BY   := ad-hoc
else
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)
SIGNED_BY   := $(if $(SIGN_ID),$(CERT_NAME),ad-hoc)
endif

# sed cannot be trusted with these characters in the generated plists.
define check_paths
@case '$(EXECUTABLE)$(LOG)' in \
	*['&|<>']*) echo "a path contains a character that would corrupt the plists: $(EXECUTABLE)"; \
	            exit 1;; \
esac
endef
BUILT       := .build/release/$(APP_NAME)
ICON_SRC    := Tools/make-icon.swift
ICNS        := .build/$(APP_NAME).icns
STAGE       := .build/stage
DIST        := .build/dist
ZIP         := $(DIST)/$(APP_NAME)-$(VERSION).zip

.PHONY: all build test bundle dist install install-agent uninstall restart logs logs-clear probe \
        icon cert check-package reset-permission requirement clean

all: build

build:
	swift build -c release

test:
	swift test

## Render the iconset from code; below 32px the renderer switches to a head-on cube.
icon: $(ICNS)

# The Makefile defines the size matrix, so it is a dependency too.
$(ICNS): $(ICON_SRC) Makefile
	@rm -rf .build/$(APP_NAME).iconset
	@mkdir -p .build/$(APP_NAME).iconset
	@set -e; for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
	                     256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		px=$${spec%%:*}; name=$${spec##*:}; \
		swift $(ICON_SRC) $$px .build/$(APP_NAME).iconset/icon_$$name.png; \
	done
	iconutil -c icns .build/$(APP_NAME).iconset -o $(ICNS)
	@echo "built $(ICNS)"

## Assemble and sign the .app under $(INSTALL_DIR).
bundle: build $(ICNS)
	@if [ -z "$(SIGN_ID)" ] && [ "$(ADHOC)" != "1" ]; then \
		echo "no code-signing identity named \"$(CERT_NAME)\" was found. Either:"; \
		echo "  make cert             create one, so the permission survives rebuilds"; \
		echo "  make bundle ADHOC=1   sign ad-hoc deliberately (permission resets each rebuild)"; \
		exit 1; \
	fi
	$(check_paths)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILT)" "$(EXECUTABLE)"
	cp "$(ICNS)" "$(APP)/Contents/Resources/$(APP_NAME).icns"
	cp LaunchAgent/agent.plist.in "$(APP)/Contents/Resources/agent.plist.in"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@APP_NAME@|$(APP_NAME)|g' \
	    -e 's|@VERSION@|$(VERSION)|g' \
	    Resources/Info.plist > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(CODESIGN_ID)" --identifier "$(BUNDLE_ID)" "$(APP)"
	@echo "built $(APP), signed by $(SIGNED_BY)"

# install-agent runs from the recipe: as a prerequisite, `make -j` could bootstrap it before the
# bundle existed.
install: bundle
	@$(MAKE) --no-print-directory install-agent
	@echo
	@echo "Installed. If this is the first run, grant Accessibility to $(APP_NAME) in"
	@echo "System Settings > Privacy & Security > Accessibility."
	@echo "It is picked up automatically -- no restart needed. Watch it with: make logs"

## Load the login agent. Regenerated every time: the contents depend on APP_NAME and $(HOME).
install-agent:
	$(check_paths)
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@EXECUTABLE@|$(EXECUTABLE)|g' \
	    -e 's|@LOG@|$(LOG)|g' \
	    LaunchAgent/agent.plist.in > "$(AGENT_PLIST)"
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	@# bootout returns before the job is gone; bootstrapping into that window fails with EIO.
	@for i in $$(seq 30); do \
		launchctl print $(DOMAIN)/$(BUNDLE_ID) >/dev/null 2>&1 || break; \
		sleep 0.1; \
	done
	launchctl bootstrap $(DOMAIN) "$(AGENT_PLIST)"
	@echo "agent loaded: $(BUNDLE_ID)"

restart:
	launchctl kickstart -k $(DOMAIN)/$(BUNDLE_ID)

logs:
	@touch "$(LOG)"; tail -f "$(LOG)"

## Truncated rather than deleted, so the running agent keeps its open handle.
logs-clear:
	@: > "$(LOG)"; echo "cleared $(LOG)"

## What the agent sees under the pointer, or at a point: make probe X=960 Y=540
probe: build
	@if [ -n "$(X)$(Y)" ] && { [ -z "$(X)" ] || [ -z "$(Y)" ]; }; then \
		echo "usage: make probe [X=<x> Y=<y>]"; exit 1; \
	fi
	@"$(BUILT)" --probe $(X) $(Y)

## Self-signed identity, trusted in the login keychain only, so the Accessibility grant survives
## rebuilds. Remove: security delete-identity -t -c "$(CERT_NAME)" ~/Library/Keychains/login.keychain-db
## Apple's importer rejects openssl's PKCS#12 defaults, hence the legacy PBE and SHA1 MAC.
cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '$(CERT_NAME)'; then \
		echo "identity \"$(CERT_NAME)\" already present"; \
	else \
		set -e; \
		tmp=$$(mktemp -d); \
		trap 'rm -rf "$$tmp"' EXIT INT TERM; \
		printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = v3' 'prompt = no' \
			'[dn]' 'CN = $(CERT_NAME)' \
			'[v3]' 'basicConstraints = critical,CA:false' \
			'keyUsage = critical,digitalSignature' \
			'extendedKeyUsage = critical,codeSigning' \
			'subjectKeyIdentifier = hash' > "$$tmp/cfg"; \
		openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
			-keyout "$$tmp/key.pem" -out "$$tmp/cert.pem" -config "$$tmp/cfg" 2>/dev/null; \
		openssl pkcs12 -export -out "$$tmp/bundle.p12" -inkey "$$tmp/key.pem" -in "$$tmp/cert.pem" \
			-name '$(CERT_NAME)' -passout pass:heedtmp \
			-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1; \
		security import "$$tmp/bundle.p12" -k "$(HOME)/Library/Keychains/login.keychain-db" \
			-P heedtmp -T /usr/bin/codesign; \
		security add-trusted-cert -r trustRoot -p codeSign \
			-k "$(HOME)/Library/Keychains/login.keychain-db" "$$tmp/cert.pem"; \
		echo "created and trusted \"$(CERT_NAME)\" -- now run: make install"; \
	fi

## Package smoke test, staged and ad-hoc so it touches neither the installed app nor launchd.
check-package:
	@rm -rf "$(STAGE)"
	@$(MAKE) --no-print-directory bundle ADHOC=1 INSTALL_DIR="$(STAGE)"
	codesign --verify --deep --strict "$(STAGE)/$(APP_NAME).app"
	plutil -lint "$(STAGE)/$(APP_NAME).app/Contents/Info.plist"
	@sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	     -e 's|@EXECUTABLE@|$(STAGE)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)|g' \
	     -e 's|@LOG@|$(STAGE)/heed.log|g' \
	     "$(STAGE)/$(APP_NAME).app/Contents/Resources/agent.plist.in" > "$(STAGE)/agent.plist"
	plutil -lint "$(STAGE)/agent.plist"
	@test -s "$(STAGE)/$(APP_NAME).app/Contents/Resources/$(APP_NAME).icns" \
		|| { echo "the bundle has no icon"; exit 1; }
	@rc=0; "$(STAGE)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" --probe >/dev/null 2>&1 || rc=$$?; \
	if [ $$rc -ge 126 ]; then \
		echo "--probe crashed rather than ran (exit $$rc)"; exit 1; \
	elif [ $$rc -ne 0 ]; then \
		echo "note: --probe exited $$rc, expected without an Accessibility grant"; \
	fi
	@echo "package checks passed"

## Release archive for the cask. ditto rather than zip: zip can mangle the code signature.
dist:
	@rm -rf "$(STAGE)" "$(DIST)"
	@$(MAKE) --no-print-directory bundle INSTALL_DIR="$(STAGE)"
	codesign --verify --deep --strict "$(STAGE)/$(APP_NAME).app"
	@mkdir -p "$(DIST)"
	ditto -c -k --keepParent --sequesterRsrc "$(STAGE)/$(APP_NAME).app" "$(ZIP)"
	@shasum -a 256 "$(ZIP)"

## Clear the stale Accessibility grant after a rebuild, so macOS prompts again.
reset-permission:
	tccutil reset Accessibility $(BUNDLE_ID)
	-launchctl kickstart -k $(DOMAIN)/$(BUNDLE_ID)

## Print the designated requirement; codesign emits it as a comment, hence -o rather than an anchor.
requirement:
	@req=$$(codesign -d -r- "$(APP)" 2>/dev/null | grep -o 'designated =>.*'); \
	if [ -z "$$req" ]; then \
		echo "no signature found at $(APP) -- run: make bundle"; \
	elif echo "$$req" | grep -q cdhash; then \
		echo "$$req"; \
		echo "-> hash-based: every rebuild is a new identity, so the Accessibility grant will"; \
		echo "   not survive one. Recover with: make reset-permission"; \
	else \
		echo "$$req"; \
		echo "-> identity-based: the grant should survive rebuilds"; \
	fi

uninstall:
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	rm -f "$(AGENT_PLIST)"
	rm -rf "$(APP)"
	@echo "removed the agent and $(APP)"
	@echo "note: the Accessibility entry remains listed; clear it with"
	@echo "  tccutil reset Accessibility $(BUNDLE_ID)"

clean:
	rm -rf .build
