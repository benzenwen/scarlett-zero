(ns scarlett.state
  "Pure conversion between the numeric EDN emitted by ./scarlett_ctl
   and a canonical, keyword-keyed state map. No I/O, no shelling out."
  (:require [malli.core :as m]
            [scarlett.codec :as c]
            [scarlett.device :as d]))

;; ─── Schemas ──────────────────────────────────────────────────

(def Clock
  [:map
   [:source c/ClockKw]
   [:rate   :int]])

(def Routing
  [:map-of c/OutputKw c/SourceKw])

(def Bus
  ;; Mute decoding is unresolved on 18i20 (brief Q1 — the raw value
  ;; is 0x0b00 regardless of MixControl mute state), so we pass the
  ;; raw int through and leave interpretation to callers.
  [:map
   [:volume-db [:or :double [:= :silence]]]
   [:mute-raw  :int]])

(def Buses
  [:map-of c/BusKw Bus])

(def MixerInputs
  ;; Mixer slots are anonymous positions 0..17; keep integer keys.
  [:map-of c/MixerSlotId c/SourceKw])

(def MatrixCell
  ;; Matrix node → gain. Missing entries are silent (-inf).
  [:map-of
   [:tuple c/MixerSlotId c/MixBusId]
   [:or :double [:= :silence]]])

(def State
  [:map
   [:clock        Clock]
   [:routing      Routing]
   [:buses        Buses]
   [:mixer-inputs MixerInputs]
   [:matrix       MatrixCell]])

;; ─── Parsers: raw EDN → canonical ─────────────────────────────

(defn parse-clock [raw]
  {:source (c/id->clock (:source raw))
   :rate   (:rate raw)})

(defn parse-routing
  "Raw {output-id → source-id} → {output-kw → source-kw}."
  [raw]
  (into {} (for [[out-id src-id] raw]
             [(c/id->output out-id) (c/id->source src-id)])))

(defn parse-bus [raw]
  {:volume-db (c/raw->db (:volume raw))
   :mute-raw  (:mute raw)})

(defn parse-buses
  "Raw {bus-id → {:volume v :mute m}} → {bus-kw → Bus}."
  [raw]
  (into {} (for [[bus-id bus-raw] raw]
             [(c/id->bus bus-id) (parse-bus bus-raw)])))

(defn parse-mixer-inputs
  "Raw {slot → source-id} → {slot → source-kw}."
  [raw]
  (into {} (for [[slot src-id] raw]
             [slot (c/id->source src-id)])))

(defn parse-matrix
  "Raw {node-idx → raw-gain} → {[slot mix-bus] → dB}.
   Silent nodes are omitted from the dump and likewise omitted here."
  [raw]
  (into {} (for [[node raw-gain] raw]
             [(c/node->input+bus node) (c/raw->db raw-gain)])))

(defn parse-dump
  "Parse the full EDN map emitted by `./scarlett_ctl dump` into a
   canonical State."
  [raw]
  {:clock        (parse-clock        (:clock        raw))
   :routing      (parse-routing      (:routing      raw))
   :buses        (parse-buses        (:buses        raw))
   :mixer-inputs (parse-mixer-inputs (:mixer-inputs raw))
   :matrix       (parse-matrix       (:matrix       raw))})

;; ─── Unparsers: canonical → raw ───────────────────────────────
;; Useful for round-trip tests and for encoding a preset back into
;; the ID-keyed form if some future transport needs it.

(defn unparse-clock [state-clock]
  {:source (c/clock->id (:source state-clock))
   :rate   (:rate state-clock)})

(defn unparse-routing [state-routing]
  (into {} (for [[out-kw src-kw] state-routing]
             [(c/output->id out-kw) (c/source->id src-kw)])))

(defn unparse-bus [bus]
  {:volume (c/db->raw (:volume-db bus))
   :mute   (:mute-raw bus)})

(defn unparse-buses [state-buses]
  (into {} (for [[bus-kw bus] state-buses]
             [(c/bus->id bus-kw) (unparse-bus bus)])))

(defn unparse-mixer-inputs [state-mixer]
  (into {} (for [[slot src-kw] state-mixer]
             [slot (c/source->id src-kw)])))

(defn unparse-matrix [state-matrix]
  (into {} (for [[[slot bus] db] state-matrix]
             [(c/matrix-node slot bus) (c/db->raw db)])))

(defn unparse-dump [state]
  {:clock        (unparse-clock        (:clock        state))
   :routing      (unparse-routing      (:routing      state))
   :buses        (unparse-buses        (:buses        state))
   :mixer-inputs (unparse-mixer-inputs (:mixer-inputs state))
   :matrix       (unparse-matrix       (:matrix       state))})

;; ─── Validation helper ────────────────────────────────────────

(defn validate
  "Return nil if state conforms to State, otherwise a Malli explanation."
  [state]
  (m/explain State state))
