/*
 * scarlett_ctl — Unified control tool for Focusrite Scarlett 18i20 Gen 1.
 *
 * Two modes share the same command grammar:
 *
 *   One-shot:   scarlett_ctl <cmd> [args...]
 *   Daemon:     scarlett_ctl daemon
 *                   reads newline-delimited commands on stdin,
 *                   emits one line of EDN per command on stdout,
 *                   flushes after each. SIGINT/SIGTERM close cleanly.
 *
 * All output is single-line EDN for easy bb parsing. Daemon exists so
 * bulk-write workloads (preset apply) don't re-open the IOKit handle
 * on every write — brief §Operational Constraints warns that rapid
 * open/close cycles can wedge the device.
 *
 * Commands:
 *   ping                       Liveness + device-open status
 *   doctor                     Device presence + competing processes
 *   clock [N]                  Read or set (1=int 2=spdif 3=adat)
 *   rate                       Read sample rate
 *   route [OUT SRC]            Read all, or set one (numeric ids)
 *   bus [BUS RAW]              Read all, or set bus volume to signed int16
 *   mixer [SLOT SRC]           Read all, or set mixer-input assignment
 *   matrix [NODE RAW]          Read all non-silent, or set matrix gain
 *   dump                       Full state
 *   save confirm               Persist to hardware flash (untested wire cmd)
 *   quit                       (daemon only) exit cleanly
 *
 * Writes take raw signed int16 values — symbolic/dB conversion happens
 * on the Babashka side. Gain values: 0x0000 = 0 dB, 0x8000 = silence.
 *
 * Compile:
 *   cc -o scarlett_ctl scarlett_ctl.c scarlett_core.c -framework IOKit -framework CoreFoundation
 *
 * Copyright 2026 Ben Wen. All rights reserved.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include "scarlett_core.h"

#define NUM_OUTPUTS     SC_NUM_OUTPUTS
#define NUM_BUSES       SC_NUM_BUSES
#define NUM_MIXER_INS   SC_NUM_MIXER_INS
#define MATRIX_NODES    SC_MATRIX_NODES

/* ── Device handle ─────────────────────────────────────── */

static sc_device             *g_dev = NULL;
static volatile sig_atomic_t  g_quit = 0;

static int device_open(void) { return sc_open(&g_dev); }

static void device_close(void) {
    sc_close(g_dev);
    g_dev = NULL;
}

/* ── Read/write helpers (thin names over scarlett_core) ── */

#define read_clock_source()      sc_read_clock_source(g_dev)
#define read_sample_rate()       sc_read_sample_rate(g_dev)
#define read_route(o)            sc_read_route(g_dev, (o))
#define read_bus_volume(b)       sc_read_bus_volume(g_dev, (b))
#define read_bus_mute(b)         sc_read_bus_mute(g_dev, (b))
#define read_mixer_input(s)      sc_read_mixer_input(g_dev, (s))
#define read_matrix_gain(n)      sc_read_matrix_gain(g_dev, (n))
#define write_bus_volume(b, v)   sc_write_bus_volume(g_dev, (b), (v))
#define write_mixer_input(s, v)  sc_write_mixer_input(g_dev, (s), (v))
#define write_matrix_gain(n, v)  sc_write_matrix_gain(g_dev, (n), (v))

/* ── EDN helpers ───────────────────────────────────────── */

static void edn_error(const char *msg) {
    printf("{:error \"%s\"}\n", msg);
}

static void edn_error_code(const char *msg, int code) {
    printf("{:error \"%s\" :code %d}\n", msg, code);
}

/* ── Commands ──────────────────────────────────────────── */

static void cmd_ping(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("{:ok true :device-open %s}\n", g_dev ? "true" : "false");
}

