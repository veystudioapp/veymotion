.PHONY: build run bundle dmg release clean

build:
	swift build

run: build
	swift run VeyMotion

bundle:
	bash scripts/bundle.sh

dmg: bundle
	bash scripts/dmg.sh

release:
	bash scripts/release.sh

clean:
	rm -rf .build dist
