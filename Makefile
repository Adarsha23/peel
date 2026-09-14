FWK := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
APP := dist/Peel.app
BINDIR := /opt/homebrew/bin

.PHONY: build app install test run clean

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/Peel $(APP)/Contents/MacOS/Peel
	@if [ -f Support/Peel.icns ]; then cp Support/Peel.icns $(APP)/Contents/Resources/; fi
	codesign --force -s - $(APP)

install: app
	-killall Peel 2>/dev/null || true
	mkdir -p ~/Applications
	rm -rf ~/Applications/Peel.app
	cp -R $(APP) ~/Applications/
	ln -sf ~/Applications/Peel.app/Contents/MacOS/Peel $(BINDIR)/peel
	@echo "Installed ~/Applications/Peel.app  (CLI: peel)"

test:
	swift test \
		-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
		-Xswiftc -F$(FWK) -Xlinker -F$(FWK) -Xlinker -rpath -Xlinker $(FWK)

run:
	swift run Peel gui

clean:
	rm -rf .build dist
