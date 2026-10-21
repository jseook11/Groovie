.PHONY: build app run test demo clean

build:
	swift build

app:
	./Scripts/build-app.sh

run: app
	open build/NotchVinyl.app

test:
	swift build
	.build/debug/NotchVinyl --self-test

demo: app
	./Scripts/capture-demo.sh

clean:
	rm -rf .build build
