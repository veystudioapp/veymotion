.PHONY: build run bundle dmg clean

build:
	swift build

run: build
	swift run VeyMotion

bundle:
	bash scripts/bundle.sh

dmg: bundle
	bash scripts/dmg.sh

clean:
	rm -rf .build dist
