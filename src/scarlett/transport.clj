(ns scarlett.transport
  "Side-effecting layer. Shells out to ./scarlett_ctl, reads EDN from
   stdout, converts numeric IDs into canonical keyword form via
   scarlett.codec / scarlett.state. All fns here touch the device."
  (:require [babashka.process :as p]
            [clojure.edn :as edn]
            [scarlett.codec :as c]
            [scarlett.state :as s]))

(def ^:dynamic *binary* "./scarlett_ctl")

;; ─── Low-level invocation ─────────────────────────────────────

(defn- run
  "Invoke the scarlett_ctl binary with argv, parse stdout as EDN.
   Throws ex-info if the binary exits non-zero or emits an EDN map
   containing an :error key."
  [& args]
  (let [{:keys [exit out err]}
        @(p/process (into [*binary*] (map str args))
                    {:out :string :err :string})
        parsed (try (edn/read-string out)
                    (catch Exception e
                      (throw (ex-info "scarlett_ctl emitted non-EDN output"
                                      {:argv   args
                                       :exit   exit
                                       :stdout out
                                       :stderr err}
                                      e))))]
    (when (not (zero? exit))
      (throw (ex-info "scarlett_ctl exited non-zero"
                      {:argv args :exit exit :stderr err :parsed parsed})))
    (when (and (map? parsed) (:error parsed))
      (throw (ex-info (str "scarlett_ctl error: " (:error parsed))
                      {:argv args :parsed parsed})))
    parsed))

;; ─── Reads ────────────────────────────────────────────────────

(defn dump
  "Run `scarlett_ctl dump` and return the canonical parsed State."
  []
  (s/parse-dump (run "dump")))

(defn dump-raw
  "Like `dump` but returns the raw numeric EDN. Useful for debugging
   and for tools that want the wire-form."
  []
  (run "dump"))

(defn read-clock  [] (run "clock"))
(defn read-rate   [] (run "rate"))
(defn read-routes [] (run "route"))
(defn read-buses  [] (run "bus"))
(defn read-mixer  [] (run "mixer"))
(defn read-matrix [] (run "matrix"))
(defn doctor      [] (run "doctor"))

;; ─── Writes (limited: clock + route only — see dispatch! below) ──

(defn set-clock!
  "Set the clock source. Accepts a keyword (:internal :spdif :adat)."
  [clock-kw]
  (run "clock" (c/clock->id clock-kw)))

(defn set-route!
  "Set an output's routing source. Accepts keywords for both args
   (e.g. :mon-l :daw-1) and translates to numeric IDs."
  [output-kw source-kw]
  (run "route" (c/output->id output-kw) (c/source->id source-kw)))

(defn save!
  "Persist the current device state to hardware flash.
   **Destructive** — the device stores settings across power cycles,
   so this overwrites whatever was there. Caller confirms."
  []
  (run "save"))

;; ─── Command dispatch ─────────────────────────────────────────
;;
;; scarlett_ctl.c today only exposes writes for :clock, :route, and
;; :save. Applying a full preset diff (bus volumes, mixer-input
;; assignments, matrix gains) requires extending the C transport.
;; Those commands raise here so failures are loud and scoped.

(def supported-write-ops #{:clock :route :save})

(defn dispatch!
  "Execute a single preset command. Returns the parsed EDN response."
  [cmd]
  (case (first cmd)
    :clock        (set-clock! (nth cmd 1))
    :route        (set-route! (nth cmd 1) (nth cmd 2))
    :save         (save!)
    :bus-volume
    (throw (ex-info "Bus-volume writes not yet implemented in scarlett_ctl"
                    {:cmd cmd :unsupported-op (first cmd)}))
    :mixer-input
    (throw (ex-info "Mixer-input assignment writes not yet implemented in scarlett_ctl"
                    {:cmd cmd :unsupported-op (first cmd)}))
    :matrix
    (throw (ex-info "Matrix-gain writes not yet implemented in scarlett_ctl"
                    {:cmd cmd :unsupported-op (first cmd)}))
    (throw (ex-info "Unknown command op" {:cmd cmd}))))

(defn execute!
  "Execute a sequence of commands in order. Stops at first failure
   and returns a map with :applied (completed commands), :failed
   (the one that threw), and :error (the exception)."
  [commands]
  (loop [applied []
         [cmd & more] commands]
    (if (nil? cmd)
      {:applied applied}
      (let [result (try {:ok (dispatch! cmd)}
                        (catch Exception e {:ex e}))]
        (if (:ex result)
          {:applied applied :failed cmd :error (:ex result)}
          (recur (conj applied cmd) more))))))