static void cmd_clock(int argc, char **argv) {
    if (argc > 1) {
        int val = atoi(argv[1]);
        if (val < 1 || val > 3) {
            edn_error("clock value must be 1 (internal), 2 (spdif), or 3 (adat)");
            return;
        }
        kern_return_t kr = sc_write_clock_source(g_dev, val);
        if (kr != KERN_SUCCESS) { edn_error_code("write failed", kr); return; }
        int readback = read_clock_source();
        printf("{:ok true :source %d}\n", readback);
    } else {
        int src = read_clock_source();
        int rate = read_sample_rate();
        if (src < 0 || rate < 0) { edn_error("read failed"); return; }
        printf("{:source %d :rate %d}\n", src, rate);
    }
}

static void cmd_rate(int argc, char **argv) {
    (void)argc; (void)argv;
    int rate = read_sample_rate();
    if (rate < 0) { edn_error("read failed"); return; }
    printf("{:rate %d}\n", rate);
}

static void cmd_route(int argc, char **argv) {
    if (argc > 2) {
        int out = atoi(argv[1]);
        int src = (int)strtol(argv[2], NULL, 0);
        if (out < 0 || out >= NUM_OUTPUTS) {
            edn_error("output index must be 0-19"); return;
        }
        int before = read_route(out);
        kern_return_t kr = sc_write_route(g_dev, out, src);
        if (kr != KERN_SUCCESS) { edn_error_code("write failed", kr); return; }
        int after = read_route(out);
        printf("{:ok true :output %d :before %d :after %d}\n", out, before, after);
    } else {
        printf("{");
        for (int i = 0; i < NUM_OUTPUTS; i++) {
            int src = read_route(i);
            if (src < 0) continue;
            printf("%s%d %d", i > 0 ? " " : "", i, src);
        }
        printf("}\n");
    }
}

static void cmd_bus(int argc, char **argv) {
    if (argc > 2) {
        int bus = atoi(argv[1]);
        int raw = (int)strtol(argv[2], NULL, 0);
        if (bus < 0 || bus >= NUM_BUSES) {
            edn_error("bus index must be 0-20"); return;
        }
        if (raw < -32768 || raw > 32767) {
            edn_error("volume raw must fit in int16"); return;
        }
        int before = read_bus_volume(bus);
        kern_return_t kr = write_bus_volume(bus, (int16_t)raw);
        if (kr != KERN_SUCCESS) { edn_error_code("write failed", kr); return; }
        int after = read_bus_volume(bus);
        printf("{:ok true :bus %d :before %d :after %d}\n", bus, before, after);
    } else {
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
}

static void cmd_mixer(int argc, char **argv) {
    if (argc > 2) {
        int slot = atoi(argv[1]);
        int src  = (int)strtol(argv[2], NULL, 0);
        if (slot < 0 || slot >= NUM_MIXER_INS) {
            edn_error("mixer slot must be 0-17"); return;
        }
        int before = read_mixer_input(slot);
        kern_return_t kr = write_mixer_input(slot, src);
        if (kr != KERN_SUCCESS) { edn_error_code("write failed", kr); return; }
        int after = read_mixer_input(slot);
        printf("{:ok true :slot %d :before %d :after %d}\n", slot, before, after);
    } else {
        printf("{");
        for (int i = 0; i < NUM_MIXER_INS; i++) {
            int src = read_mixer_input(i);
            if (src < 0) continue;
            printf("%s%d %d", i > 0 ? " " : "", i, src);
        }
        printf("}\n");
    }
}

static void cmd_matrix(int argc, char **argv) {
    if (argc > 2) {
        int node = atoi(argv[1]);
        int raw  = (int)strtol(argv[2], NULL, 0);
        if (node < 0 || node >= MATRIX_NODES) {
            edn_error("matrix node must be 0-143"); return;
        }
        if (raw < -32768 || raw > 32767) {
            edn_error("gain raw must fit in int16"); return;
        }
        int before = read_matrix_gain(node);
        kern_return_t kr = write_matrix_gain(node, (int16_t)raw);
        if (kr != KERN_SUCCESS) { edn_error_code("write failed", kr); return; }
        int after = read_matrix_gain(node);
        printf("{:ok true :node %d :before %d :after %d}\n", node, before, after);
    } else {
        printf("{");
        int first = 1;
        for (int node = 0; node < MATRIX_NODES; node++) {
            int val = read_matrix_gain(node);
            if (val == -99999) break;                /* stall — bail */
            if (val == (int16_t)0x8000) continue;    /* -inf — skip */
            printf("%s%d %d", first ? "" : " ", node, val);
            first = 0;
        }
        printf("}\n");
    }
}

static void cmd_dump(int argc, char **argv) {
    (void)argc; (void)argv;
    int clk  = read_clock_source();
    int rate = read_sample_rate();

    printf("{:clock {:source %d :rate %d}", clk, rate);

    printf(" :routing {");
    for (int i = 0; i < NUM_OUTPUTS; i++) {
        int src = read_route(i);
        if (src < 0) continue;
        printf("%s%d %d", i > 0 ? " " : "", i, src);
    }
    printf("}");

    printf(" :buses {");
    for (int i = 0; i < NUM_BUSES; i++) {
        int vol = read_bus_volume(i);
        int mute = read_bus_mute(i);
        if (vol == -9999) continue;
        printf("%s%d {:volume %d :mute %d}",
               i > 0 ? " " : "", i, vol, mute);
    }
    printf("}");

    printf(" :mixer-inputs {");
    for (int i = 0; i < NUM_MIXER_INS; i++) {
        int src = read_mixer_input(i);
        if (src < 0) continue;
        printf("%s%d %d", i > 0 ? " " : "", i, src);
    }
    printf("}");

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

static void cmd_save(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "confirm") != 0) {
        edn_error("save requires confirm: 'save confirm'");
        return;
    }
    kern_return_t kr = sc_save_to_flash(g_dev);
    if (kr == KERN_SUCCESS) printf("{:ok true}\n");
    else                    edn_error_code("save failed", kr);
}

