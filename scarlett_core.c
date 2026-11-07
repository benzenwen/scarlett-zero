/*
 * scarlett_core — USB transport for the Focusrite Scarlett 18i20 Gen 1.
 * See scarlett_core.h.
 *
 * Copyright 2026 Ben Wen. All rights reserved.
 */

#include "scarlett_core.h"

#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#define MIXER_WINDEX 0x3c00

struct sc_device {
    IOUSBDeviceInterface **dev;
};

/* ── Lifecycle ─────────────────────────────────────────── */

static io_service_t find_service(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return 0;

    int32_t vid = SC_VENDOR_ID, pid = SC_PRODUCT_ID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"),  v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);

    /* Consumes one reference to match. */
    return IOServiceGetMatchingService(kIOMainPortDefault, match);
}

int sc_present(void) {
    io_service_t svc = find_service();
    if (!svc) return 0;
    IOObjectRelease(svc);
    return 1;
}

int sc_open(sc_device **out) {
    *out = NULL;
    io_service_t svc = find_service();
    if (!svc) return SC_ERR_NOT_FOUND;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc,
        kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plug) return SC_ERR_PLUGIN;

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return SC_ERR_INTERFACE;

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != KERN_SUCCESS) {
        (*dev)->Release(dev);
        return SC_ERR_BUSY;
    }

    sc_device *h = malloc(sizeof *h);
    if (!h) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return SC_ERR_INTERFACE;
    }
    h->dev = dev;
    *out = h;
    return SC_OK;
}

void sc_close(sc_device *h) {
    if (!h) return;
    (*h->dev)->USBDeviceClose(h->dev);
    (*h->dev)->Release(h->dev);
    free(h);
}

/* ── Raw requests ──────────────────────────────────────── */

static IOReturn request(sc_device *h, uint8_t type, uint8_t req,
                        uint16_t wValue, uint16_t wIndex,
                        void *buf, uint16_t len) {
    IOUSBDevRequest r = {
        .bmRequestType = type, .bRequest = req,
        .wValue = wValue, .wIndex = wIndex,
        .wLength = len, .pData = buf
    };
    return (*h->dev)->DeviceRequest(h->dev, &r);
}

IOReturn sc_ctl_read(sc_device *h, uint16_t wValue, uint16_t wIndex,
                     uint8_t *buf, uint16_t len) {
    return request(h, 0xA1, 0x01, wValue, wIndex, buf, len);
}

IOReturn sc_ctl_write(sc_device *h, uint16_t wValue, uint16_t wIndex,
                      const uint8_t *buf, uint16_t len) {
    return request(h, 0x21, 0x01, wValue, wIndex, (void *)buf, len);
}

IOReturn sc_mem_read(sc_device *h, uint16_t addr, uint8_t *buf, uint16_t len) {
    return request(h, 0xA1, 0x03, addr, MIXER_WINDEX, buf, len);
}

IOReturn sc_mem_write(sc_device *h, uint16_t addr, const uint8_t *buf, uint16_t len) {
    return request(h, 0x21, 0x03, addr, MIXER_WINDEX, (void *)buf, len);
}

/* ── Verified reads ────────────────────────────────────── */

static int read_i16(sc_device *h, uint16_t wValue, uint16_t wIndex, int fail) {
    uint8_t buf[2] = {0};
    if (sc_ctl_read(h, wValue, wIndex, buf, 2) != KERN_SUCCESS) return fail;
    return (int16_t)(buf[0] | (buf[1] << 8));
}

static int read_id(sc_device *h, uint16_t wValue, uint16_t wIndex) {
    uint8_t buf[2] = {0};
    if (sc_ctl_read(h, wValue, wIndex, buf, 2) != KERN_SUCCESS) return SC_READ_FAIL_ID;
    return buf[0];
}

int sc_read_clock_source(sc_device *h) {
    uint8_t buf = 0;
    if (sc_ctl_read(h, 0x0100, 0x2800, &buf, 1) != KERN_SUCCESS) return SC_READ_FAIL_ID;
    return buf;
}

int sc_read_sample_rate(sc_device *h) {
    uint8_t buf[4] = {0};
    if (sc_ctl_read(h, 0x0100, 0x2900, buf, 4) != KERN_SUCCESS) return SC_READ_FAIL_ID;
    return buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
}

int sc_read_route(sc_device *h, int output) {
    return read_id(h, (uint16_t)output, 0x3300);
}

int sc_read_mixer_input(sc_device *h, int slot) {
    return read_id(h, (uint16_t)(0x0600 + slot), 0x3200);
}

int sc_read_bus_volume(sc_device *h, int bus) {
    return read_i16(h, (uint16_t)(0x0200 + bus), 0x0a00, -9999);
}

int sc_read_bus_mute(sc_device *h, int bus) {
    return read_i16(h, (uint16_t)(0x0100 + bus), 0x0a00, -9999);
}

int sc_read_matrix_gain(sc_device *h, int node) {
    if (node < 0 || node >= SC_MATRIX_NODES) return SC_READ_FAIL_GAIN;
    return read_i16(h, (uint16_t)node, MIXER_WINDEX, SC_READ_FAIL_GAIN);
}

/* ── Verified writes ───────────────────────────────────── */

