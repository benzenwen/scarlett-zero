(ns scarlett.daemon
  "Manages a long-running `./scarlett_ctl daemon` subprocess. Commands
   go in as newline-terminated argv-style lines; responses come back
   as one EDN map per line. Lifecycle is explicit (open/close or
   with-daemon) so any client — CLI session, integration test, future
   native app — can drive it the same way."
  (:require [babashka.process :as p]
            [clojure.edn :as edn]
            [clojure.string :as str])
  (:import [java.io BufferedReader InputStreamReader OutputStreamWriter]))

(def ^:dynamic *binary* "./scarlett_ctl")

;; ─── Internal helpers ─────────────────────────────────────────

(defn- parse-response [line]
  (when (nil? line)
    (throw (ex-info "scarlett_ctl daemon EOF" {})))
  (let [parsed (try (edn/read-string line)
                    (catch Exception e
                      (throw (ex-info "daemon emitted non-EDN response"
                                      {:line line} e))))]
    (when-not (map? parsed)
      (throw (ex-info "daemon emitted non-EDN response (not a map)"
                      {:line line :parsed parsed})))
    parsed))

(defn- wrap-writer [in]
  (if (instance? java.io.Writer in)
    in
    (OutputStreamWriter. in)))

(defn- wrap-reader [out]
  (if (instance? BufferedReader out)
    out
    (BufferedReader. (InputStreamReader. out))))

;; ─── Public API ───────────────────────────────────────────────

(defn open
  "Spawn ./scarlett_ctl daemon, wait for its {:ok true :ready true}
   line, return a Daemon handle map. Throws if the subprocess refuses
   to come up (e.g. device held by another process)."
  []
  (let [proc (p/process [*binary* "daemon"]
                        {:in :pipe :out :pipe :err :inherit})
        in   (wrap-writer (:in proc))
        out  (wrap-reader (:out proc))
        ready (parse-response (.readLine out))]
    (when-not (:ready ready)
      (throw (ex-info "daemon did not signal ready"
                      {:first-line ready})))
    {:proc proc :in in :out out :lock (Object.)}))

(defn request
  "Send a single command line to the daemon and return the parsed
   EDN response. Throws on an :error response, on EOF, or on a
   non-EDN line. `line` can be a string or a seq of tokens (which
   are joined with spaces)."
  [daemon line]
  (let [line-str (if (string? line) line (str/join " " (map str line)))]
    (locking (:lock daemon)
      (.write ^java.io.Writer (:in daemon) (str line-str \newline))
      (.flush ^java.io.Writer (:in daemon))
      (let [resp (parse-response (.readLine ^BufferedReader (:out daemon)))]
        (when (and (map? resp) (:error resp))
          (throw (ex-info (str "daemon error: " (:error resp))
                          {:command line-str :response resp})))
        resp))))

(defn close
  "Send quit, drain the bye response, wait for the subprocess to
   exit. Safe to call multiple times and safe to call on a daemon
   whose child has already died."
  [daemon]
  (try
    (.write ^java.io.Writer (:in daemon) "quit\n")
    (.flush ^java.io.Writer (:in daemon))
    (.readLine ^BufferedReader (:out daemon))
    (catch Exception _ nil))
  (try (.close ^java.io.Writer     (:in  daemon)) (catch Exception _ nil))
  (try (.close ^BufferedReader     (:out daemon)) (catch Exception _ nil))
  @(:proc daemon)
  nil)

(defmacro with-daemon
  "Open a daemon, bind to sym, run body, always close."
  [[sym] & body]
  `(let [~sym (open)]
     (try ~@body (finally (close ~sym)))))