static void cmd_doctor(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("{:device ");

    if (!sc_present()) {
        printf("{:found false}");
    } else {
        printf("{:found true}");
    }

    printf(" :blockers [");
    FILE *fp = popen(
        "ps aux 2>/dev/null | grep -i -E 'FocusriteControl|MIDIServer' "
        "| grep -v grep | awk '{print $11}' | tr '\\n' ' '", "r");
    if (fp) {
        char line[512] = {0};
        if (fgets(line, sizeof(line), fp)) {
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

    fp = popen(
        "ps aux 2>/dev/null | grep -i 'Google Chrome' "
        "| grep -v grep | head -1 | awk '{print $2}'", "r");
    if (fp) {
        char pid[32] = {0};
        if (fgets(pid, sizeof(pid), fp) && strlen(pid) > 1) {
            printf(" :chrome-running true");
        } else {
            printf(" :chrome-running false");
        }
        pclose(fp);
    }

    if (g_dev) {
        int clk = read_clock_source();
        printf(" :readable %s", clk >= 0 ? "true" : "false");
    } else {
        printf(" :readable false");
    }

    printf("}\n");
}

/* ── Dispatch table ────────────────────────────────────── */

typedef void (*cmd_fn)(int argc, char **argv);

struct cmd_entry {
    const char *name;
    cmd_fn fn;
    int needs_device;  /* 0 = doctor can run without an open handle */
};

static struct cmd_entry commands[] = {
    {"ping",   cmd_ping,   0},
    {"doctor", cmd_doctor, 0},
    {"clock",  cmd_clock,  1},
    {"rate",   cmd_rate,   1},
    {"route",  cmd_route,  1},
    {"bus",    cmd_bus,    1},
    {"mixer",  cmd_mixer,  1},
    {"matrix", cmd_matrix, 1},
    {"dump",   cmd_dump,   1},
    {"save",   cmd_save,   1},
    {NULL, NULL, 0}
};

/* Dispatch argv[0..argc) to a subcommand. Returns 0 on recognized cmd,
   -1 on unknown. Does not itself print errors for unknown commands. */
static int dispatch(int argc, char **argv) {
    if (argc < 1) return -1;
    for (struct cmd_entry *e = commands; e->name; e++) {
        if (strcmp(argv[0], e->name) == 0) {
            e->fn(argc, argv);
            return 0;
        }
    }
    return -1;
}

/* ── Daemon ────────────────────────────────────────────── */

static void on_signal(int sig) { (void)sig; g_quit = 1; }

static void cmd_daemon(void) {
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    /* Line-buffered stdout so every response flushes on its trailing \n. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    char line[4096];
    while (!g_quit && fgets(line, sizeof(line), stdin)) {
        /* Tokenize in place on whitespace. */
        char *tokens[32];
        int ntok = 0;
        char *p = strtok(line, " \t\r\n");
        while (p && ntok < 32) { tokens[ntok++] = p; p = strtok(NULL, " \t\r\n"); }
        if (ntok == 0) continue;

        if (strcmp(tokens[0], "quit") == 0) {
            printf("{:ok true :bye true}\n");
            fflush(stdout);
            break;
        }

        if (dispatch(ntok, tokens) < 0) {
            printf("{:error \"unknown command\" :cmd \"%s\"}\n", tokens[0]);
            fflush(stdout);
        }
        /* Each cmd prints its own trailing \n which flushes line-buffered stdout. */
    }
}

/* ── Usage & main ──────────────────────────────────────── */

static void usage(void) {
    fprintf(stderr,
        "scarlett_ctl — Focusrite Scarlett 18i20 Gen 1 control\n"
        "\n"
        "One-shot:\n"
        "  scarlett_ctl ping\n"
        "  scarlett_ctl doctor\n"
        "  scarlett_ctl dump\n"
        "  scarlett_ctl clock [1|2|3]\n"
        "  scarlett_ctl rate\n"
        "  scarlett_ctl route [OUT SRC]\n"
        "  scarlett_ctl bus    [BUS RAW]\n"
        "  scarlett_ctl mixer  [SLOT SRC]\n"
        "  scarlett_ctl matrix [NODE RAW]\n"
        "  scarlett_ctl save confirm\n"
        "\n"
        "Daemon (newline-delimited same grammar on stdin, EDN on stdout):\n"
        "  scarlett_ctl daemon\n"
        "    additional: ping, quit\n"
        "\n"
        "Writes take raw signed int16. 0x0000 = 0 dB, 0x8000 = silence.\n"
    );
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }

    const char *cmd = argv[1];

    /* Daemon mode: open device, run loop, close. */
    if (strcmp(cmd, "daemon") == 0) {
        int err = device_open();
        if (err) {
            if (err == -4)
                edn_error("cannot open device — check for competing processes (run: scarlett_ctl doctor)");
            else
                edn_error_code("device open failed", err);
            return 1;
        }
        /* Signal readiness so the bb supervisor knows we're live. */
        printf("{:ok true :ready true}\n");
        fflush(stdout);
        cmd_daemon();
        device_close();
        return 0;
    }

    /* One-shot: look up cmd, open device if needed, dispatch, close. */
    struct cmd_entry *entry = NULL;
    for (struct cmd_entry *e = commands; e->name; e++) {
        if (strcmp(cmd, e->name) == 0) { entry = e; break; }
    }
    if (!entry) { usage(); return 1; }

    /* Doctor runs even without an open handle — it's specifically the
       thing you use to diagnose why the handle won't open. */
    if (entry->needs_device) {
        int err = device_open();
        if (err) {
            if (err == -1)      edn_error("device not found");
            else if (err == -4) edn_error("cannot open device — check for competing processes (run: scarlett_ctl doctor)");
            else                edn_error_code("device open failed", err);
            return 1;
        }
    } else {
        /* Best-effort open for doctor — OK if it fails. */
        device_open();
    }

    entry->fn(argc - 1, argv + 1);
    device_close();
    return 0;
}
