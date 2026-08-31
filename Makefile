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
# Resolved to the certificate's hash, not its name, and empty when it is not found.
#
# Matching a name is ambiguous once two identities share one, and the previous version collapsed any
# failure -- locked keychain, missing tool, ambiguous match -- into ad-hoc signing, which silently
# recreated the permission loss the certificate exists to prevent. Signing now refuses rather than
# quietly degrading; ADHOC=1 asks for ad-hoc on purpose.
SIGN_ID     := $(shell security find-identity -v -p codesigning 2>/dev/null \
                 | grep -F '"$(CERT_NAME)"' | head -1 | awk '{print $$2}')
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

# The generated plists are built with sed, which cannot be trusted with these characters. Refuse
# rather than emit a corrupt plist that fails in some confusing way later.
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

## Render the app icon at every size the iconset needs.
##
## Generated rather than committed, so the artwork stays reviewable as code. The renderer switches to
## a head-on cube below 32px, where an isometric one collapses into a green ring.
icon: $(ICNS)

# Depends on the Makefile too: it defines the size/name matrix, so changing that must rebuild.
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

## Assemble and sign the .app in place under $(INSTALL_DIR).
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
	@echo "built $(APP), signed by $(if $(SIGN_ID),$(CERT_NAME),ad-hoc)"

# install-agent runs from the recipe rather than as a second prerequisite: as prerequisites they are
# independent, so `make -j install` could bootstrap the agent before the bundle existed.
install: bundle
	@$(MAKE) --no-print-directory install-agent
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
	$(check_paths)
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

## The log is append-only with no rotation: negligible with verbose off, not with it on. Truncated
## rather than deleted, so the running agent keeps its open handle.
logs-clear:
	@: > "$(LOG)"; echo "cleared $(LOG)"

## What does the agent see under the pointer right now? Runs standalone; does not touch the agent.
probe: build
	@"$(BUILT)" --probe

## Create a self-signed code-signing identity so the Accessibility grant survives rebuilds.
##
## Scoped to code signing only, and trusted in the login keychain rather than system-wide, so it
## cannot vouch for anything else. Remove it with (-t also removes the trust setting, which -c
## alone leaves behind):
##   security delete-identity -t -c "$(CERT_NAME)" ~/Library/Keychains/login.keychain-db
##
## openssl's own PKCS#12 defaults are rejected by Apple's importer ("MAC verification failed"),
## hence the explicit legacy PBE and SHA1 MAC.
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

## Package smoke test: assemble the bundle and the agent plist into a staging directory and check
## them. Deliberately ad-hoc and staged, so it touches neither the installed app nor launchd, and can
## therefore run in CI -- where the compile alone would not catch a broken plist, a missing icon or a
## signature that does not verify.
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
	@"$(STAGE)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" --probe >/dev/null 2>&1 \
		|| echo "note: --probe exited non-zero, expected without an Accessibility grant"
	@echo "package checks passed"

## Build the release archive the Homebrew cask downloads, and print its checksum.
##
## ditto rather than zip: it preserves the bundle's symlinks and its code signature, which `zip -r`
## is free to mangle -- and a mangled signature only shows up as a TCC failure on someone else's
## machine. Staged like check-package, so releasing never touches the installed app.
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
