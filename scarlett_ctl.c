/*
 * scarlett_ctl — Unified control tool for Focusrite Scarlett 18i20 Gen 1
 *
 * Communicates via IOKit DeviceRequest (device-level USB control transfers).
 * All output is EDN (Extensible Data Notation) for consumption by Babashka.
 *
 * Usage:
 *   scarlett_ctl dump                  Full state dump
 *   scarlett_ctl clock                 Read clock source & sample rate
 *   scarlett_ctl clock <1|2|3>         Set clock (1=internal, 2=spdif, 3=adat)
 *   scarlett_ctl rate                  Read sample rate
 *   scarlett_ctl route                 Read all output routing
 *   scarlett_ctl route <out> <src>     Set output route (numeric IDs)
 *   scarlett_ctl bus                   Read all bus volumes & mutes
 *   scarlett_ctl mixer                 Read mixer input assignments
 *   scarlett_ctl matrix                Read matrix gains (non-silent)
 *   scarlett_ctl save                  Persist state to hardware flash
 *   scarlett_ctl doctor                Check device & competing processes
 *
 * Compile:
 *   cc -o scarlett_ctl scarlett_ctl.c -framework IOKit -framework CoreFoundation
 *
 * Copyright 2026 Ben Wen. All rights reserved.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#define VENDOR_ID  0x1235
#define PRODUCT_ID 0x800c

#define NUM_OUTPUTS     20
#define NUM_BUSES       21
#define NUM_MIXER_INS   18
#define MATRIX_NODES    144  /* 18 inputs × 8 mix buses, indices 0–143 */

/* ── Device handle ─────────────────────────────────────── */

static IOUSBDeviceInterface **g_dev = NULL;

static int device_open(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return -1;

    CFDictionarySetValue(match, CFSTR("idVendor"),
        CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){VENDOR_ID}));
    CFDictionarySetValue(match, CFSTR("idProduct"),
        CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){PRODUCT_ID}));

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) return -1;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc,
        kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plug) return -2;

    (*plug)->QueryInterface(plug,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&g_dev);
    (*plug)->Release(plug);
    if (!g_dev) return -3;

    kr = (*g_dev)->USBDeviceOpen(g_dev);
    if (kr != KERN_SUCCESS) return -4;

    return 0;
}

static void device_close(void) {
    if (g_dev) {
        (*g_dev)->USBDeviceClose(g_dev);
        (*g_dev)->Release(g_dev);
        g_dev = NULL;
    }
}

/* ── Low-level read/write ──────────────────────────────── */

static kern_return_t ctl_read(uint16_t wValue, uint16_t wIndex,
                              uint8_t *buf, uint16_t len) {
    IOUSBDevRequest req = {
        .bmRequestType = 0xA1, .bRequest = 0x01,
        .wValue = wValue, .wIndex = wIndex,
        .wLength = len, .pData = buf
    };
    return (*g_dev)->DeviceRequest(g_dev, &req);
}

static kern_return_t ctl_write(uint16_t wValue, uint16_t wIndex,
                               uint8_t *buf, uint16_t len) {
    IOUSBDevRequest req = {
        .bmRequestType = 0x21, .bRequest = 0x01,
        .wValue = wValue, .wIndex = wIndex,
        .wLength = len, .pData = buf
    };
    return (*g_dev)->DeviceRequest(g_dev, &req);
}

/* ── Read helpers ──────────────────────────────────────── */

static int read_clock_source(void) {
    uint8_t buf = 0;
    if (ctl_read(0x0100, 0x2800, &buf, 1) != KERN_SUCCESS) return -1;
    return buf;
}

static int read_sample_rate(void) {
    uint8_t buf[4] = {0};
    if (ctl_read(0x0100, 0x2900, buf, 4) != KERN_SUCCESS) return -1;
    return buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
}

static int read_route(int output) {
    uint8_t buf[2] = {0};
    if (ctl_read(output, 0x3300, buf, 2) != KERN_SUCCESS) return -1;
    return buf[0];
}

static int read_bus_volume(int bus) {
    uint8_t buf[2] = {0};
    if (ctl_read(0x0200 + bus, 0x0a00, buf, 2) != KERN_SUCCESS) return -9999;
    return (int16_t)(buf[0] | (buf[1] << 8));
}

static int read_bus_mute(int bus) {
    uint8_t buf[2] = {0};
    if (ctl_read(0x0100 + bus, 0x0a00, buf, 2) != KERN_SUCCESS) return -9999;
    return (int16_t)(buf[0] | (buf[1] << 8));
}

static int read_mixer_input(int slot) {
    uint8_t buf[2] = {0};
    if (ctl_read(0x0600 + slot, 0x3200, buf, 2) != KERN_SUCCESS) return -1;
    return buf[0];
}

static int read_matrix_gain(int node) {
    uint8_t buf[2] = {0};
    kern_return_t kr = ctl_read(node, 0x3c00, buf, 2);
    if (kr != KERN_SUCCESS) return -99999;
    return (int16_t)(buf[0] | (buf[1] << 8));
}

