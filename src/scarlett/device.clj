(ns scarlett.device
  "Static data for the Focusrite Scarlett 18i20 Gen 1: source IDs,
   output map, bus map, dimensions, clock sources, and USB wire
   constants. Pure data — no functions, no I/O, no validation.")

;; ─── USB identity ─────────────────────────────────────────────

(def usb-vendor-id  0x1235)
(def usb-product-id 0x800c)

;; ─── Dimensions ───────────────────────────────────────────────

(def num-outputs      20)
(def num-buses        21)   ; master + 20 per-output volume/mute
(def num-mixer-inputs 18)
(def num-mix-outputs   8)
(def num-matrix-nodes (* num-mixer-inputs num-mix-outputs))  ; 144

;; ─── Clock sources ────────────────────────────────────────────

(def clock-sources
  "Clock source keyword → numeric id sent to device."
  {:internal 1
   :spdif    2
   :adat     3})

;; ─── Signal sources ───────────────────────────────────────────
;; Used as routing sources (→ outputs) and mixer-input sources.
;;
;;  0–19   DAW 1–20  (USB playback from host)
;; 20–27   Analog In 1–8
;; 28–29   S/PDIF In L/R
;; 30–37   ADAT In 1–8
;; 38–47   Mix 1–10  (matrix outputs)
;; 255     explicit OFF
;;
;; Note: MixControl parks unused slots on Mix 9 (id 46) rather than
;; using 255. Both are representable; the codec treats them as
;; distinct sources with distinct numeric ids.

(def sources
  "Source keyword → numeric id."
  (into
   (sorted-map)
   (concat
    (for [n (range 1 21)] [(keyword (str "daw-"  n)) (dec n)])
    (for [n (range 1 9)]  [(keyword (str "anlg-" n)) (+ 19 n)])
    [[:spdif-l 28] [:spdif-r 29]]
    (for [n (range 1 9)]  [(keyword (str "adat-in-" n)) (+ 29 n)])
    (for [n (range 1 11)] [(keyword (str "mix-"  n)) (+ 37 n)])
    [[:off 255]])))

;; ─── Output map (20 physical outputs) ─────────────────────────

(def outputs
  "Output keyword → output index (0–19)."
  {:mon-l   0  :mon-r   1
   :hp1-l   2  :hp1-r   3
   :hp2-l   4  :hp2-r   5
   :out-7   6  :out-8   7  :out-9   8  :out-10  9
   :spdif-l 10 :spdif-r 11
   :adat-1  12 :adat-2  13 :adat-3  14 :adat-4  15
   :adat-5  16 :adat-6  17 :adat-7  18 :adat-8  19})

;; ─── Bus map (21 buses: master + per-output vol/mute) ─────────

(def buses
  "Bus keyword → bus index (0–20). Bus 0 is the global master."
  {:master  0
   :mon-l   1  :mon-r   2
   :hp1-l   3  :hp1-r   4
   :hp2-l   5  :hp2-r   6
   :out-7   7  :out-8   8  :out-9   9  :out-10 10
   :spdif-l 11 :spdif-r 12
   :adat-1  13 :adat-2  14 :adat-3  15 :adat-4  16
   :adat-5  17 :adat-6  18 :adat-7  19 :adat-8  20})

;; ─── USB wire constants ───────────────────────────────────────
;; The C transport (scarlett_ctl) hardcodes these. Kept here as the
;; canonical reference and for any future pure-Clojure transport.
;;
;; :w-value is either a literal uint16 or a 1-arg fn of the control
;; parameter (output index, bus index, mixer slot, matrix node).

(def wire
  {:clock-source {:w-index 0x2800 :w-value (constantly 0x0100) :length 1}
   :sample-rate  {:w-index 0x2900 :w-value (constantly 0x0100) :length 4}
   :route        {:w-index 0x3300 :w-value identity            :length 2}
   :mixer-input  {:w-index 0x3200 :w-value #(+ 0x0600 %)       :length 2}
   :matrix-gain  {:w-index 0x3c00 :w-value identity            :length 2}
   :bus-volume   {:w-index 0x0a00 :w-value #(+ 0x0200 %)       :length 2}
   :bus-mute     {:w-index 0x0a00 :w-value #(+ 0x0100 %)       :length 2}
   :save         {:w-index 0x3c00 :w-value (constantly 0x005a)
                  :length 1 :b-request 0x03 :payload [0xa5]}})

;; ─── Matrix boundary ──────────────────────────────────────────
;; The device pipe-stalls on reads to node ≥ 144. A stall wedges the
;; device and requires a power cycle. Any matrix index generator must
;; honour this limit.

(def max-matrix-node (dec num-matrix-nodes))  ; 143
