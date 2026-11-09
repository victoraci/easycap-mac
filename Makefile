# /usr/bin/clang (Xcode, SDK 26.4) und das CLT-SDK 27.0 vertragen sich nicht,
# deshalb CLT-Compiler + CLT-SDK explizit.
CC      = /Library/Developer/CommandLineTools/usr/bin/clang
SDK     = /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk
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

# TAPR.app: Mac-Fenster mit Live-Bild, Doppelklick startet. hw.c laeuft direkt in der App.
# libusb ist fest eingebaut (.a), damit ein brew-Update die App nicht kaputt macht.
# Nicht in "all", damit "make" fuer die Terminal-Tools genauso schnell bleibt wie bisher.
APP_SWIFT = tapr/TAPRApp.swift tapr/Stick.swift tapr/Regler.swift tapr/Bild.swift tapr/Aufnahme.swift

app: TAPR.app

TAPR.app: $(APP_SWIFT) tapr/kern.c tapr/kern.h hw.c hw.h tapr/Info.plist tapr/Inter.woff2
	rm -rf $@ tapr/build
	mkdir -p tapr/build $@/Contents/MacOS $@/Contents/Resources
	$(CC) $(CFLAGS) -I/opt/homebrew/include/libusb-1.0 -c hw.c -o tapr/build/hw.o
	$(CC) $(CFLAGS) -I/opt/homebrew/include/libusb-1.0 -c tapr/kern.c -o tapr/build/kern.o
	$(SWIFTC) -sdk $(SDK) -O -swift-version 5 -import-objc-header tapr/kern.h $(APP_SWIFT) \
		tapr/build/hw.o tapr/build/kern.o /opt/homebrew/lib/libusb-1.0.a \
		-framework IOKit -framework CoreFoundation -framework Security \
		-o $@/Contents/MacOS/TAPR
	cp tapr/Info.plist $@/Contents/
	cp tapr/Inter.woff2 $@/Contents/Resources/
	codesign --force -s - $@

clean:
	rm -f dump_desc chipid streamtest ezcap
	rm -rf TAPR.app tapr/build