/* ── EDN output helpers ────────────────────────────────── */

static void edn_error(const char *msg) {
    printf("{:error \"%s\"}\n", msg);
}

/* ── Commands ──────────────────────────────────────────── */

static void cmd_clock(int argc, char **argv) {
    if (argc > 2) {
        /* Write clock source */
        int val = atoi(argv[2]);
        if (val < 1 || val > 3) {
            edn_error("clock value must be 1 (internal), 2 (spdif), or 3 (adat)");
            return;
        }
        uint8_t buf = (uint8_t)val;
        kern_return_t kr = ctl_write(0x0100, 0x2800, &buf, 1);
        if (kr != KERN_SUCCESS) {
            printf("{:error \"write failed\" :code %d}\n", kr);
            return;
        }
        /* Read back to confirm */
        int readback = read_clock_source();
        printf("{:ok true :source %d}\n", readback);
    } else {
        /* Read clock source + rate */
        int src = read_clock_source();
        int rate = read_sample_rate();
        if (src < 0 || rate < 0) {
            edn_error("read failed");
            return;
        }
        printf("{:source %d :rate %d}\n", src, rate);
    }
}

static void cmd_rate(void) {
    int rate = read_sample_rate();
    if (rate < 0) { edn_error("read failed"); return; }
    printf("{:rate %d}\n", rate);
}

static void cmd_route(int argc, char **argv) {
    if (argc > 3) {
        /* Write route */
        int out = atoi(argv[2]);
        int src = (int)strtol(argv[3], NULL, 0);  /* accept hex or decimal */
        if (out < 0 || out >= NUM_OUTPUTS) {
            edn_error("output index must be 0-19");
            return;
        }

        /* Read before */
        int before = read_route(out);

        /* Write */
        uint8_t buf[2] = {(uint8_t)src, 0x00};
        kern_return_t kr = ctl_write(out, 0x3300, buf, 2);
        if (kr != KERN_SUCCESS) {
            printf("{:error \"write failed\" :code %d}\n", kr);
            return;
        }

        /* Read back */
        int after = read_route(out);
        printf("{:ok true :output %d :before %d :after %d}\n", out, before, after);
    } else {
        /* Read all routes */
        printf("{");
        for (int i = 0; i < NUM_OUTPUTS; i++) {
            int src = read_route(i);
            if (src < 0) continue;
            printf("%s%d %d", i > 0 ? " " : "", i, src);
        }
        printf("}\n");
    }
}

static void cmd_bus(void) {
    printf("{");
    for (int i = 0; i < NUM_BUSES; i++) {
        int vol = read_bus_volume(i);
        int mute = read_bus_mute(i);
        if (vol == -9999) continue;
        printf("%s%d {:volume %d :mute %d}",
               i > 0 ? " " : "", i, vol, mute);
    }
    printf("}\n");
}

static void cmd_mixer(void) {
    printf("{");
    for (int i = 0; i < NUM_MIXER_INS; i++) {
        int src = read_mixer_input(i);
        if (src < 0) continue;
        printf("%s%d %d", i > 0 ? " " : "", i, src);
    }
    printf("}\n");
}

static void cmd_matrix(void) {
    printf("{");
    int first = 1;
    for (int node = 0; node < MATRIX_NODES; node++) {
        int val = read_matrix_gain(node);
        if (val == -99999) break;  /* stall, stop */
        if (val == (int16_t)0x8000) continue;  /* -inf, skip */
        printf("%s%d %d", first ? "" : " ", node, val);
        first = 0;
    }
    printf("}\n");
}

static void cmd_dump(void) {
    int clk = read_clock_source();
    int rate = read_sample_rate();

    printf("{:clock {:source %d :rate %d}\n", clk, rate);

    /* Routing */
    printf(" :routing {");
    for (int i = 0; i < NUM_OUTPUTS; i++) {
        int src = read_route(i);
        if (src < 0) continue;
        printf("%s%d %d", i > 0 ? " " : "", i, src);
    }
    printf("}\n");

    /* Buses */
    printf(" :buses {");
    for (int i = 0; i < NUM_BUSES; i++) {
        int vol = read_bus_volume(i);
        int mute = read_bus_mute(i);
        if (vol == -9999) continue;
        printf("%s%d {:volume %d :mute %d}",
               i > 0 ? "\n         " : "", i, vol, mute);
    }
    printf("}\n");

    /* Mixer inputs */
    printf(" :mixer-inputs {");
    for (int i = 0; i < NUM_MIXER_INS; i++) {
        int src = read_mixer_input(i);
        if (src < 0) continue;
        printf("%s%d %d", i > 0 ? " " : "", i, src);
    }
    printf("}\n");

    /* Matrix */
    printf(" :matrix {");
    int first = 1;
    for (int node = 0; node < MATRIX_NODES; node++) {
        int val = read_matrix_gain(node);
        if (val == -99999) break;
        if (val == (int16_t)0x8000) continue;
        printf("%s%d %d", first ? "" : " ", node, val);
        first = 0;
    }
    printf("}}\n");
}

