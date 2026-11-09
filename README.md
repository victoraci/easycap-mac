# easycap-mac

<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--2.0-%233fb950?labelColor=32383f" alt="License: GPL-2.0"></a>
  <img src="https://img.shields.io/badge/C-a8b9cc?logo=c&logoColor=white&labelColor=32383f" alt="C">
  <img src="https://img.shields.io/badge/Swift-f05138?logo=swift&logoColor=white&labelColor=32383f" alt="Swift">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white&labelColor=32383f" alt="macOS">
</p>

A user-space driver and macOS app for cheap EasyCAP USB video grabbers with the Empia EM2860 chip and a Philips SAA7113 decoder.

macOS has no driver for these sticks. This one talks to the hardware directly over libusb: no kernel extension, no changes to system security, no root. It was written from the SAA7113 datasheet and the Linux `em28xx` and `saa7115` drivers.

The picture is passed through as it comes from the tape. The decoder runs without sharpening or noise filters, both fields are kept (50 per second), and recordings are lossless. Made for digitizing VHS among other things.

<br/>

## Hardware

| | |
|---|---|
| USB ID | `eb1a:2861` |
| Bridge | Empia EM2860 |
| Decoder | Philips SAA7113 or the GM7113C clone |
| Input | Composite or S-Video, PAL |
| Output | 720 × 576, YUV 4:2:2, 25 frames / 50 fields per second |

Measured on the stick: isochronous transfer at 20.8 MB/s with 50 fields per second and no lost frames.

## What's in here

| | |
|---|---|
| `app/` | The macOS app, easycap (SwiftUI, Metal). Live picture, decoder controls, recording. |
| `hw.c` | The driver: EM2860 registers, I2C to the decoder, decoder setup, isochronous transfers. |
| `ezcap` | Command-line capture. Raw YUYV frames to stdout, decoder settings live from the keyboard. |
| `preview.sh` | Live preview in ffplay, 50 fields per second or raw interlaced. |
| `record.sh` | Lossless recording (FFV1 in MKV) with a live preview. |
| `streamtest` | Data rate, fields per second and transfer errors. |
| `chipid`, `dump_desc` | Read-only checks of the chip ID and USB descriptors via IOKit. |

## The app

- Live picture through a Metal shader with BT.601 limited-range color.
- Two views: Tube shows every field on its own, 50 times per second, like a CRT. Interlaced shows both fields woven into 25 frames.
- Decoder controls for color, hue and contrast, written straight to the SAA7113 registers while the picture runs.
- Glitch controls on the decoder's sync: lines calm, jittering or tearing; picture steady, jumping or rolling.
- 4:3 or 16:9 for anamorphic sources.
- Record, watch the take in a loop, then save or discard. Saving writes a lossless `.mkv` (FFV1) and a deinterlaced `.mp4` (H.264, 50p) to watch anywhere.

The keys from `ezcap` work in the app too, plus `r` to switch the view.

## Build

Requires macOS on Apple Silicon, the Xcode Command Line Tools and [Homebrew](https://brew.sh).

```bash
brew install libusb ffmpeg
git clone https://github.com/victoraci/easycap-mac.git
cd easycap-mac
make        # command-line tools
make app    # easycap.app
```

The app links libusb statically. ffmpeg is needed for recording.

## Use

```bash
./preview.sh            # live preview
./preview.sh raw        # both fields woven, 25 frames per second
./record.sh             # record to recordings/
./record.sh -s          # S-Video instead of composite
./ezcap -r 08=2c        # set a decoder register (hex) at start
```

Press `h` in the terminal for the list of live controls. Unplugging the stick resets everything. `record.sh` saves somewhere else with `OUT=/path ./record.sh`.

Recordings from `record.sh` are bit-exact copies of what the stick sends, checked frame by frame with MD5. Expect roughly 25 to 40 GB per hour.

Only one program can use the stick at a time: close the app before running the scripts, and the other way round.

## License

[GPL-2.0](LICENSE), like the Linux drivers this code is based on.
