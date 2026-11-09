# /usr/bin/clang (Xcode) and the Command Line Tools SDK don't always get along,
# so the CLT compiler + CLT SDK are set explicitly.
CC      = /Library/Developer/CommandLineTools/usr/bin/clang
SDK     = /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
CFLAGS  = -isysroot $(SDK) -Wall -O2 -Wno-deprecated-declarations
IOKIT   = -framework IOKit -framework CoreFoundation
LIBUSB  = -I/opt/homebrew/include/libusb-1.0 -L/opt/homebrew/lib -lusb-1.0
SWIFTC  = /Library/Developer/CommandLineTools/usr/bin/swiftc

all: dump_desc chipid streamtest ezcap

.PHONY: all app clean

dump_desc: dump_desc.c
	$(CC) $(CFLAGS) $(IOKIT) $< -o $@

chipid: chipid.c
	$(CC) $(CFLAGS) $(IOKIT) $< -o $@

streamtest: streamtest.c hw.c hw.h
	$(CC) $(CFLAGS) streamtest.c hw.c $(LIBUSB) -o $@

ezcap: ezcap.c hw.c hw.h
	$(CC) $(CFLAGS) ezcap.c hw.c $(LIBUSB) -o $@

# easycap.app: Mac window with the live picture, starts with a double-click. hw.c runs inside the app.
# libusb is built in (.a), so a brew update can't break the app.
# Not part of "all", so "make" stays as fast as before for the terminal tools.
APP_SWIFT = app/EasycapApp.swift app/Stick.swift app/Controls.swift app/LiveView.swift app/Recorder.swift

app: easycap.app

easycap.app: $(APP_SWIFT) app/core.c app/core.h hw.c hw.h app/Info.plist app/Inter.woff2
	rm -rf $@ app/build
	mkdir -p app/build $@/Contents/MacOS $@/Contents/Resources
	$(CC) $(CFLAGS) -I/opt/homebrew/include/libusb-1.0 -c hw.c -o app/build/hw.o
	$(CC) $(CFLAGS) -I/opt/homebrew/include/libusb-1.0 -c app/core.c -o app/build/core.o
	$(SWIFTC) -sdk $(SDK) -O -swift-version 5 -import-objc-header app/core.h $(APP_SWIFT) \
		app/build/hw.o app/build/core.o /opt/homebrew/lib/libusb-1.0.a \
		-framework IOKit -framework CoreFoundation -framework Security \
		-o $@/Contents/MacOS/easycap
	cp app/Info.plist $@/Contents/
	cp app/Inter.woff2 $@/Contents/Resources/
	codesign --force -s - $@

clean:
	rm -f dump_desc chipid streamtest ezcap
	rm -rf easycap.app app/build