static void cmd_save(void) {
    uint8_t buf[1] = {0xa5};
    IOUSBDevRequest req = {
        .bmRequestType = 0x21,
        .bRequest      = 0x03,
        .wValue        = 0x005a,
        .wIndex        = 0x3c00,
        .wLength       = 1,
        .pData         = buf
    };
    kern_return_t kr = (*g_dev)->DeviceRequest(g_dev, &req);
    if (kr == KERN_SUCCESS)
        printf("{:ok true}\n");
    else
        printf("{:error \"save failed\" :code %d}\n", kr);
}

static void cmd_doctor(void) {
    printf("{:device ");

    /* Check if device exists */
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    CFDictionarySetValue(match, CFSTR("idVendor"),
        CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){VENDOR_ID}));
    CFDictionarySetValue(match, CFSTR("idProduct"),
        CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){PRODUCT_ID}));
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);

    if (!svc) {
        printf("{:found false}");
    } else {
        printf("{:found true}");
        IOObjectRelease(svc);
    }

    /* Check for competing processes */
    printf("\n :blockers [");
    FILE *fp = popen(
        "ps aux 2>/dev/null | grep -i -E 'FocusriteControl|MIDIServer' "
        "| grep -v grep | awk '{print $11}' | tr '\\n' ' '", "r");
    if (fp) {
        char line[512] = {0};
        if (fgets(line, sizeof(line), fp)) {
            /* Trim and wrap each process name as a string */
            char *tok = strtok(line, " \t\n");
            int first = 1;
            while (tok) {
                printf("%s\"%s\"", first ? "" : " ", tok);
                first = 0;
                tok = strtok(NULL, " \t\n");
            }
        }
        pclose(fp);
    }
    printf("]");

    /* Check Chrome */
    fp = popen(
        "ps aux 2>/dev/null | grep -i 'Google Chrome' "
        "| grep -v grep | head -1 | awk '{print $2}'", "r");
    if (fp) {
        char pid[32] = {0};
        if (fgets(pid, sizeof(pid), fp) && strlen(pid) > 1) {
            printf("\n :chrome-running true");
        } else {
            printf("\n :chrome-running false");
        }
        pclose(fp);
    }

    /* Try a test read */
    if (g_dev) {
        int clk = read_clock_source();
        printf("\n :readable %s", clk >= 0 ? "true" : "false");
    }

    printf("}\n");
}

static void usage(void) {
    fprintf(stderr,
        "scarlett_ctl — Focusrite Scarlett 18i20 Gen 1 control\n"
        "\n"
        "Usage:\n"
        "  scarlett_ctl dump                  Full state dump (EDN)\n"
        "  scarlett_ctl clock                 Read clock source & rate\n"
        "  scarlett_ctl clock <1|2|3>         Set clock (1=int 2=spdif 3=adat)\n"
        "  scarlett_ctl rate                  Read sample rate\n"
        "  scarlett_ctl route                 Read all output routing\n"
        "  scarlett_ctl route <out> <src>     Set output route\n"
        "  scarlett_ctl bus                   Read bus volumes & mutes\n"
        "  scarlett_ctl mixer                 Read mixer input assignments\n"
        "  scarlett_ctl matrix               Read matrix gains (non-silent)\n"
        "  scarlett_ctl save                  Persist to hardware flash\n"
        "  scarlett_ctl doctor                Check device & blockers\n"
        "\n"
        "All output is EDN. Source/output IDs are numeric.\n"
        "Use 0x prefix for hex: scarlett_ctl route 6 0x26\n"
    );
}

/* ── Main ──────────────────────────────────────────────── */

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }

    const char *cmd = argv[1];

    /* Doctor doesn't need full device open */
    if (strcmp(cmd, "doctor") == 0) {
        /* Try to open but don't fail hard */
        device_open();
        cmd_doctor();
        device_close();
        return 0;
    }

    /* All other commands need the device */
    int err = device_open();
    if (err) {
        if (err == -1)
            edn_error("device not found");
        else if (err == -4)
            edn_error("cannot open device — check for competing processes (run: scarlett_ctl doctor)");
        else
            printf("{:error \"device open failed\" :code %d}\n", err);
        return 1;
    }

    /* Dispatch */
    if      (strcmp(cmd, "dump")   == 0) cmd_dump();
    else if (strcmp(cmd, "clock")  == 0) cmd_clock(argc, argv);
    else if (strcmp(cmd, "rate")   == 0) cmd_rate();
    else if (strcmp(cmd, "route")  == 0) cmd_route(argc, argv);
    else if (strcmp(cmd, "bus")    == 0) cmd_bus();
    else if (strcmp(cmd, "mixer")  == 0) cmd_mixer();
    else if (strcmp(cmd, "matrix") == 0) cmd_matrix();
    else if (strcmp(cmd, "save")   == 0) cmd_save();
    else { usage(); device_close(); return 1; }

    device_close();
    return 0;
}
