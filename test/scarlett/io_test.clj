(ns scarlett.io-test
  (:require [clojure.java.io :as jio]
            [clojure.test :refer [deftest is testing]]
            [scarlett.io :as sio]
            [scarlett.state :as state]))

(def sample-raw-dump
  {:clock {:source 1 :rate 48000}
   :routing {0 0 1 1 2 0 3 1 4 0 5 1 6 20 7 21
             8 20 9 21 10 38 11 39 12 30 13 31
             14 32 15 33 16 34 17 35 18 36 19 37}
   :buses (into {}
                (for [i (range 21)]
                  [i {:volume 0 :mute 2816}]))
   :mixer-inputs (into {} (for [i (range 18)] [i i]))
   :matrix {0 -256 9 -256}})

(defn- tmp-edn-path []
  (let [f (java.io.File/createTempFile "scarlett-preset-" ".edn")]
    (.deleteOnExit f)
    (.getAbsolutePath f)))

(deftest save-then-load-round-trips-a-valid-state
  (let [st   (state/parse-dump sample-raw-dump)
        path (tmp-edn-path)]
    (sio/save! path st)
    (is (.exists (jio/file path)))
    (let [loaded (sio/load path)]
      (is (= st loaded)))))

(deftest load-throws-on-malformed-preset
  (let [path (tmp-edn-path)]
    (spit path "{:clock {:source :bogus :rate 48000}}")
    (is (thrown? clojure.lang.ExceptionInfo (sio/load path)))))

(deftest load-lenient-skips-schema-check
  (let [path (tmp-edn-path)]
    (spit path "{:routing {:mon-l :daw-1}}")
    (is (= {:routing {:mon-l :daw-1}} (sio/load-lenient path)))))
