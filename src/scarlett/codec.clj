(ns scarlett.codec
  "Pure encoding/decoding between symbolic keywords and the numeric
   ids spoken by the device. Malli schemas describe every id type
   produced or consumed here. No I/O, no state."
  (:require [malli.core :as m]
            [scarlett.device :as d]))

;; ─── Schemas ──────────────────────────────────────────────────

(def SourceKw (into [:enum] (keys d/sources)))
(def OutputKw (into [:enum] (keys d/outputs)))
(def BusKw    (into [:enum] (keys d/buses)))
(def ClockKw  (into [:enum] (keys d/clock-sources)))

(def SourceId      [:or [:int {:min 0 :max 47}] [:= 255]])
(def OutputId      [:int {:min 0 :max 19}])
(def BusId         [:int {:min 0 :max 20}])
(def ClockId       [:int {:min 1 :max 3}])
(def MixerSlotId   [:int {:min 0 :max 17}])
(def MixBusId      [:int {:min 0 :max 7}])
(def MatrixNodeId  [:int {:min 0 :max 143}])

;; Raw 16-bit signed gain value, as read via IOKit. 0 = 0 dB,
;; -32768 = -inf / silence.
(def GainRaw [:int {:min -32768 :max 32767}])

;; A dB value or the silence sentinel.
(def Db
  [:or
   [:and :double [:>= -127.99] [:<= 0.0]]
   [:= :silence]])

(defn valid?
  "Return true if value conforms to schema. Thin wrapper over m/validate."
  [schema value]
  (m/validate schema value))

(defn explain
  "Return a Malli explanation map for schema/value, or nil if valid."
  [schema value]
  (m/explain schema value))

;; ─── Inverse lookup tables ────────────────────────────────────

(def ^:private id->source-kw (into {} (map (juxt val key)) d/sources))
(def ^:private id->output-kw (into {} (map (juxt val key)) d/outputs))
(def ^:private id->bus-kw    (into {} (map (juxt val key)) d/buses))
(def ^:private id->clock-kw  (into {} (map (juxt val key)) d/clock-sources))

;; ─── Keyword → id (strict: throws on unknown) ─────────────────

(defn- encode* [table kind kw]
  (or (get table kw)
      (throw (ex-info (str "Unknown " kind " keyword")
                      {:keyword kw :known (sort (keys table))}))))

(defn source->id  [kw] (encode* d/sources       "source" kw))
(defn output->id  [kw] (encode* d/outputs       "output" kw))
(defn bus->id     [kw] (encode* d/buses         "bus"    kw))
(defn clock->id   [kw] (encode* d/clock-sources "clock"  kw))

;; ─── Id → keyword (lenient: nil on unknown) ───────────────────

(defn id->source [id] (id->source-kw id))
(defn id->output [id] (id->output-kw id))
(defn id->bus    [id] (id->bus-kw    id))
(defn id->clock  [id] (id->clock-kw  id))

;; ─── Matrix node ↔ (input-slot, mix-bus) ──────────────────────
;; Node index = input-slot * num-mix-outputs + mix-bus.
;; The stride (8 vs 9) is still an open question per project brief
;; Q2; we ship the natural stride of 8 and can revise once the
;; calibration pass lands.

(defn matrix-node
  "Encode (input-slot, mix-bus) → matrix node index."
  [input-slot mix-bus]
  (+ (* input-slot d/num-mix-outputs) mix-bus))

(defn node->input+bus
  "Decode matrix node index → [input-slot mix-bus]."
  [node]
  [(quot node d/num-mix-outputs)
   (rem  node d/num-mix-outputs)])

;; ─── Gain (dB ↔ signed int16) ─────────────────────────────────
;; The device encodes attenuation linearly: raw = round(dB * 256),
;; with the reserved value -32768 (0x8000) meaning -inf / silence.
;; This matches x42's formula for bus volumes and is consistent
;; with the 4/5 calibration points observed for matrix gains.
;; (The 5th matrix-gain point — 0xdf ≙ -22.3 dB — doesn't fit
;; and is flagged as open question Q5 in the project brief.)

(def ^:const gain-silence-raw -32768)

(defn raw->db
  "Decode signed int16 gain raw value → dB (double) or :silence."
  [raw]
  (if (= raw gain-silence-raw)
    :silence
    (/ (double raw) 256.0)))

(defn db->raw
  "Encode dB (double or :silence) → signed int16 gain raw value.
   dB is clamped to (-127.996, 0] so the result never collides
   with the silence sentinel."
  [db]
  (if (= db :silence)
    gain-silence-raw
    (let [clamped (max -127.996 (min 0.0 (double db)))]
      (long (Math/round (* 256.0 clamped))))))