static IOReturn write_i16(sc_device *h, uint16_t wValue, uint16_t wIndex, int16_t val) {
    uint8_t buf[2] = {(uint8_t)(val & 0xff), (uint8_t)((val >> 8) & 0xff)};
    return sc_ctl_write(h, wValue, wIndex, buf, 2);
}

IOReturn sc_write_clock_source(sc_device *h, int source) {
    if (source < 1 || source > 3) return kIOReturnBadArgument;
    uint8_t buf = (uint8_t)source;
    return sc_ctl_write(h, 0x0100, 0x2800, &buf, 1);
}

IOReturn sc_write_route(sc_device *h, int output, int source) {
    if (output < 0 || output >= SC_NUM_OUTPUTS) return kIOReturnBadArgument;
    uint8_t buf[2] = {(uint8_t)source, 0x00};
    return sc_ctl_write(h, (uint16_t)output, 0x3300, buf, 2);
}

IOReturn sc_write_mixer_input(sc_device *h, int slot, int source) {
    if (slot < 0 || slot >= SC_NUM_MIXER_INS) return kIOReturnBadArgument;
    uint8_t buf[2] = {(uint8_t)source, 0x00};
    return sc_ctl_write(h, (uint16_t)(0x0600 + slot), 0x3200, buf, 2);
}

IOReturn sc_write_bus_volume(sc_device *h, int bus, int16_t raw) {
    if (bus < 0 || bus >= SC_NUM_BUSES) return kIOReturnBadArgument;
    return write_i16(h, (uint16_t)(0x0200 + bus), 0x0a00, raw);
}

IOReturn sc_write_matrix_gain(sc_device *h, int node, int16_t raw) {
    if (node < 0 || node >= SC_MATRIX_NODES) return kIOReturnBadArgument;
    return write_i16(h, (uint16_t)node, MIXER_WINDEX, raw);
}

IOReturn sc_write_bus_mute(sc_device *h, int bus, int16_t raw) {
    if (bus < 0 || bus >= SC_NUM_BUSES) return kIOReturnBadArgument;
    return write_i16(h, (uint16_t)(0x0100 + bus), 0x0a00, raw);
}

static IOReturn write_mask(sc_device *h, uint16_t addr, uint32_t mask) {
    uint8_t buf[4] = { mask & 0xff, (mask >> 8) & 0xff, (mask >> 16) & 0xff, (mask >> 24) & 0xff };
    return sc_mem_write(h, addr, buf, 4);
}

IOReturn sc_write_monitor_knob_set(sc_device *h, uint32_t mask) {
    return write_mask(h, 0x000a, mask & 0x3ff);
}

IOReturn sc_write_monitor_button_set(sc_device *h, uint32_t mask) {
    IOReturn r = write_mask(h, 0x000b, mask & 0x3ff);
    return r != KERN_SUCCESS ? r : write_mask(h, 0x000c, mask & 0x3ff);
}

IOReturn sc_write_dac_mute(sc_device *h, int output, int muted) {
    if (output < 0 || output > 9) return kIOReturnBadArgument;
    uint8_t b = muted ? 1 : 0;
    return sc_ctl_write(h, (uint16_t)(0x0101 + output), 0x0a00, &b, 1);
}

int sc_read_dac_mute(sc_device *h, int output) {
    if (output < 0 || output > 9) return -1;
    uint8_t b = 0;
    if (sc_ctl_read(h, (uint16_t)(0x0101 + output), 0x0a00, &b, 1) != KERN_SUCCESS) return -1;
    return b;
}

/* ── EXPERIMENTAL ──────────────────────────────────────── */

IOReturn sc_save_to_flash(sc_device *h) {
    uint8_t buf[1] = {0xa5};
    return sc_mem_write(h, 0x005a, buf, 1);
}

static int read_meters(sc_device *h, uint16_t sel, uint16_t *out, int n) {
    uint8_t buf[64] = {0};
    if (sc_mem_read(h, sel, buf, (uint16_t)(2 * n)) != KERN_SUCCESS) return -1;
    for (int i = 0; i < n; i++)
        out[i] = (uint16_t)(buf[2 * i] | (buf[2 * i + 1] << 8)) >> 4;
    return n;
}

int sc_read_meters_inputs(sc_device *h, uint16_t out[18]) { return read_meters(h, 0, out, 18); }
int sc_read_meters_mixes (sc_device *h, uint16_t out[8])  { return read_meters(h, 1, out, 8);  }
int sc_read_meters_daw   (sc_device *h, uint16_t out[20]) { return read_meters(h, 3, out, 20); }

int sc_read_monitor_state(sc_device *h, sc_monitor_state *out) {
    uint8_t buf[4] = {0};
    if (sc_mem_read(h, 0x0004, buf, 4) != KERN_SUCCESS) return -1;
    out->knob_atten_db = buf[0];
    out->mute = buf[2] != 0;
    out->dim  = buf[3] != 0;
    return 0;
}

IOReturn sc_write_monitor_mono(sc_device *h, int pair, int on) {
    if (pair < 1 || pair > 5) return kIOReturnBadArgument;
    uint8_t buf = on ? 1 : 0;
    return sc_ctl_write(h, (uint16_t)(0x0A00 | pair), 0x1400, &buf, 1);
}
