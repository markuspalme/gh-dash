APP := build/Build/Products/Release/GHDash.app

IOS_APP := build/Build/Products/Debug-iphonesimulator/GHDashMobile.app
IOS_DEVICE ?= iPhone 17 Pro

.PHONY: project build run demo install ios ios-run ios-demo clean

project:
	xcodegen generate --quiet

# The touch bumps the bundle's timestamp so the Dock and Finder drop cached icons.
build: project
	xcodebuild -project GHDash.xcodeproj -scheme GHDash -configuration Release \
		-derivedDataPath build -quiet build
	touch $(APP)

run: build
	open $(APP)

# A second instance with made-up data; leaves your settings and GitHub alone.
demo: build
	open -n $(APP) --args --demo -hideDrafts YES -hideFailingDependabot YES -scopedRepo ""

install: build
	rm -rf /Applications/GHDash.app
	cp -R $(APP) /Applications/GHDash.app

# The iOS app, built for and run in the simulator.
ios: project
	xcodebuild -project GHDash.xcodeproj -scheme GHDashMobile -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet build

ios-run: ios
	xcrun simctl boot "$(IOS_DEVICE)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(IOS_DEVICE)" $(IOS_APP)
	xcrun simctl launch --terminate-running-process "$(IOS_DEVICE)" com.markuspalme.GHDashMobile $(IOS_ARGS)

ios-demo: IOS_ARGS = --demo
ios-demo: ios-run

clean:
	rm -rf build GHDash.xcodeproj
