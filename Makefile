APP := build/Build/Products/Release/GHDash.app

.PHONY: project build run install clean

project:
	xcodegen generate --quiet

# The touch bumps the bundle's timestamp so the Dock and Finder drop cached icons.
build: project
	xcodebuild -project GHDash.xcodeproj -scheme GHDash -configuration Release \
		-derivedDataPath build -quiet build
	touch $(APP)

run: build
	open $(APP)

install: build
	rm -rf /Applications/GHDash.app
	cp -R $(APP) /Applications/GHDash.app

clean:
	rm -rf build GHDash.xcodeproj
