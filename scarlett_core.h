/*
 * scarlett_core — USB transport for the Focusrite Scarlett 18i20 Gen 1.
 *
 * Shared by the scarlett_ctl CLI and the macOS app (macOS/). Bytes in,
 * bytes out: every value crossing this boundary is a raw device integer
 * (source ids, signed int16 gains). Symbolic names and dB live in the
 * callers.
 *
 * Wire constants are documented in scarlett-18i20-project-brief.md.
 * Functions tagged EXPERIMENTAL use requests recovered from the
 * MixControl 1.10.6 binary that have not been verified on hardware.
 *
 * Copyright 2026 Ben Wen. All rights reserved.
 */

#ifndef SCARLETT_CORE_H
#define SCARLETT_CORE_H

#include <stdint.h>
#include <IOKit/IOReturn.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SC_VENDOR_ID      0x1235
#define SC_PRODUCT_ID     0x800c

#define SC_NUM_OUTPUTS    20
#define SC_NUM_BUSES      21    /* bus 0 = master, 1–20 = outputs 0–19 */
#define SC_NUM_MIXER_INS  18
#define SC_NUM_MIX_BUSES  8
#define SC_MATRIX_NODES   144   /* 18 × 8. Node ≥ 144 pipe-stalls the device. */

#define SC_GAIN_SILENCE   ((int16_t)-32768)   /* 0x8000 = −inf */

/* Sentinels returned by typed reads on transfer failure. */
#define SC_READ_FAIL_ID   (-1)
#define SC_READ_FAIL_GAIN (-99999)

/* sc_open results. */
enum {
    SC_OK             =  0,
    SC_ERR_NOT_FOUND  = -1,
    SC_ERR_PLUGIN     = -2,
    SC_ERR_INTERFACE  = -3,
    SC_ERR_BUSY       = -4,   /* another process holds the device user client */
};

typedef struct sc_device sc_device;

/* ── Lifecycle ─────────────────────────────────────────── */

int  sc_present(void);                  /* 1 if the 18i20 is enumerated */
int  sc_open(sc_device **out);          /* SC_OK or SC_ERR_*            */
void sc_close(sc_device *dev);

/* ── Raw requests ──────────────────────────────────────── */

/* Class GET/SET CUR (bRequest 0x01). */
IOReturn sc_ctl_read (sc_device *dev, uint16_t wValue, uint16_t wIndex,
                      uint8_t *buf, uint16_t len);
IOReturn sc_ctl_write(sc_device *dev, uint16_t wValue, uint16_t wIndex,
                      const uint8_t *buf, uint16_t len);

/* Focusrite memory requests (bRequest 0x03, wIndex 0x3c00). */
IOReturn sc_mem_read (sc_device *dev, uint16_t addr, uint8_t *buf, uint16_t len);
IOReturn sc_mem_write(sc_device *dev, uint16_t addr, const uint8_t *buf, uint16_t len);

/* ── Verified reads ────────────────────────────────────── */

int sc_read_clock_source(sc_device *dev);          /* 1/2/3 or -1   */
int sc_read_sample_rate (sc_device *dev);          /* Hz or -1      */
int sc_read_route       (sc_device *dev, int output);
int sc_read_mixer_input (sc_device *dev, int slot);
int sc_read_bus_volume  (sc_device *dev, int bus); /* int16 or -9999  */
int sc_read_bus_mute    (sc_device *dev, int bus); /* int16 or -9999  */
int sc_read_matrix_gain (sc_device *dev, int node);/* int16 or -99999 */

/* ── Verified writes ───────────────────────────────────── */

IOReturn sc_write_clock_source(sc_device *dev, int source);
IOReturn sc_write_route       (sc_device *dev, int output, int source);
IOReturn sc_write_mixer_input (sc_device *dev, int slot, int source);
IOReturn sc_write_bus_volume  (sc_device *dev, int bus, int16_t raw);
IOReturn sc_write_matrix_gain (sc_device *dev, int node, int16_t raw);

/* ── EXPERIMENTAL (from MixControl disassembly) ────────── */

/* Bus mute (ctl wValue 0x0100+bus, wIndex 0x0a00) as a raw int16. The
 * control is really one byte (see sc_write_dac_mute); the old "always
 * 0x0b00" read-back was byte 0 = 0 (unmuted) plus a junk second byte. */
IOReturn sc_write_bus_mute(sc_device *dev, int bus, int16_t raw);

/* ── Monitor output sets (verified 2026-11-07) ─────────────
 * Bit n = analog output n (0 = Mon 1 … 9 = Line 10).
 *
 * Knob set (mem 0x0a, 4 bytes LE): outputs the FIRMWARE attenuates by the
 * front MONITOR knob, standalone, with no host involved. MixControl's
 * HW Control writes its "controlled" outputs here when on and 0 when off.
 * Flash ships with outputs 1–6 set, which is why Line 3–6 sound dead with
 * the knob turned down.
 *
 * Button set (mem 0x0b and 0x0c, same mask): MixControl always writes the
 * controlled outputs here; presumably the outputs the front MUTE/DIM act on.
 *
 * DAC mute (ctl 0x0100+output+1 @ 0x0a00, 1 byte): 1 = muted. MixControl's
 * red output buttons and L/R mutes.                                       */
IOReturn sc_write_monitor_knob_set  (sc_device *dev, uint32_t mask);
IOReturn sc_write_monitor_button_set(sc_device *dev, uint32_t mask);
IOReturn sc_write_dac_mute(sc_device *dev, int output, int muted);   /* output 0–9 */
int      sc_read_dac_mute (sc_device *dev, int output);              /* 0/1, or -1 */

/* Persist current state to flash: memory addr 0x5a ← 0xa5. */
IOReturn sc_save_to_flash(sc_device *dev);

/* Level meters. Each value is the device's u16 shifted right by 4
   (12-bit linear, full scale 4095). Returns the number of values
   written to out, or -1 on failure.
     sc_read_meters_inputs: 18 hardware inputs (anlg 1–8, spdif L/R, adat 1–8)
     sc_read_meters_daw:    20 DAW playback channels
     sc_read_meters_mixes:   8 mix bus outputs                            */
int sc_read_meters_inputs(sc_device *dev, uint16_t out[18]);
int sc_read_meters_daw   (sc_device *dev, uint16_t out[20]);
int sc_read_meters_mixes (sc_device *dev, uint16_t out[8]);

/* Front-panel monitor state (memory addr 0x04, 4 bytes).
   knob_atten_db: attenuation in whole dB (gain = −value). */
typedef struct {
    int knob_atten_db;
    int mute;
    int dim;
} sc_monitor_state;

int sc_read_monitor_state(sc_device *dev, sc_monitor_state *out);  /* 0 ok, -1 fail */

/* Mono-sum an analog output pair (pair 1–5 → outputs 1+2 … 9+10). */
IOReturn sc_write_monitor_mono(sc_device *dev, int pair, int on);

#ifdef __cplusplus
}
#endif

#endif /* SCARLETT_CORE_H */
