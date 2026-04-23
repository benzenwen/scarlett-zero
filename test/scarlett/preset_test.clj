(ns scarlett.preset-test
  (:require [clojure.test :refer [deftest is testing]]
            [scarlett.preset :as preset]))

(def state-a
  {:clock        {:source :internal :rate 48000}
   :routing      {:mon-l :daw-1 :mon-r :daw-2}
   :buses        {:master {:volume-db 0.0 :mute-raw 0}
                  :mon-l  {:volume-db 0.0 :mute-raw 0}}
   :mixer-inputs {0 :anlg-1 1 :anlg-2}
   :matrix       {[0 0] -6.0 [1 1] -6.0}})

(def state-b
  {:clock        {:source :spdif :rate 48000}
   :routing      {:mon-l :mix-1 :mon-r :daw-2}         ; mon-l changed
   :buses        {:master {:volume-db -3.0 :mute-raw 0} ; master down
                  :mon-l  {:volume-db 0.0  :mute-raw 0}}
   :mixer-inputs {0 :anlg-1 1 :anlg-3}                   ; slot 1 changed
   :matrix       {[0 0] -6.0 [1 1] -9.0 [2 0] -12.0}})   ; cell edited + added

(deftest diff-clock-emits-only-on-source-change
  (is (= [[:clock :spdif]] (preset/diff-clock state-a state-b)))
  (is (empty? (preset/diff-clock state-a state-a))))

(deftest diff-routing-emits-only-changed-outputs
  (is (= [[:route :mon-l :mix-1]] (preset/diff-routing state-a state-b))))

(deftest diff-buses-emits-changed-volumes-only
  (is (= [[:bus-volume :master -3.0]] (preset/diff-buses state-a state-b))))

(deftest diff-mixer-inputs-emits-changed-slots
  (is (= [[:mixer-input 1 :anlg-3]] (preset/diff-mixer-inputs state-a state-b))))

(deftest diff-matrix-handles-add-edit-and-silence
  (let [state-c (assoc state-a :matrix {[0 0] -6.0})]  ; dropped [1 1]
    (is (= [[:matrix 1 1 :silence]] (preset/diff-matrix state-a state-c))))
  (testing "edit + add"
    (is (= [[:matrix 1 1 -9.0]
            [:matrix 2 0 -12.0]]
           (preset/diff-matrix state-a state-b)))))

(deftest top-level-diff-orders-clock-mixer-matrix-routing-buses
  (let [cmds (preset/diff state-a state-b)]
    (is (= [:clock :mixer-input :matrix :matrix :route :bus-volume]
           (mapv first cmds)))
    (is (nil? (preset/validate-commands cmds))
        (str "diff output should pass Commands schema; got: "
             (pr-str (preset/validate-commands cmds))))))

(deftest diff-is-empty-when-states-equal
  (is (empty? (preset/diff state-a state-a))))

(deftest commands-schema-rejects-garbage
  (is (some? (preset/validate-commands [[:clock :bogus]])))
  (is (some? (preset/validate-commands [[:route :not-a-real-output :daw-1]])))
  (is (some? (preset/validate-commands [[:unknown-op]]))))
