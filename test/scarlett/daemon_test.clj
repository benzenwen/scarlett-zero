(ns scarlett.daemon-test
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [scarlett.daemon :as d]))

;; All tests in this ns use the fake shell script at
;; test/fixtures/fake-scarlett-ctl so they never touch the real device.

(defn with-fake [f]
  (binding [d/*binary* "test/fixtures/fake-scarlett-ctl"]
    (f)))

(use-fixtures :each with-fake)

(deftest open-consumes-ready-line
  (let [dm (d/open)]
    (is (map? dm))
    (is (some? (:proc dm)))
    (d/close dm)))

(deftest request-with-string-round-trips
  (d/with-daemon [dm]
    (let [r (d/request dm "ping")]
      (is (:ok r))
      (is (:fake r)))))

(deftest request-with-tokens-joins-with-spaces
  (d/with-daemon [dm]
    (let [r (d/request dm ["bus" 0 0])]
      (is (:ok r))
      (is (= 0 (:bus r))))))

(deftest request-throws-on-error-response
  (d/with-daemon [dm]
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"bad command"
                          (d/request dm "bad cmd")))))

(deftest request-throws-on-non-edn
  (d/with-daemon [dm]
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"non-EDN"
                          (d/request dm "not edn")))))

(deftest multiple-requests-in-sequence-stay-aligned
  (d/with-daemon [dm]
    (is (:ok (d/request dm "ping")))
    (is (= 48000 (:rate (d/request dm "clock"))))
    (is (:ok (d/request dm "ping")))))

(deftest close-is-idempotent
  (let [dm (d/open)]
    (d/close dm)
    (is (nil? (d/close dm))
        "second close should not throw")))
