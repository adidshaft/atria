# Overview & Goals

## Goal

Talk to my own WHOOP strap directly over Bluetooth LE and build a custom iOS app
that surfaces the data I care about — independent of the official WHOOP app/cloud.

Concretely:

1. **Read live sensor data** — heart rate first, then raw streams.
2. **Map the proprietary protocol** — understand the custom BLE service so we can
   request data the standard profiles don't expose.
3. **Repurpose the hardware** — drive it from my own software.

## Principles

- **Read before write.** Enumerate and subscribe (safe) before ever writing to a
  characteristic (can misconfigure/brick). No blind writes.
- **Build on what's solid.** The standard BLE Heart Rate service works with zero
  reverse engineering — ship that first, instrument the proprietary parts for later.
- **Own hardware only.** This is my device; everything here is on hardware I own.

## Current status

| Goal | Status |
|---|---|
| Read live sensor data | ✅ Live HR + battery in the iOS app |
| Map the protocol | 🔬 Framing decoded; payload fields in progress |
| Repurpose hardware | ⏳ Depends on protocol decoding |
