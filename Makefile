.PHONY: build app run test demo icon l10n-check clean

build:
	swift build

app:
	./Scripts/build-app.sh

run: app
	open build/Groovie.app

test:
	swift build
	.build/debug/Groovie --self-test
	swift Scripts/check-localizations.swift Sources/GroovieKit/Resources/Localization

demo: app
	./Scripts/capture-demo.sh

icon:
	./Scripts/make-app-icon.sh

l10n-check:
	swift Scripts/check-localizations.swift Sources/GroovieKit/Resources/Localization

clean:
	rm -rf .build build
