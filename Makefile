# Heed -- build, package, install. See README.md.

BUNDLE_ID   := io.github.rbstp.heed
APP_NAME    := Heed
# The distribution identity. Notarization needs a real Developer ID, and its signature gives the app
# an identity-based designated requirement, so one Accessibility grant covers every later build.
TEAM_ID     := RM3UT3MMSR
DEVID_NAME  := Developer ID Application: RICHARD BOISVERT-ST-PIERRE ($(TEAM_ID))
# The fallback for anyone without that private key: self-signed, trusted locally, `make cert`.
CERT_NAME   := Heed Local Signing
# Latest tag, or 0.0.0 when none is reachable (a shallow CI clone). The release workflow overrides it.
VERSION     := $(shell git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')
ifeq ($(VERSION),)
VERSION     := 0.0.0
endif

INSTALL_DIR := $(HOME)/Applications
APP         := $(INSTALL_DIR)/$(APP_NAME).app
EXECUTABLE  := $(APP)/Contents/MacOS/$(APP_NAME)
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LOG         := $(HOME)/Library/Logs/heed.log
DOMAIN      := gui/$(shell id -u)
# A certificate's hash, or empty: not found, but also a locked keychain or a missing tool.
# Signing refuses rather than silently going ad-hoc; ADHOC=1 forces ad-hoc on purpose.
find_identity = $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep -F '"$(1)"' | head -1 | awk '{print $$2}')
DEVID_ID    := $(call find_identity,$(DEVID_NAME))
LOCAL_ID    := $(call find_identity,$(CERT_NAME))
ifeq ($(ADHOC),1)
CODESIGN_ID := -
SIGNED_BY   := ad-hoc
else ifneq ($(DEVID_ID),)
CODESIGN_ID := $(DEVID_ID)
SIGNED_BY   := $(DEVID_NAME)
# The notary service rejects anything without the hardened runtime and a secure timestamp.
CODESIGN_OPTS := --options runtime --timestamp
NOTARIZABLE := 1
else
CODESIGN_ID := $(if $(LOCAL_ID),$(LOCAL_ID),-)
SIGNED_BY   := $(if $(LOCAL_ID),$(CERT_NAME),ad-hoc)
endif

# Locally the notary credentials sit in a keychain profile, from `xcrun notarytool
# store-credentials`; CI has no keychain profile and passes the App Store Connect key itself.
NOTARY_PROFILE := heed
NOTARY_AUTH := $(if $(NOTARY_KEY),--key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" \
                 --issuer "$(NOTARY_ISSUER)",--keychain-profile "$(NOTARY_PROFILE)")

BUILT       := .build/release/$(APP_NAME)
ICON_TOOL   := .build/release/heed-icon
ICON_SRC    := Sources/IconTool/main.swift Sources/HeedCore/Glyph.swift
ICNS        := .build/$(APP_NAME).icns
STAGE       := .build/stage
DIST        := .build/dist
ZIP         := $(DIST)/$(APP_NAME)-$(VERSION).zip

.PHONY: all build test bundle dist notarize install uninstall restart logs \
        logs-clear probe icon cert check-package reset-permission requirement clean

all: build

build:
	swift build -c release

test:
	swift test

## Render the iconset from code: the menu bar mark, white on a dark tile.
icon: $(ICNS)

# The Makefile defines the size matrix, so it is a dependency too. `build` is order-only: it builds
# the renderer along with everything else, and running it here as well would put a second SwiftPM
# process on .build under `make -j`, where the two contend for its lock.
$(ICNS): $(ICON_SRC) Makefile | build
	@rm -rf .build/$(APP_NAME).iconset
	@mkdir -p .build/$(APP_NAME).iconset
	@set -e; for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
	                     256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		px=$${spec%%:*}; name=$${spec##*:}; \
		$(ICON_TOOL) $$px .build/$(APP_NAME).iconset/icon_$$name.png; \
	done
	iconutil -c icns .build/$(APP_NAME).iconset -o $(ICNS)
	@echo "built $(ICNS)"

## Assemble and sign the .app under $(INSTALL_DIR).
bundle: build $(ICNS)
	@if [ "$(CODESIGN_ID)" = "-" ] && [ "$(ADHOC)" != "1" ]; then \
		echo "no code-signing identity was found -- neither a Developer ID nor \"$(CERT_NAME)\"."; \
		echo "Either:"; \
		echo "  make cert             create one, so the permission survives rebuilds"; \
		echo "  make bundle ADHOC=1   sign ad-hoc deliberately (permission resets each rebuild)"; \
		exit 1; \
	fi
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILT)" "$(EXECUTABLE)"
	cp "$(ICNS)" "$(APP)/Contents/Resources/$(APP_NAME).icns"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@APP_NAME@|$(APP_NAME)|g' \
	    -e 's|@VERSION@|$(VERSION)|g' \
	    Resources/Info.plist > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(CODESIGN_ID)" --identifier "$(BUNDLE_ID)" $(CODESIGN_OPTS) "$(APP)"
	@echo "built $(APP), signed by $(SIGNED_BY)"

# Earlier versions ran under a login agent, which would start a second copy at the next login.
install: bundle
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	rm -f "$(AGENT_PLIST)"
	@$(MAKE) --no-print-directory restart
	@echo
	@echo "Installed. If this is the first run, grant Accessibility to $(APP_NAME) in"
	@echo "System Settings > Privacy & Security > Accessibility."
	@echo "It is picked up automatically -- no restart needed. Watch it with: make logs"

restart:
	pkill -x $(APP_NAME) || true
	@for i in $$(seq 30); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.1; done
	open "$(APP)"

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
	@$(MAKE) --no-print-directory notarize
	@shasum -a 256 "$(ZIP)"

## Notarize what `dist` staged, staple the ticket into the app, and repack: the ticket has to be
## inside the archive people download, or the first launch needs the network to find one.
notarize:
ifneq ($(NOTARIZABLE),1)
	@echo "not notarized: the app is signed by $(SIGNED_BY), which the notary service cannot check."
	@echo "Gatekeeper will refuse this archive on a machine that downloads it."
else
	@# --timeout: without one, a notary service that never answers hangs the release job for hours.
	xcrun notarytool submit "$(ZIP)" $(NOTARY_AUTH) --wait --timeout 1h
	xcrun stapler staple "$(STAGE)/$(APP_NAME).app"
	@rm -f "$(ZIP)"
	ditto -c -k --keepParent --sequesterRsrc "$(STAGE)/$(APP_NAME).app" "$(ZIP)"
	xcrun stapler validate "$(STAGE)/$(APP_NAME).app"
	spctl -a -vvv -t exec "$(STAGE)/$(APP_NAME).app"
endif

## Clear the stale Accessibility grant after a rebuild, so macOS prompts again.
reset-permission:
	tccutil reset Accessibility $(BUNDLE_ID)
	-@$(MAKE) --no-print-directory restart

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
	pkill -x $(APP_NAME) || true
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	rm -f "$(AGENT_PLIST)"
	rm -rf "$(APP)"
	@echo "removed $(APP)"
	@echo "note: the Accessibility entry remains listed; clear it with"
	@echo "  tccutil reset Accessibility $(BUNDLE_ID)"

clean:
	rm -rf .build
