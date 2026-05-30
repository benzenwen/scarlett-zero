(ns scarlett.integration-test
  "End-to-end tests against the real Scarlett 18i20. Run with
   `bb test:device`. Every write in here is intentionally a no-op
   round-trip so the user's current device state is preserved."
  (:require [clojure.test :refer [deftest is testing]]
            [scarlett.daemon :as d]
            [scarlett.preset :as preset]
            [scarlett.state :as state]
            [scarlett.transport :as t]))

(deftest one-shot-reads-work
  (testing "doctor finds the device"
    (is (true? (get-in (t/doctor) [:device :found]))))
  (testing "ping reports device-open"
    (is (true? (:device-open (t/ping)))))
  (testing "dump parses to a schema-valid State"
    (let [st (t/dump)]
      (is (nil? (state/validate st))))))

(deftest daemon-round-trip
  (d/with-daemon [dm]
    (is (true? (:device-open (d/request dm "ping"))))
    (is (map? (d/request dm "dump")))))

(deftest idempotent-write-preserves-state
  (testing "writing master bus volume back to its current value"
    (let [before (t/read-buses)
          vol    (get-in before [0 :volume])
          result (d/with-daemon [dm]
                   (d/request dm (str "bus 0 " vol)))]
      (is (:ok result))
      (is (= vol (:after result))))))

(deftest preset-apply-of-current-state-is-noop
  (testing "dump → diff-against-self → empty command list"
    (let [current (t/dump)
          cmds    (preset/diff current current)]
      (is (empty? cmds))
      (is (= {:applied []} (t/execute! cmds))))))

(deftest preset-apply-full-state-back-to-self-writes-everything
  (testing "apply(current) from blank baseline exercises every write path
            non-destructively (each write lands on its current value)"
    (let [current (t/dump)
          baseline (preset/empty-state)
          cmds    (preset/diff baseline current)
          {:keys [applied failed error]} (t/execute! cmds)]
      (is (nil? failed) (when failed (str "failed on: " (pr-str failed) " — " (ex-message error))))
      (is (= (count cmds) (count applied))))))
