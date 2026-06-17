.PHONY: run install build test clean

run:
	./scripts/run.sh

install:
	./scripts/install_app.sh

build:
	./scripts/build_app.sh

test:
	swift test

clean:
	rm -rf .build Assets/AppIcon.icns Assets/AppIcon.iconset
