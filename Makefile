.PHONY: build app run test demo icon clean

build:
	swift build

app:
	./Scripts/build-app.sh

run: app
	open build/Groovie.app

test:
	swift build
	.build/debug/Groovie --self-test

demo: app
	./Scripts/capture-demo.sh

icon:
	./Scripts/make-app-icon.sh

clean:
	rm -rf .build build
