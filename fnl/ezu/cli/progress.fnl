;; ABOUTME: Live progress of Arazzo workflows: a line per step, rewritten in place
;; ABOUTME: on a terminal while the step runs or polls, plain lines in logs.
(local socket (require :socket))
(local util (require :ezu.util))
(local width (require :ezu.cli.width))
(local pretty (require :ezu.pretty))

(fn wait-text [seconds]
  "A wait before running a step again: 3s, 0.5s, 1m30s."
  (if (>= seconds 60) (util.duration seconds)
      (= seconds (math.floor seconds)) (string.format "%ds" seconds)
      (string.format "%.1fs" seconds)))

(fn op-name [op-ref calls]
  "What a step calls, briefly: getPet for $sourceDescriptions.api.getPet,
GET /pets/{id} for an operationPath, workflow ID for a workflow, workflow
SOURCE.ID for another document's."
  (let [ref (tostring op-ref)
        id (ref:match "^%$sourceDescriptions%.[^%.]+%.(.+)$")
        (path method) (ref:match "#/paths/([^/]+)/(%a+)$")]
    (if (= calls :workflow)
        (.. "workflow " (or (ref:match "^%$sourceDescriptions%.(.+)$") ref))
        id
        id
        path
        (.. (method:upper) " "
            (pick-values 1 (: (path:gsub "~1" "/") :gsub "~0" "~")))
        ref)))

(fn one-line [s]
  "s made safe for a line of progress: control characters escaped, and line
breaks and tabs as spaces, so a line rewritten in place stays one line."
  (pick-values 1 (: (util.printable (tostring s)) :gsub "[\n\t]" " ")))

(fn pad [s n]
  (.. s (string.rep " " (- n (width.of s)))))

(fn fit [text columns]
  "text cut with … to fit in a terminal of columns, leaving the last column
free; color codes are kept and take no room."
  (let [limit (- columns 1)]
    (if (<= (width.of (pick-values 1 (text:gsub "\27%[[%d;]*m" ""))) limit)
        text
        (let [out []]
          (var used 0)
          (var pos 1)
          (var full false)
          (while (and (<= pos (length text)) (not full))
            (let [code (text:match "^\27%[[%d;]*m" pos)
                  piece (or code
                            (text:match "^[%z\1-\127\194-\244][\128-\191]*" pos)
                            (text:sub pos pos))
                  w (if code 0 (width.of piece))]
              (if (> (+ used w 1) limit) (set full true)
                  (do
                    (table.insert out piece)
                    (set used (+ used w))
                    (set pos (+ pos (length piece)))))))
          (.. (table.concat out) "…"
              (if (text:find "\27[" 1 true) "\27[0m" ""))))))

(fn same-step-again? [e]
  "Whether action event e runs its step again: a retry, or a goto to itself."
  (or (= e.action.type :retry)
      (and (= e.action.type :goto) (= e.action.stepId e.step))))

(fn action-text [e]
  (let [wait (if (> e.wait 0) (.. " in " (wait-text e.wait)) "")
        a e.action]
    (match a.type
      :retry (.. "retry" wait)
      :end "end"
      _ (if (same-step-again? e) (.. "again" wait) a.stepId
            (.. "goto " (tostring a.stepId))
            (.. "goto workflow " (tostring a.workflowId))))))

