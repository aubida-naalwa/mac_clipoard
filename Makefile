.PHONY: app run install icon clean

app:
	scripts/build-app.sh

run: app
	-pkill -x ClipHistory
	open build/ClipHistory.app

install: app
	-pkill -x ClipHistory
	rm -rf /Applications/ClipHistory.app
	cp -R build/ClipHistory.app /Applications/
	open /Applications/ClipHistory.app

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
