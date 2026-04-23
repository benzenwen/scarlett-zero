(ns scarlett.cli
  "Command-line entry point. Parses argv, dispatches to transport/
   preset/io, and formats output for a human (or EDN if requested)."
  (:require [clojure.pprint :as pp]
            [clojure.string :as str]
            [scarlett.codec :as c]
            [scarlett.device :as d]
            [scarlett.io :as sio]
            [scarlett.preset :as preset]
            [scarlett.state :as state]
            [scarlett.transport :as t]))

;; ─── Output helpers ───────────────────────────────────────────

(defn- edn-mode? [args] (some #{"--edn"} args))

(defn- println-err [& xs]
  (binding [*out* *err*] (apply println xs)))

(defn- emit [edn? value]
  (if edn? (pp/pprint value) (println value)))

(defn- fmt-db [db]
  (cond
    (= db :silence) "-inf"
    (zero? db)      "  0.0 dB"
    :else           (format "%+5.1f dB" (double db))))

(defn- kw-col
  "Right-pad a keyword's name to width for column alignment."
  [kw width]
  (format (str "%-" width "s") (name kw)))

;; ─── Subcommand implementations ───────────────────────────────

(defn- cmd-doctor [args]
  (let [info (t/doctor)]
    (if (edn-mode? args)
      (pp/pprint info)
      (do
        (println "device found:  " (get-in info [:device :found]))
        (println "blockers:      " (or (seq (:blockers info)) "(none)"))
        (println "chrome running:" (:chrome-running info))
        (println "readable:      " (:readable info))))))

(defn- cmd-clock [args]
  (cond
    (and (seq args) (not= "--edn" (first args)))
    (let [kw (keyword (first args))]
      (t/set-clock! kw)
      (println "clock source set to" (name kw)))

    :else
    (let [raw  (t/read-clock)
          src  (c/id->clock (:source raw))
          rate (:rate raw)]
      (if (edn-mode? args)
        (pp/pprint {:source src :rate rate})
        (println (format "clock: %s @ %d Hz" (name src) rate))))))

(defn- cmd-rate [args]
  (let [{:keys [rate]} (t/read-rate)]
    (if (edn-mode? args)
      (pp/pprint {:rate rate})
      (println rate "Hz"))))

(defn- cmd-route [args]
  (let [positional (remove #{"--edn"} args)]
    (cond
      (= 2 (count positional))
      (let [[out-s src-s] positional
            out (keyword out-s)
            src (keyword src-s)
            r   (t/set-route! out src)]
        (println (format "route %s <- %s (was id=%d, now id=%d)"
                         (name out) (name src) (:before r) (:after r))))

      (seq positional)
      (do (println-err "usage: scarlett route [<output> <source>]") (System/exit 1))

      :else
      (let [raw (t/read-routes)
            pairs (sort-by #(d/outputs (first %))
                           (for [[out-id src-id] raw]
                             [(c/id->output out-id) (c/id->source src-id)]))]
        (if (edn-mode? args)
          (pp/pprint (into {} pairs))
          (doseq [[o s] pairs]
            (println (kw-col o 10) "<-" (name s))))))))

(defn- cmd-bus [args]
  (let [buses (t/read-buses)
        state (state/parse-buses buses)]
    (if (edn-mode? args)
      (pp/pprint state)
      (doseq [[bus-kw {:keys [volume-db mute-raw]}]
              (sort-by #(d/buses (first %)) state)]
        (println (kw-col bus-kw 10) (fmt-db volume-db)
                 (format "  mute-raw=0x%04x" mute-raw))))))

(defn- cmd-mixer [args]
  (let [raw   (t/read-mixer)
        state (state/parse-mixer-inputs raw)]
    (if (edn-mode? args)
      (pp/pprint state)
      (doseq [slot (range d/num-mixer-inputs)
              :let [src (get state slot)]
              :when src]
        (println (format "slot %2d <- %s" slot (name src)))))))

(defn- cmd-matrix [args]
  (let [raw   (t/read-matrix)
        state (state/parse-matrix raw)]
    (if (edn-mode? args)
      (pp/pprint state)
      (doseq [[[slot bus] db] (sort state)]
        (println (format "slot %2d → mix %d  %s"
                         slot bus (fmt-db db)))))))

(defn- cmd-dump [args]
  (let [st (t/dump)]
    (if (edn-mode? args)
      (pp/pprint st)
      (do
        (println "── clock ──")
        (println (format "%s @ %d Hz"
                         (name (get-in st [:clock :source]))
                         (get-in st [:clock :rate])))
        (println)
        (println "── routing ──")
        (doseq [[o s] (sort-by #(d/outputs (first %)) (:routing st))]
          (println (kw-col o 10) "<-" (name s)))
        (println)
        (println "── buses ──")
        (doseq [[bus-kw {:keys [volume-db mute-raw]}]
                (sort-by #(d/buses (first %)) (:buses st))]
          (println (kw-col bus-kw 10) (fmt-db volume-db)
                   (format "  mute-raw=0x%04x" mute-raw)))
        (println)
        (println "── mixer-inputs ──")
        (doseq [slot (range d/num-mixer-inputs)
                :let [src (get-in st [:mixer-inputs slot])]
                :when src]
          (println (format "slot %2d <- %s" slot (name src))))
        (println)
        (println "── matrix (non-silent) ──")
        (doseq [[[slot bus] db] (sort (:matrix st))]
          (println (format "slot %2d → mix %d  %s"
                           slot bus (fmt-db db))))))))

(defn- cmd-save [_args]
  (println "persisting device state to flash…")
  (t/save!)
  (println "ok"))

(defn- cmd-preset [args]
  (let [[sub & more] (remove #{"--edn"} args)]
    (case sub
      "save"
      (let [[path] more]
        (when-not path
          (println-err "usage: scarlett preset save <path>") (System/exit 1))
        (sio/save! path (t/dump))
        (println "saved →" path))

      "diff"
      (let [[path] more]
        (when-not path
          (println-err "usage: scarlett preset diff <path>") (System/exit 1))
        (let [target  (sio/load path)
              current (t/dump)
              cmds    (preset/diff current target)]
          (if (edn-mode? args)
            (pp/pprint cmds)
            (do (println (count cmds) "command(s) would apply:")
                (doseq [c cmds] (println " " (pr-str c)))))))

      "apply"
      (let [[path] more]
        (when-not path
          (println-err "usage: scarlett preset apply <path>") (System/exit 1))
        (let [target  (sio/load path)
              current (t/dump)
              cmds    (preset/diff current target)
              result  (t/execute! cmds)]
          (println "applied:" (count (:applied result)) "/ total:" (count cmds))
          (when-let [failed (:failed result)]
            (println-err "failed on:" (pr-str failed))
            (println-err (ex-message (:error result)))
            (System/exit 1))))

      (do (println-err "preset subcommands: save | diff | apply")
          (System/exit 1)))))

;; ─── Usage & dispatch ─────────────────────────────────────────

(defn- usage []
  (println
   (str/join "\n"
    ["scarlett — Focusrite Scarlett 18i20 Gen 1 control (Babashka frontend)"
     ""
     "Usage:"
     "  scarlett dump [--edn]              Full state dump"
     "  scarlett clock [<source>]          Read or set clock (internal|spdif|adat)"
     "  scarlett rate                      Read current sample rate"
     "  scarlett route [<out> <src>]       Read all routes, or set one"
     "  scarlett bus                       Read all bus volumes"
     "  scarlett mixer                     Read mixer-input assignments"
     "  scarlett matrix                    Read non-silent matrix gains"
     "  scarlett save                      Persist current state to flash"
     "  scarlett doctor                    Device health + competing processes"
     ""
     "  scarlett preset save <path>        Dump current state to an EDN file"
     "  scarlett preset diff <path>        Show commands to reach preset state"
     "  scarlett preset apply <path>       Apply a preset to the device"
     ""
     "Flags:"
     "  --edn                              Emit raw EDN instead of formatted text"
     ""
     "Outputs use keywords; e.g. :mon-l, :daw-1, :anlg-3, :spdif-l,"
     ":adat-in-N (as source), :adat-N (as output/bus), :mix-1..10, :off."])))

(defn -main [& argv]
  (let [[cmd & args] argv]
    (try
      (case cmd
        "dump"    (cmd-dump    args)
        "clock"   (cmd-clock   args)
        "rate"    (cmd-rate    args)
        "route"   (cmd-route   args)
        "bus"     (cmd-bus     args)
        "mixer"   (cmd-mixer   args)
        "matrix"  (cmd-matrix  args)
        "save"    (cmd-save    args)
        "doctor"  (cmd-doctor  args)
        "preset"  (cmd-preset  args)
        ("--help" "-h" "help" nil) (usage)
        (do (println-err "unknown command:" cmd)
            (usage)
            (System/exit 1)))
      (catch clojure.lang.ExceptionInfo e
        (println-err "error:" (ex-message e))
        (when-let [d (ex-data e)]
          (binding [*out* *err*] (pp/pprint d)))
        (System/exit 1)))))