(fn reporter [{: write : tty : color : columns : clock}]
  "{:on-step :warn :finish}: on-step takes the events of ezu.arazzo's
:on-step and writes their progress with write; warn writes a warning on a line
of its own; finish (ok workflow-id seconds) ends with the workflow's line. On a terminal (tty), the line of a running or polled step
is rewritten in place, cut to the terminal's columns when given."
  (let [clock (or clock socket.gettime)
        paint #(pretty.paint $1 $2 color)
        widths {}
        streaks {}
        looping {}]
    (var held nil)
    (var pending nil)

    (fn end-pending []
      "End the line kept on a terminal, leaving its header."
      (when pending
        (write (.. "\r\27[K" pending.header "\n"))
        (set pending nil)))

    (fn show [text slot ?header]
      "Write a line; with ?header, a line kept on a terminal until the next
one, which replaces it when it is about the same step (slot), and otherwise
leaves ?header in its place."
      (when (and pending (not= pending.slot slot))
        (end-pending))
      (if (not tty) (write (.. text "\n")) ?header
          (do
            (write (.. "\r\27[K" (if columns (fit text columns) text)))
            (set pending {: slot :header ?header}))
          (do
            (write (.. "\r\27[K" text "\n"))
            (set pending nil))))

    (fn head [e mark]
      (let [w (or (. widths e.workflow) {:id 0 :op 0})
            n (tostring e.count)]
        (.. (string.rep "  " (or e.depth 0)) mark " "
            (string.rep " " (- (length n) (length (tostring e.index)))) e.index
            "/" n " " (pad (one-line e.step) w.id) "  "
            (pad (one-line (op-name e.op-ref e.calls)) w.op))))

    (fn status-text [e]
      (let [status (?. e :response :status)]
        (if e.error (paint :fail "error") (= (type status) :number)
            (paint (if (< status 300) :ok
                       (< status 400) :dim
                       :fail) (tostring status)) status
            (tostring status))))

    (fn result-line [e mark ?extra]
      (let [streak (. streaks (.. e.workflow ":" e.step))
            attempts (if streak (+ 1 (- e.attempt streak.first)) 1)
            timing (if (> attempts 1)
                       (.. attempts " attempts · "
                           (util.duration (- e.at streak.start)))
                       (util.duration (or e.elapsed 0)))
            status (status-text e)]
        (.. (head e mark) "  " timing (if status (.. "  " status) "")
            (if ?extra (.. "  " ?extra) ""))))

    (fn mark-of [e]
      (if e.passed (paint :ok "✓") (paint :fail "✗")))

    (fn flush-held []
      "Show the step result waiting for the action that may follow it."
      (when held
        (let [e held]
          (set held nil)
          (show (result-line e (mark-of e)) (.. e.workflow ":" e.step))
          (tset streaks (.. e.workflow ":" e.step) nil))))

    (fn on-action [e]
      (let [slot (.. e.workflow ":" e.step)
            done (when (and held (= (.. held.workflow ":" held.step) slot))
                   held)
            again (same-step-again? e)
            extra (one-line (if (?. done :failure)
                                (.. (action-text e) " · " done.failure)
                                (action-text e)))]
        (if done
            (do
              (set held nil)
              (let [line (result-line done
                                      (if again (paint :warn "↻")
                                          (mark-of done))
                                      (paint :dim extra))]
                (if again
                    (show line slot line)
                    (do
                      (show line slot)
                      (tset streaks slot nil)))))
            (flush-held))
        (tset looping slot again)))

    (fn on-running [e]
      (flush-held)
      (let [slot (.. e.workflow ":" e.step)
            streak (. streaks slot)]
        (if (and streak (. looping slot))
            (when tty
              (let [line (.. (head e (paint :warn "↻")) "  attempt "
                             e.attempt " · "
                             (util.duration (- e.at streak.start)) " …")]
                (show line slot line)))
            (do
              (tset streaks slot {:start e.at :first e.attempt})
              (when tty
                (let [line (head e (paint :dim "→"))]
                  (show (.. line "  …") slot
                        (pick-values 1 (line:gsub "%s+$" "")))))))
        (tset looping slot nil)))

    {:on-step (fn [e]
                (match e.status
                  :workflow (let [names (icollect [_ s (ipairs e.steps)]
                                          (one-line s.step))
                                  ops (icollect [_ s (ipairs e.steps)]
                                        (one-line (op-name s.op-ref s.calls)))]
                              (tset widths e.workflow
                                    {:id (accumulate [m 0 _ s (ipairs names)]
                                           (math.max m (width.of s)))
                                     :op (accumulate [m 0 _ s (ipairs ops)]
                                           (math.max m (width.of s)))}))
                  :running (do
                             (set e.at (clock))
                             (on-running e))
                  :done (do
                          (set e.at (clock))
                          (flush-held)
                          (set held e))
                  :action (do
                            (set e.at (clock))
                            (on-action e))))
     :warn (fn [message]
             (end-pending)
             (write (.. "warning: " (util.printable (tostring message)) "\n")))
     :finish (fn [ok workflow-id seconds]
               (flush-held)
               (end-pending)
               (write (.. (if ok (paint :ok "✓") (paint :fail "✗"))
                          " workflow " (one-line workflow-id)
                          (if ok "" " failed") "  " (util.duration seconds) "\n")))}))

{: reporter : fit : one-line}
