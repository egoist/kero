PROJECT := kero.xcodeproj
SCHEME := kero
CONFIGURATION := Debug
ARCH ?= $(shell uname -m)
DERIVED_DATA := $(CURDIR)/build/debug
DEBUG_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Kero Debug.app
DEBUG_BUNDLE_ID := sh.kero.dev

ifdef DEVELOPER_DIR
XCODEBUILD := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild
else
XCODEBUILD := xcodebuild
endif

.PHONY: run update stop

# A stable DerivedData path lets `open` address the Debug bundle directly.
run:
	@$(XCODEBUILD) -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -destination 'platform=macOS,arch=$(ARCH)' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
	# Kero-hosted shells export these for the in-app CLI; inheriting them makes
	# the Debug bundle immediately act as that CLI instead of launching its UI.
	@/usr/bin/env -u KERO_CLI_STATE -u KERO_CLI_TOKEN /usr/bin/open -n "$(DEBUG_APP)"

update:
	@$(MAKE) stop
	@$(MAKE) run

# Give terminal sessions their normal shutdown path before forcing a stuck Debug app.
stop:
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("$(DEBUG_BUNDLE_ID)"); for (let i = 0; i < apps.count; i += 1) { void apps.objectAtIndex(i).terminate; }'
	@sleep 1
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("$(DEBUG_BUNDLE_ID)"); for (let i = 0; i < apps.count; i += 1) { void apps.objectAtIndex(i).forceTerminate; }'
