# Heed -- build, package, install.
#
# The app is ad-hoc signed because there is no code-signing identity on this machine. That has one
# consequence worth knowing before you wonder why things broke: an ad-hoc signature is tied to the
# exact binary, so every rebuild is a different identity as far as TCC is concerned, and the
# Accessibility grant does not carry over. `make reset-permission` clears the stale grant so macOS
# asks again. See README.md.

BUNDLE_ID   := io.github.rbstp.heed
CERT_NAME   := Heed Local Signing
APP_NAME    := Heed
VERSION     := 0.1.0

INSTALL_DIR := $(HOME)/Applications
APP         := $(INSTALL_DIR)/$(APP_NAME).app
EXECUTABLE  := $(APP)/Contents/MacOS/$(APP_NAME)
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LOG         := $(HOME)/Library/Logs/heed.log
DOMAIN      := gui/$(shell id -u)
SIGN_ID     := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '$(CERT_NAME)' && printf '%s' '$(CERT_NAME)' || printf -- '-')
BUILT       := .build/release/$(APP_NAME)
ICON_SRC    := Tools/make-icon.swift
ICNS        := .build/$(APP_NAME).icns

.PHONY: all build test bundle install install-agent uninstall restart logs probe \
        icon cert reset-permission requirement clean

all: build

build:
	swift build -c release

test:
	swift test

## Render the app icon at every size the iconset needs.
##
## Generated rather than committed, so the artwork stays reviewable as code. The renderer switches to
## a head-on cube below 32px, where an isometric one collapses into a green ring.
icon: $(ICNS)

$(ICNS): $(ICON_SRC)
	@rm -rf .build/$(APP_NAME).iconset
	@mkdir -p .build/$(APP_NAME).iconset
	@set -e; for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
	                     256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		px=$${spec%%:*}; name=$${spec##*:}; \
		swift $(ICON_SRC) $$px .build/$(APP_NAME).iconset/icon_$$name.png; \
	done
	iconutil -c icns .build/$(APP_NAME).iconset -o $(ICNS)
	@echo "built $(ICNS)"

## Assemble and sign the .app in place under $(INSTALL_DIR).
bundle: build $(ICNS)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILT)" "$(EXECUTABLE)"
	cp "$(ICNS)" "$(APP)/Contents/Resources/$(APP_NAME).icns"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@APP_NAME@|$(APP_NAME)|g' \
	    -e 's|@VERSION@|$(VERSION)|g' \
	    Resources/Info.plist > "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" --identifier "$(BUNDLE_ID)" "$(APP)"
	@echo "built $(APP), signed by $(if $(filter -,$(SIGN_ID)),ad-hoc,$(SIGN_ID))"

install: bundle install-agent
	@echo
	@echo "Installed. If this is the first run, grant Accessibility to $(APP_NAME) in"
	@echo "System Settings > Privacy & Security > Accessibility."
	@echo "It is picked up automatically -- no restart needed. Watch it with: make logs"

## Load the login agent. Written with absolute paths; launchd does not expand ~ .
##
## Regenerated every time rather than treated as a file target dependent on the template: the
## contents also depend on APP_NAME and $(HOME), so a timestamp comparison against the template
## alone would happily leave a plist pointing at an app path that no longer exists.
install-agent:
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@EXECUTABLE@|$(EXECUTABLE)|g' \
	    -e 's|@LOG@|$(LOG)|g' \
	    LaunchAgent/agent.plist.in > "$(AGENT_PLIST)"
	-launchctl bootout $(DOMAIN)/$(BUNDLE_ID) 2>/dev/null
	launchctl bootstrap $(DOMAIN) "$(AGENT_PLIST)"
	@echo "agent loaded: $(BUNDLE_ID)"

restart:
	launchctl kickstart -k $(DOMAIN)/$(BUNDLE_ID)

logs:
	@touch "$(LOG)"; tail -f "$(LOG)"

## What does the agent see under the pointer right now? Runs standalone; does not touch the agent.
probe: build
	@"$(BUILT)" --probe

## Create a self-signed code-signing identity so the Accessibility grant survives rebuilds.
##
## Scoped to code signing only, and trusted in the login keychain rather than system-wide, so it
## cannot vouch for anything else. Remove it with:
##   security delete-identity -c "$(CERT_NAME)" ~/Library/Keychains/login.keychain-db
##
## openssl's own PKCS#12 defaults are rejected by Apple's importer ("MAC verification failed"),
## hence the explicit legacy PBE and SHA1 MAC.
cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '$(CERT_NAME)'; then \
		echo "identity \"$(CERT_NAME)\" already present"; \
	else \
		set -e; \
		tmp=$$(mktemp -d); \
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
		rm -rf "$$tmp"; \
		echo "created and trusted \"$(CERT_NAME)\" -- now run: make install"; \
	fi

## Clear the stale Accessibility grant after a rebuild, so macOS prompts again.
reset-permission:
	tccutil reset Accessibility $(BUNDLE_ID)
	-launchctl kickstart -k $(DOMAIN)/$(BUNDLE_ID)

## Print the designated requirement, and say what it means for permission surviving a rebuild.
## codesign emits this line commented ("# designated => ..."), hence the -o rather than an anchor.
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
