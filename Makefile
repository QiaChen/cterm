.PHONY: build test run debug clean icon

build:
	./build.sh

test:
	swift test

run: build
	open dist/cTerm.app

debug:
	swift build

clean:
	rm -rf .build dist

icon:
	python3 scripts/make_icon.py
	iconutil -c icns Resources/cTerm.iconset -o Resources/cTerm.icns
