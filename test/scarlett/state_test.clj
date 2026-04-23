(ns scarlett.state-test
  (:require [clojure.test :refer [deftest is testing]]
            [scarlett.codec :as c]
            [scarlett.device :as d]
            [scarlett.state :as s]))

;; Real sample dump captured from a live 18i20 (clock=S/PDIF,
;; common MixControl stereo-pair preset). Shrunk for readability.

(def sample-dump
  {:clock {:source 2 :rate 48000}
   :routing {0 38 1 39 6 0 7 1 10 46 19 46}
   :buses {0 {:volume 0 :mute 2816}
           1 {:volume -32768 :mute 2816}
           20 {:volume 0 :mute 2816}}
   :mixer-inputs {0 20 1 21 16 0 17 1}
   :matrix {0 -2560 9 -2560 16 -1024 137 -2048}})

(deftest parse-clock-decodes-source-and-passes-rate
  (is (= {:source :spdif :rate 48000}
         (s/parse-clock (:clock sample-dump)))))

(deftest parse-routing-uses-keywords-for-both-sides
  (let [r (s/parse-routing (:routing sample-dump))]
    (is (= :mix-1 (r :mon-l)))       ; output 0  → source 38 (mix-1)
    (is (= :mix-2 (r :mon-r)))       ; output 1  → source 39 (mix-2)
    (is (= :daw-1 (r :out-7)))       ; output 6  → source 0  (daw-1)
    (is (= :mix-9 (r :spdif-l)))     ; output 10 → source 46
    (is (= :mix-9 (r :adat-8)))))    ; output 19 → source 46

(deftest parse-buses-decodes-volume-preserves-mute-raw
  (let [b (s/parse-buses (:buses sample-dump))]
    (is (= 0.0      (get-in b [:master :volume-db])))
    (is (= :silence (get-in b [:mon-l  :volume-db])))
    (is (= 2816     (get-in b [:master :mute-raw])))))

(deftest parse-mixer-inputs-uses-source-keywords
  (let [m (s/parse-mixer-inputs (:mixer-inputs sample-dump))]
    (is (= :anlg-1 (m 0)))
    (is (= :anlg-2 (m 1)))
    (is (= :daw-1  (m 16)))
    (is (= :daw-2  (m 17)))))

(deftest parse-matrix-uses-tuple-keys-and-db
  (let [m (s/parse-matrix (:matrix sample-dump))]
    (is (= -10.0 (m [0 0])))    ; node 0   = slot 0, mix 0 → -2560
    (is (= -10.0 (m [1 1])))    ; node 9   = slot 1, mix 1
    (is (= -4.0  (m [2 0])))    ; node 16  = slot 2, mix 0 → -1024
    (is (= -8.0  (m [17 1])))   ; node 137 = slot 17, mix 1 → -2048
    (is (nil? (m [5 5])))))      ; silent — absent from both raw and parsed

(deftest parse-dump-produces-valid-state
  (let [st (s/parse-dump sample-dump)]
    (is (nil? (s/validate st))
        (str "parse-dump should yield a schema-valid State; got: "
             (pr-str (s/validate st))))))

(deftest parse-unparse-round-trip
  (let [st (s/parse-dump sample-dump)
        back (s/unparse-dump st)]
    (is (= (:clock sample-dump)        (:clock back)))
    (is (= (:routing sample-dump)      (:routing back)))
    (is (= (:mixer-inputs sample-dump) (:mixer-inputs back)))
    (is (= (:matrix sample-dump)       (:matrix back)))
    (testing "bus round-trip preserves both volume and mute"
      (is (= (:buses sample-dump)      (:buses back))))))
