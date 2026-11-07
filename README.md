# Scarlett Zero
Pre-release alpha 

A utility for a Focusrite Scarlett 18i20 Gen 1 on macOS. 

With the arrival of macOS Tahoe 26, Focusrite halted support for the
Scarlett 18i20 1st Gen rackmount USB audio and MIDI interface. This
repo enables command line (Terminal) control of the 18i20.

It is a pre-release alpha, with many untested paths and experimental
architecture. Use at your own risk.

## Architecture

The USB transport lives in scarlett_core.c / scarlett_core.h: a small
C library that opens the 18i20 through IOKit and reads and writes its
controls. Two front ends share it:

* scarlett_ctl.c, the command line tool (and daemon), and
* macOS/, a native SwiftUI app that recreates Scarlett MixControl.

An optional Clojure Babashka program wraps the scarlett_ctl program.

## macOS app: Scarlett MixControl

A modern replacement for Focusrite's defunct MixControl, laid out the
same way: one window with the Mixer on top and the Routing, Device
and Monitor sections below.

* Mixer: 8 mix buses as mono or stereo mixes (tabs), 18 channel
  strips with source, pan/balance, fader, mute, solo, PFL and stereo
  link, and a mix output strip with destinations, Copy To…, and Stereo.
* Routing: all 20 outputs with MixControl's routing presets.
* Monitor: per-output controlled/muted/fixed buttons, level knob,
  Dim, Mute, L/R mute, pad, monitor presets.
* Device: connection, sample rate, sync source; "Release for CLI"
  hands the USB device to scarlett_ctl without quitting.
* File: Open/Save snapshots (.scarlettmix JSON), import legacy
  MixControl .18i20 files, Restore Factory Defaults, Clear All.

On connect the app adopts the device state (or your saved document if it
matches), then writes that state in full once — the 18i20's mixer matrix
reads back 0 dB after power-up no matter what it is actually doing, so
only written values can be trusted. Unverified hardware commands
(meters, front-panel HW Control, mono, Save to Hardware) sit behind
Settings ▸ "Enable experimental hardware features", off by default.

Build: open macOS/ScarlettMixControl.xcodeproj in Xcode and run, or

```
cd macOS
xcodegen            # only after editing project.yml
xcodebuild -scheme ScarlettMixControl -derivedDataPath build/DerivedData build
xcodebuild -scheme ScarlettMixControl -derivedDataPath build/DerivedData test
```

The app and scarlett_ctl can't hold the device at the same time.

## C program scarlett_ctl

scarlett_ctl — Focusrite Scarlett 18i20 Gen 1 control

One-shot:
  scarlett_ctl ping
  scarlett_ctl doctor
  scarlett_ctl dump
  scarlett_ctl clock [1|2|3]
  scarlett_ctl rate
  scarlett_ctl route [OUT SRC]
  scarlett_ctl bus    [BUS RAW]
  scarlett_ctl mixer  [SLOT SRC]
  scarlett_ctl matrix [NODE RAW]
  scarlett_ctl save confirm

Daemon (newline-delimited same grammar on stdin, EDN on stdout):
  scarlett_ctl daemon
    additional: ping, quit

Writes take raw signed int16. 0x0000 = 0 dB, 0x8000 = silence.

## Babashka script

([Babashka](https://babashka.org) is a fast-starting Clojure scripting
environment that allows you to run Clojure scripts quickly without the
overhead of the JVM, making it ideal for command line scripting.)

```
% bb scarlett dump
```

### Docs
scarlett — Focusrite Scarlett 18i20 Gen 1 control (Babashka frontend)

Usage:
  scarlett dump [--edn]              Full state dump
  scarlett clock [<source>]          Read or set clock (internal|spdif|adat)
  scarlett rate                      Read current sample rate
  scarlett route [<out> <src>]       Read all routes, or set one
  scarlett bus                       Read all bus volumes
  scarlett mixer                     Read mixer-input assignments
  scarlett matrix                    Read non-silent matrix gains
  scarlett save                      Persist current state to flash
  scarlett doctor                    Device health + competing processes

  scarlett preset save <path>        Dump current state to an EDN file
  scarlett preset diff <path>        Show commands to reach preset state
  scarlett preset apply <path>       Apply a preset to the device

Flags:
  --edn                              Emit raw EDN instead of formatted text

Outputs use keywords; e.g. :mon-l, :daw-1, :anlg-3, :spdif-l,
:adat-in-N (as source), :adat-N (as output/bus), :mix-1..10, :off.

## Bugs

* Does not write config to non-volatile memory.
* Mixer level input not tested.

## Todo

* Mixer input research and testing: The input values are guesses. 
* Write to non-volatile memory
* Testing
* Verify the experimental commands (meters, HW Control, mono, save)

## Build notes

Build the CLI with:

```
cc -o scarlett_ctl scarlett_ctl.c scarlett_core.c -framework IOKit -framework CoreFoundation
```

Built and tested on macOS Tahoe 26.3 with Apple clang version 17.0.0 (clang-1700.6.4.2).
The macOS app was built with Xcode 27 on macOS 26.6.
The binary is provided for my convenience.

scarlett-18i20-project-brief.md is the Claude design doc

Claude Code was used to write the software. 
