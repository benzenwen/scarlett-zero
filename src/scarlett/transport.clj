(ns scarlett.transport
  "Side-effecting layer. Two modes reach the device:

   * One-shot helpers (`dump`, `read-clock`, `set-clock!` …) fork a
     ./scarlett_ctl process per call. Right for ad-hoc reads and
     individual writes.

   * Bulk application (`execute!`) spawns one `./scarlett_ctl daemon`
     subprocess and streams commands through it — right for preset
     apply, where the device only tolerates so many open/close cycles
     before IOKit gets upset (see brief §Operational Constraints #3)."
  (:require [babashka.process :as p]
            [clojure.edn :as edn]
            [scarlett.codec :as c]
            [scarlett.daemon :as d]
            [scarlett.state :as s]))

(def ^:dynamic *binary* "./scarlett_ctl")

;; ─── One-shot invocation ──────────────────────────────────────

(defn- run
  "Invoke the scarlett_ctl binary one-shot with argv, parse stdout
   as EDN. Throws ex-info on non-zero exit or {:error ...} response."
  [& args]
  (let [{:keys [exit out err]}
        @(p/process (into [*binary*] (map str args))
                    {:out :string :err :string})
        parsed (try (edn/read-string out)
                    (catch Exception e
                      (throw (ex-info "scarlett_ctl emitted non-EDN output"
                                      {:argv args :exit exit
                                       :stdout out :stderr err} e))))]
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

(defn dump-raw [] (run "dump"))
(defn read-clock  [] (run "clock"))
(defn read-rate   [] (run "rate"))
(defn read-routes [] (run "route"))
(defn read-buses  [] (run "bus"))
(defn read-mixer  [] (run "mixer"))
(defn read-matrix [] (run "matrix"))
(defn doctor      [] (run "doctor"))
(defn ping        [] (run "ping"))

;; ─── One-shot writes ──────────────────────────────────────────

(defn set-clock!    [clock-kw]         (run "clock"  (c/clock->id clock-kw)))
(defn set-route!    [output-kw src-kw] (run "route"  (c/output->id output-kw) (c/source->id src-kw)))
(defn set-bus!      [bus-kw db]        (run "bus"    (c/bus->id bus-kw) (c/db->raw db)))
(defn set-mixer!    [slot src-kw]      (run "mixer"  slot (c/source->id src-kw)))
(defn set-matrix!   [slot bus db]      (run "matrix" (c/matrix-node slot bus) (c/db->raw db)))

(defn save!
  "Persist device state to flash. The C side requires an explicit
   confirm token, so we pass it here."
  []
  (run "save" "confirm"))

;; ─── Daemon dispatch ──────────────────────────────────────────
;; Preset commands are produced by scarlett.preset/diff. The command
;; vector layout:
;;
;;   [:clock       clock-kw]
;;   [:route       output-kw src-kw]
;;   [:bus-volume  bus-kw    db-or-silence]
;;   [:mixer-input slot      src-kw]
;;   [:matrix      slot      mix-bus  db-or-silence]
;;   [:save]

(defn- cmd->argv
  "Translate a preset command vector into an argv-seq for the C
   protocol. Symbolic args (keywords, dB) are flattened to the
   numeric/raw values the C side wants."
  [cmd]
  (case (first cmd)
    :clock       ["clock"  (c/clock->id  (nth cmd 1))]
    :route       ["route"  (c/output->id (nth cmd 1)) (c/source->id (nth cmd 2))]
    :bus-volume  ["bus"    (c/bus->id    (nth cmd 1)) (c/db->raw    (nth cmd 2))]
    :mixer-input ["mixer"  (nth cmd 1)                (c/source->id (nth cmd 2))]
    :matrix      ["matrix" (c/matrix-node (nth cmd 1) (nth cmd 2))
                           (c/db->raw    (nth cmd 3))]
    :save        ["save" "confirm"]
    (throw (ex-info "Unknown preset command op" {:cmd cmd}))))

(defn dispatch!
  "Execute a single preset command through an open daemon."
  [daemon cmd]
  (d/request daemon (cmd->argv cmd)))

(defn execute!
  "Run a sequence of preset commands through a fresh daemon.
   Returns {:applied [...completed]} on success, or
   {:applied [...] :failed cmd :error e} on first failure.
   The daemon is always closed before returning."
  [commands]
  (d/with-daemon [dm]
    (loop [applied []
           [cmd & more] commands]
      (if (nil? cmd)
        {:applied applied}
        (let [res (try {:ok (dispatch! dm cmd)}
                       (catch Exception e {:ex e}))]
          (if (:ex res)
            {:applied applied :failed cmd :error (:ex res)}
            (recur (conj applied cmd) more)))))))
