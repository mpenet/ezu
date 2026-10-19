;; ABOUTME: Specs for secret values read from the environment, a private file,
;; ABOUTME: or a command's output, and the errors that never show them.
(local secrets (require :ezu.secrets))

(fn private-file [text ?mode]
  (let [path (os.tmpname)]
    (with-open [f (io.open path :w)]
      (f:write text))
    (os.execute (.. "chmod " (or ?mode "600") " " path))
    path))

(describe "secret sources"
          (fn []
            (it "tells sources from values"
                (fn []
                  (assert.is_true (secrets.source? "env:HOME"))
                  (assert.is_true (secrets.source? {:env "HOME"}))
                  (assert.is_true (secrets.source? {:file "/x"}))
                  (assert.is_true (secrets.source? {:cmd ["echo" "x"]}))
                  (assert.is_false (secrets.source? "cmd:echo x"))
                  (assert.is_false (secrets.source? "plain"))
                  (assert.is_false (secrets.source? {:env "A" :file "B"}))))
            (it "passes values through"
                (fn []
                  (assert.are.equal "plain" (secrets.resolve "plain" "x"))
                  (assert.are.equal "cmd:echo x"
                                    (secrets.resolve "cmd:echo x" "x"))))
            (it "reads the environment"
                (fn []
                  (assert.are.equal (os.getenv "HOME")
                                    (secrets.resolve {:env "HOME"} "x"))
                  (assert.are.equal (os.getenv "HOME")
                                    (secrets.resolve "env:HOME" "x"))
                  (assert.has.error #(secrets.resolve {:env "EZU_NOT_SET_42"}
                                                      "params.token")
                                    "params.token: environment variable EZU_NOT_SET_42 is not set")))
            (it "reads a private file, without its last newline"
                (fn []
                  (let [path (private-file "s3cret with spaces \n\n")]
                    (assert.are.equal "s3cret with spaces \n"
                                      (secrets.resolve {:file path} "x"))
                    (os.remove path))))
            (it "refuses a file others can read"
                (fn []
                  (let [path (private-file "s3cret" "640")
                        (ok err) (pcall secrets.resolve {:file path}
                                        "params.secret")]
                    (os.remove path)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "params.secret: secret file" 1 true)
                                      (tostring err))
                    (assert.is_truthy (: (tostring err) :find
                                         "can be read by other users" 1 true)
                                      (tostring err))
                    (assert.is_nil (: (tostring err) :find "s3cret" 1 true)))))
            (it "runs a command, its arguments as given, once per run"
                (fn []
                  (let [count-file (os.tmpname)
                        script (private-file (.. "echo run >> " count-file
                                                 "\nprintf '%s\\n' \"$1\"\n")
                                             "700")
                        source {:cmd [script "it's a \"secret\" $HOME"]}]
                    (assert.are.equal "it's a \"secret\" $HOME"
                                      (secrets.resolve source "x"))
                    (assert.are.equal "it's a \"secret\" $HOME"
                                      (secrets.resolve source "x"))
                    (let [runs (with-open [f (io.open count-file)]
                                 (f:read :*a))]
                      (os.remove count-file)
                      (os.remove script)
                      (assert.are.equal "run\n" runs)))))
            (it "says a command failed, never what it printed"
                (fn []
                  (let [(ok err) (pcall secrets.resolve
                                        {:cmd ["sh"
                                               "-c"
                                               "echo leaked-value; exit 3"]}
                                        "params.secret")]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "params.secret: command sh failed (exit 3)"
                                         1 true)
                                      (tostring err))
                    (assert.is_nil (: (tostring err) :find "leaked-value" 1
                                      true)))))
            (it "describes what is wrong with a source"
                (fn []
                  (assert.is_nil (secrets.problem {:cmd ["a" "b"]}))
                  (assert.is_nil (secrets.problem "value"))
                  (assert.are.equal "cmd must be a non-empty list of strings"
                                    (secrets.problem {:cmd "a b"}))
                  (assert.are.equal "must be a string, or one of {\"env\": NAME}, {\"file\": PATH}, {\"cmd\": [COMMAND, ARG…]}"
                                    (secrets.problem {:command ["a"]}))))))
