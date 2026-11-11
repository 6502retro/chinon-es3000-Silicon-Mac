# Chinon ES-3000 for Apple Silicon Macs

Download, convert, and control a **Chinon ES-3000** (1995) digital camera from a modern Mac.
A native SwiftUI app for Apple Silicon (it builds for Intel Macs too): no Python, no Terminal,
no shell scripts, no virtual machine, and no original software needed.

This is a Swift port of [chinon-es3000-windows](https://github.com/lustrinomatt/chinon-es3000-windows)
by mdlustri, who reverse-engineered the camera's serial protocol and its `.DCT` image format from
the original 1995 driver and serial captures.

Not tested with the other OEM models: Dakota DCC 9500, Dycam 10-C, Kodak DC50 zoom, and Promaster Digital One.

## What it does

* Finds the camera on any USB serial adapter automatically (`/dev/cu.usbserial-*` and similar)
* Lists the pictures in the camera with their dates and a small preview (decoded from the
  camera's thumbnails)
* Downloads them as PNG, JPEG or TIFF, optionally keeping the original `.DCT` data;
  **Download New** skips pictures already in your folder
* Optional fast transfers at 115200 baud, with automatic fallback to 57600
* Converts old `.DCT` files saved by the original software: File ▸ Convert, drag them onto
  the window, or open them with the app from Finder
* Remote control: resolution, flash, focus, zoom, self-timer, take a picture, set the clock,
  erase all
* Lossless rotate (re-decodes from the `.DCT`), picture info, battery indicator
* Remembers your port, save folder and speed between runs
* Reads the camera's current settings, pictures left, and the date each photo was taken
  (downloaded files are named and time-stamped with it)

## You need

* The camera's PC serial cable (8-pin mini-DIN to DB9)
* A USB-to-RS232 (DB9) adapter. FTDI-based adapters work well.
* The camera switched on: slide the **lens cover** open and keep it open while connected.
* Xcode (free from the Mac App Store) to build the app once. macOS 13 Ventura or later.

## Building the app

1. Open `ChinonES3000.xcodeproj` in Xcode.
2. Choose **Product ▸ Archive**. In the Organizer that opens, click **Distribute App ▸ Custom ▸ Copy App**
   and save it. Drag **Chinon ES-3000.app** to your Applications folder.

   To just try it, press **⌘R** to build and run from Xcode.

The project signs the app to run locally, so no Apple developer account is needed.

## Quick start

1. Plug in the USB-serial adapter and connect the camera cable.
2. Slide the lens cover open.
3. Click **Connect**, then **Download New**. Photos go to `Pictures/Chinon ES-3000` unless
   you choose another folder.

## Memory cards

With a PC card inserted, the camera uses the card in place of its 1 MB internal memory, so
the app lists, downloads and erases the card's pictures over the same cable. The card must be
a linear flash card the camera accepts (ATA flash and CompactFlash adapters give **Er 1**).
Erasing a full card can take a few minutes.

## Sample photos

Taken with an ES-3000 and decoded with the original project's decoder, which this app's
decoder matches (unedited apart from rotation).

| Superfine (640×480) | Fine (640×480, rotated) |
|---|---|
| ![Superfine](docs/ES3000_20261105_225253_04_SF.png) | ![Fine](docs/ES3000_20261107_142014_F.png) |

| Normal (320×240) | Normal (320×240) |
|---|---|
| ![Normal](docs/ES3000_20261105_225253_09_N.png) | ![Normal](docs/ES3000_20261106_153327_N.png) |

## Docs

* [PROTOCOL.md](PROTOCOL.md): serial link, commands, packets, status bytes
* [DCT_FORMAT.md](DCT_FORMAT.md): the image file format and how the decoder works

## Files

| | |
|---|---|
| `ChinonES3000/Decoder.swift` + `chinon_params.json` | `.DCT` → image decoder, thumbnail decoder |
| `ChinonES3000/Camera.swift` | serial protocol |
| `ChinonES3000/SerialPort.swift` | termios serial port for macOS |
| `ChinonES3000/AppModel.swift`, `ContentView.swift`, `ChinonApp.swift` | the app |
| `ChinonES3000/ImageSupport.swift` | saving, rotating and displaying pictures |
| `tools/chinon_sniffer.py` | serial man-in-the-middle logger from the original reverse engineering |

## Status

* **Decoder:** output checked against the original Python decoder on all three resolutions and
  on thumbnails. A few pixels per picture differ by one brightness level (floating-point rounding).
* **Protocol:** connect, status, picture list, thumbnails, downloads and camera settings tested
  against a simulated camera.
* **Not yet verified:** building and running on a real Mac with a real camera and adapter. Bug
  reports welcome.

## Credits and notes

Protocol, image format, and decoder parameters: mdlustri,
[chinon-es3000-windows](https://github.com/lustrinomatt/chinon-es3000-windows) (MIT License).

This project contains no code or files from the original Chinon/Monsoon software. You
need your own camera and cable.
