(ns scarlett.codec-test
  (:require [clojure.test :refer [deftest is testing]]
            [scarlett.codec :as c]
            [scarlett.device :as d]))

;; ─── Round-trips: keyword → id → keyword ─────────────────────

(deftest source-round-trip
  (doseq [[kw id] d/sources]
    (is (= id (c/source->id kw)))
    (is (= kw (c/id->source id)))))

(deftest output-round-trip
  (doseq [[kw id] d/outputs]
    (is (= id (c/output->id kw)))
    (is (= kw (c/id->output id)))))

(deftest bus-round-trip
  (doseq [[kw id] d/buses]
    (is (= id (c/bus->id kw)))
    (is (= kw (c/id->bus id)))))

(deftest clock-round-trip
  (doseq [[kw id] d/clock-sources]
    (is (= id (c/clock->id kw)))
    (is (= kw (c/id->clock id)))))

;; ─── Failure modes ───────────────────────────────────────────

(deftest unknown-keyword-throws
  (is (thrown? clojure.lang.ExceptionInfo (c/source->id :bogus)))
  (is (thrown? clojure.lang.ExceptionInfo (c/output->id :master)))  ; :master is a bus, not an output
  (is (thrown? clojure.lang.ExceptionInfo (c/bus->id    :daw-1)))   ; :daw-1 is a source, not a bus
  (is (thrown? clojure.lang.ExceptionInfo (c/clock->id  :external))))

(deftest unknown-id-returns-nil
  (is (nil? (c/id->source 99)))
  (is (nil? (c/id->output 99)))
  (is (nil? (c/id->bus    99)))
  (is (nil? (c/id->clock  99))))

;; ─── Malli schemas ───────────────────────────────────────────

(deftest schema-validation
  (testing "SourceId accepts 0..47 and 255, rejects 48..254 and negatives"
    (is (c/valid? c/SourceId 0))
    (is (c/valid? c/SourceId 47))
    (is (c/valid? c/SourceId 255))
    (is (not (c/valid? c/SourceId 48)))
    (is (not (c/valid? c/SourceId 254)))
    (is (not (c/valid? c/SourceId -1))))
  (testing "OutputId 0..19"
    (is (c/valid? c/OutputId 0))
    (is (c/valid? c/OutputId 19))
    (is (not (c/valid? c/OutputId 20))))
  (testing "BusId 0..20"
    (is (c/valid? c/BusId 20))
    (is (not (c/valid? c/BusId 21))))
  (testing "MatrixNodeId honours the 143 ceiling"
    (is (c/valid? c/MatrixNodeId 143))
    (is (not (c/valid? c/MatrixNodeId 144))))
  (testing "keyword schemas"
    (is (c/valid? c/SourceKw :daw-1))
    (is (c/valid? c/SourceKw :off))
    (is (not (c/valid? c/SourceKw :nope)))
    (is (c/valid? c/OutputKw :mon-l))
    (is (c/valid? c/BusKw    :master))
    (is (c/valid? c/ClockKw  :adat))))

;; ─── Matrix node ─────────────────────────────────────────────

(deftest matrix-node-math
  (is (= 0   (c/matrix-node 0 0)))
  (is (= 7   (c/matrix-node 0 7)))
  (is (= 8   (c/matrix-node 1 0)))
  (is (= 143 (c/matrix-node 17 7)))
  (testing "encode/decode round-trip covers all valid nodes"
    (doseq [node (range d/num-matrix-nodes)]
      (let [[slot bus] (c/node->input+bus node)]
        (is (= node (c/matrix-node slot bus)))
        (is (<= 0 slot 17))
        (is (<= 0 bus  7))))))

;; ─── Gain codec ──────────────────────────────────────────────

(deftest raw->db-known-points
  (is (= 0.0       (c/raw->db 0)))
  (is (= -1.0      (c/raw->db -256)))
  (is (= -4.0      (c/raw->db -1024)))   ; 0xfc00 per brief
  (is (= -5.0      (c/raw->db -1280)))   ; 0xfb00
  (is (= -8.0      (c/raw->db -2048)))   ; 0xf800
  (is (= -10.0     (c/raw->db -2560)))   ; 0xf600
  (is (= :silence  (c/raw->db -32768))))

(deftest db->raw-known-points
  (is (= 0      (c/db->raw 0.0)))
  (is (= -256   (c/db->raw -1.0)))
  (is (= -1024  (c/db->raw -4.0)))
  (is (= -2048  (c/db->raw -8.0)))
  (is (= -32768 (c/db->raw :silence))))

(deftest gain-round-trip
  (doseq [db [0.0 -0.5 -1.0 -3.0 -10.5 -22.3 -60.0 -120.0 :silence]]
    (let [db' (c/raw->db (c/db->raw db))]
      (if (= db :silence)
        (is (= :silence db'))
        (is (< (Math/abs (- (double db) (double db'))) 0.005)
            (str "round-trip drift on " db " → " db'))))))

(deftest db->raw-clamps-out-of-range
  (testing "positive dB clamps to 0 (no gain above unity on this device)"
    (is (= 0 (c/db->raw 5.0))))
  (testing "below -127.996 dB clamps just above the silence sentinel"
    (let [raw (c/db->raw -200.0)]
      (is (not= raw c/gain-silence-raw))
      (is (< raw -32000)))))
