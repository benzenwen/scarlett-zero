(ns scarlett.io
  "Preset file persistence. Read/write canonical State maps to EDN
   files with schema validation on load."
  (:refer-clojure :exclude [load])
  (:require [clojure.edn :as edn]
            [clojure.java.io :as jio]
            [clojure.pprint :as pp]
            [malli.core :as m]
            [scarlett.state :as s]))

(defn save!
  "Pretty-print a canonical State to path as EDN. Overwrites."
  [path state]
  (with-open [w (jio/writer (jio/file path))]
    (binding [*out* w] (pp/pprint state)))
  path)

(defn load
  "Read an EDN preset from path and validate against State. Returns
   the parsed state. Throws ex-info if the file does not conform."
  [path]
  (let [raw   (edn/read-string (slurp path))
        error (m/explain s/State raw)]
    (when error
      (throw (ex-info (str "Preset at " path " does not conform to State")
                      {:path path :error error})))
    raw))

(defn load-lenient
  "Read an EDN preset without schema validation. For partial presets
   (e.g. a diff baseline that only specifies clock + routing)."
  [path]
  (edn/read-string (slurp path)))
