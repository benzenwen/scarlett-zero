(ns scarlett.preset
  "Pure diffing of two canonical State maps into a deterministic list
   of commands. Commands are vectors that scarlett.transport knows how
   to execute against the device; they are also safe to serialize to
   EDN for inspection, review, or logging."
  (:require [malli.core :as m]
            [scarlett.codec :as c]
            [scarlett.state :as s]))

;; ─── Command schema ───────────────────────────────────────────

(def Command
  [:multi {:dispatch first}
   [:clock        [:tuple [:= :clock]        c/ClockKw]]
   [:route        [:tuple [:= :route]        c/OutputKw     c/SourceKw]]
   [:bus-volume   [:tuple [:= :bus-volume]   c/BusKw        [:or :double [:= :silence]]]]
   [:mixer-input  [:tuple [:= :mixer-input]  c/MixerSlotId  c/SourceKw]]
   [:matrix       [:tuple [:= :matrix]       c/MixerSlotId  c/MixBusId
                                             [:or :double [:= :silence]]]]
   [:save         [:tuple [:= :save]]]])

(def Commands [:sequential Command])

;; ─── Section diffs ────────────────────────────────────────────

(defn diff-clock [from to]
  (let [f (:source (:clock from))
        t (:source (:clock to))]
    (when (and t (not= f t)) [[:clock t]])))

(defn- diff-map
  "Generic diff over two maps sharing the same key domain. Calls
   `emit` with key, new-value when they differ. Deterministic by
   sorted key order."
  [from to emit]
  (let [ks (sort (into (set (keys from)) (keys to)))]
    (->> ks
         (keep (fn [k]
                 (let [f (get from k)
                       t (get to k)]
                   (when (and t (not= f t))
                     (emit k t))))))))

(defn diff-routing [from to]
  (diff-map (:routing from) (:routing to)
            (fn [out-kw src-kw] [:route out-kw src-kw])))

(defn diff-buses
  "Diffs bus volumes only. Mute is intentionally skipped — the 18i20
   mute encoding is unresolved (project brief Q1)."
  [from to]
  (diff-map
   (into {} (for [[k v] (:buses from)] [k (:volume-db v)]))
   (into {} (for [[k v] (:buses to)]   [k (:volume-db v)]))
   (fn [bus-kw db] [:bus-volume bus-kw db])))

(defn diff-mixer-inputs [from to]
  (diff-map (:mixer-inputs from) (:mixer-inputs to)
            (fn [slot src-kw] [:mixer-input slot src-kw])))

(defn diff-matrix
  "Matrix maps are sparse: missing cells are silent. Any cell that
   transitions from a value to absent is emitted with :silence so
   the target state is reached exactly."
  [from to]
  (let [f (:matrix from)
        t (:matrix to)
        ks (sort (into (set (keys f)) (keys t)))]
    (->> ks
         (keep (fn [k]
                 (let [fv (get f k :silence)
                       tv (get t k :silence)]
                   (when (not= fv tv)
                     (let [[slot bus] k]
                       [:matrix slot bus tv]))))))))

;; ─── Top-level diff ───────────────────────────────────────────

(defn diff
  "Return a command list that transforms state `from` into state `to`.
   Order: clock → mixer-inputs → matrix → routing → bus-volumes.
   Signal-flow–first ordering keeps intermediate states quieter —
   you don't route freshly-reassigned inputs through a stale mix."
  [from to]
  (vec
   (concat
    (diff-clock         from to)
    (diff-mixer-inputs  from to)
    (diff-matrix        from to)
    (diff-routing       from to)
    (diff-buses         from to))))

;; ─── Validation ───────────────────────────────────────────────

(defn validate-commands
  "Return nil if commands conform to Commands schema, else a Malli
   explanation."
  [commands]
  (m/explain Commands commands))

;; ─── Convenience: apply to scarlett.state/State ───────────────
;; A preset FILE on disk is just a full or partial State map — we
;; diff it against the current device state to produce commands.

(defn empty-state
  "A neutral zero-state useful for 'apply-as-if-fresh' flows: all
   matrix cells silent, no bus volumes, etc. Not validated — it
   omits required fields by design. Meant as a diff baseline, not
   as a device state."
  []
  {:clock        {}
   :routing      {}
   :buses        {}
   :mixer-inputs {}
   :matrix       {}})
