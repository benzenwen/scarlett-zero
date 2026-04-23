(ns scarlett.device-test
  (:require [clojure.test :refer [deftest is testing]]
            [scarlett.device :as d]))

(deftest dimensions
  (is (= 20  d/num-outputs))
  (is (= 21  d/num-buses))
  (is (= 18  d/num-mixer-inputs))
  (is (= 8   d/num-mix-outputs))
  (is (= 144 d/num-matrix-nodes))
  (is (= 143 d/max-matrix-node)))

(deftest usb-identity
  (is (= 0x1235 d/usb-vendor-id))
  (is (= 0x800c d/usb-product-id)))

(deftest clock-sources-shape
  (is (= {:internal 1 :spdif 2 :adat 3} d/clock-sources)))

(deftest sources-shape
  (testing "49 entries: 20 DAW + 8 analog + 2 S/PDIF + 8 ADAT + 10 mix + off"
    (is (= 49 (count d/sources))))
  (testing "ids are unique"
    (is (= (count d/sources) (count (set (vals d/sources))))))
  (testing "spot checks align with project brief"
    (is (= 0   (d/sources :daw-1)))
    (is (= 19  (d/sources :daw-20)))
    (is (= 20  (d/sources :anlg-1)))
    (is (= 27  (d/sources :anlg-8)))
    (is (= 28  (d/sources :spdif-l)))
    (is (= 29  (d/sources :spdif-r)))
    (is (= 30  (d/sources :adat-in-1)))
    (is (= 37  (d/sources :adat-in-8)))
    (is (= 38  (d/sources :mix-1)))
    (is (= 46  (d/sources :mix-9)))
    (is (= 47  (d/sources :mix-10)))
    (is (= 255 (d/sources :off)))))

(deftest outputs-shape
  (is (= 20 (count d/outputs)))
  (is (= (set (range 20)) (set (vals d/outputs))))
  (testing "spot checks"
    (is (= 0  (d/outputs :mon-l)))
    (is (= 1  (d/outputs :mon-r)))
    (is (= 6  (d/outputs :out-7)))
    (is (= 10 (d/outputs :spdif-l)))
    (is (= 19 (d/outputs :adat-8)))))

(deftest buses-shape
  (is (= 21 (count d/buses)))
  (is (= (set (range 21)) (set (vals d/buses))))
  (testing "bus 0 is master; bus 1/2 are monitor L/R (offset by 1 vs outputs)"
    (is (= 0 (d/buses :master)))
    (is (= 1 (d/buses :mon-l)))
    (is (= 2 (d/buses :mon-r)))
    (is (= 20 (d/buses :adat-8)))))

(deftest wire-shape
  (testing "every control the C transport handles has a wire entry"
    (is (= #{:clock-source :sample-rate :route :mixer-input
             :matrix-gain :bus-volume :bus-mute :save}
           (set (keys d/wire)))))
  (testing "w-value fns produce expected wValues for a few samples"
    (is (= 0x0100 ((get-in d/wire [:clock-source :w-value]) nil)))
    (is (= 0x0100 ((get-in d/wire [:sample-rate  :w-value]) nil)))
    (is (= 5      ((get-in d/wire [:route        :w-value]) 5)))
    (is (= 0x0605 ((get-in d/wire [:mixer-input  :w-value]) 5)))
    (is (= 0x0205 ((get-in d/wire [:bus-volume   :w-value]) 5)))
    (is (= 0x0105 ((get-in d/wire [:bus-mute     :w-value]) 5)))))
