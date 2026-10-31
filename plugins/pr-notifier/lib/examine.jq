# examine.jq: one PR's issue timeline and state, turned into wake events.
#
# bin/pr-notifier runs it three times per examined PR, with --arg phase:
#   edits   prints the node ids (one per line) of comments edited after the
#           baseline, whose editor the notifier then reads through GraphQL
#           (the REST timeline names a comment's author, never its editor)
#   need    prints the logins (one per line) whose owner-check result the
#           filter needs (needs_owner): new items, and edits, by an actor that
#           is neither the sessions' own login nor any bot
#   result  prints {ps, events, log}: the PR's new cursor, the events to
#           queue, and one record per filtered item for the log
#
# Inputs:
#   $tl            --slurpfile: the timeline, as gh's --paginate --slurp pages
#   $pr            --slurpfile: the PR (GET /repos/{o}/{r}/pulls/{n})
#   $psf           --slurpfile: this PR's cursor from state.json ({} when new)
#   $me            --arg: the sessions' own login
#   $bots          --argjson: the configured review-bot logins
#   $baseline      --arg: the earliest subscribed_at of the PR's subscriptions
#   $now           --argjson: epoch seconds
#   $retry_window  --argjson: seconds a failed owner check is retried
#   $editors       --argjson: {comment node id: {login, type}} (need, result)
#   $owners        --argjson: {lowercased login: owner-check exit code} (result)
#
# The filter reads the timeline, never the notification: a notification
# carries no author and no event type (the #292 spike, Design corrections).

def lc: ascii_downcase;

# A Codex summary comment's review state, "<commit>:<status>", read from its
# codex-review-state line; null for any other comment. Codex's clean result
# edits this comment and adds a reaction, and neither is a new timeline item.
def codex_state:
  (.body // "") as $b
  | if ($b | startswith("<!-- codex-pull-request-review-summary -->")) then
      ((try ($b | capture("codex-review-state:v1 (?<j>.*?) -->").j | fromjson | .code_review
              | "\(.commit_sha // ""):\(.status // "")") catch null) // "")
    else null end;

# The timeline items that can wake a session, normalized. A single line
# comment is a review too; a reply in a thread can surface as line-commented.
# A line comment whose review is itself on the timeline is that review's,
# so one review wakes one line however many comments it carries.
def items:
  ($tl[0] // []) | (if type == "array" then flatten else [] end) as $all
  | ([ $all[] | select(type == "object" and .event == "reviewed") | .id | tostring ]
     | map({(.): true}) | add // {}) as $reviews
  | ($bots | map(lc)) as $bots_lc
  | [ $all[] | select(type == "object") as $e
    | if $e.event == "commented" then
        {key: "comment:\($e.id)", kind: "comment", actor: ($e.user.login // ""),
         type: ($e.user.type // ""), url: ($e.html_url // ""), at: ($e.created_at // ""),
         id: ($e.id | tostring), node_id: ($e.node_id // ""),
         updated_at: ($e.updated_at // $e.created_at // ""),
         # Only a configured bot's comment can be a Codex summary: anyone can
         # post one's text, so a stranger's copy is an ordinary comment.
         codex: (if ($e.user.type // "") == "Bot" and ($bots_lc | index(($e.user.login // "") | lc)) != null
                 then ($e | codex_state) else null end)}
      elif $e.event == "reviewed" and (($e.state // "") | lc) != "pending" then
        {key: "review:\($e.id)", kind: "review", actor: ($e.user.login // ""),
         type: ($e.user.type // ""), url: ($e.html_url // ""), at: ($e.submitted_at // "")}
      elif $e.event == "line-commented" then
        ($e.comments // [])[] | select(type == "object")
        | select($reviews[(.pull_request_review_id // "") | tostring] | not)
        | {key: "review_comment:\(.id)", kind: "review", actor: (.user.login // ""),
           type: (.user.type // ""), url: (.html_url // ""), at: (.created_at // "")}
      else empty end ];

# A configured bot must also be typed Bot by GitHub, so a user account that
# takes a bot's display login (e.g. "Copilot") is checked like anyone else.
# Any other Bot, or a login owner-check would refuse on its format alone,
# settles at once rather than being rechecked for the retry window.
def class($i):
  ($i.actor | lc) as $a
  | if $a == "" then "unknown"
    elif $a == ($me | lc) then "own"
    elif $i.type == "Bot" and (($bots | map(lc) | index($a)) != null) then "bot"
    elif $i.type == "Bot" or ($a | test("^[a-z0-9][a-z0-9-]{0,38}$") | not) then "other-bot"
    else "check" end;

def record($i; $verdict; $reason):
  {key: $i.key, actor: ($i.actor // ""), verdict: $verdict, reason: $reason};

($psf[0] // {}) as $ps
| ($ps.seen // []) as $seen
| ($seen | map({(.): true}) | add // {}) as $seenset
| items as $items
| [ $items[] | select($seenset[.key] | not) ] as $new
| ($ps.comments // {}) as $tracked
| ($editors // {}) as $editors
# A comment's updated_at as last recorded. One with no entry was last seen
# unedited, so its creation time stands in.
| def prev_updated($i): (($tracked[$i.id] // {}).updated_at) // $i.at;
# A comment edited after the baseline (Codex's summary has its own rule),
# whether or not its creation is decided yet: a stranger's comment still being
# rechecked can carry the owner's edit. The edit is its editor's, whoever
# wrote the comment, and is decided apart from the comment: its own owner
# check, the same cached one, and its own recheck window. No comment pins
# anyone's ownership. (The result phase skips an edit the first pass already
# covered, by the updated_at it just recorded.)
  def edited($i):
    $i.kind == "comment" and $i.codex == null
    and $i.updated_at >= $baseline and $i.updated_at != prev_updated($i);
# The edit as an item of its editor's, or null while the editor is unread.
  def edit($i): ($editors[$i.node_id] // null) as $ed
    | if $ed == null then null else $i + {actor: ($ed.login // ""), type: ($ed.type // "")} end;
# The one rule for who needs an owner check, shared by the need and result
# phases: an item the filter decides, by a login that is neither the
# sessions' own nor a bot's.
  def needs_owner($i): class($i) == "check";
  def verdict($i):
    class($i) as $c
    | if $c == "own" then {keep: false, reason: "own login", settle: true}
      elif $c == "unknown" then {keep: false, reason: "no actor", settle: true}
      elif $c == "other-bot" then {keep: false, reason: "a bot or app not configured", settle: true}
      elif $c == "bot" then {keep: true, reason: "review bot"}
      elif needs_owner($i) then
        ($owners[$i.actor | lc]) as $o
        | if $o == 0 then {keep: true, reason: "owner"}
          elif $o == 3 then {keep: false, reason: "same-account login (owner-check 3)", settle: true}
          else {keep: false, reason: "not the owner (owner-check \($o // "not run"))", settle: false} end
      else {keep: false, reason: "unclassified", settle: true} end;
# A failed or negative owner check on an edit: the recorded updated_at stays
# put, so the edit is seen again, until the window for this very edit ends.
  def retry_edit($i; $why):
    ($tracked[$i.id] // {}) as $old
    | if $old.edit_retry == null or $old.edit_retry_for != $i.updated_at then
        .comments[$i.id] = {updated_at: prev_updated($i), edit_retry: $now, edit_retry_for: $i.updated_at}
        | .log += [record($i; "drop"; "\($why); rechecked for \($retry_window)s")]
      elif $now - $old.edit_retry >= $retry_window then
        .comments[$i.id] = {updated_at: $i.updated_at}
        | .log += [record($i; "drop"; "\($why); settled")]
      else . end;
  if $phase == "edits" then
    $items[] | select(edited(.)) | .node_id | select(. != "")
  elif $phase == "need" then
    [ ($new[] | select(.at >= $baseline) | select(needs_owner(.)) | .actor),
      ($items[] | select(edited(.)) | edit(.) // empty | select(needs_owner(.)) | .actor) ]
    | unique_by(lc) | .[]
  else
    ($pr[0] // {}) as $p
    | reduce $new[] as $i (
        {seen: [], retry: ($ps.retry // {}), comments: $tracked, events: [], log: []};
        if $i.at < $baseline then
          # Before every subscription: never an event. A bot's comment is still
          # tracked, so a later edit of Codex's summary is caught.
          .seen += [$i.key]
          | if $i.kind == "comment" and class($i) == "bot" and $i.codex != null then
              .comments[$i.id] = {updated_at: $i.updated_at, codex: $i.codex}
              | if ($i.codex | endswith(":completed")) and $i.updated_at >= $baseline then
                  .events += [{key: "codex:\($i.id):\($i.codex)", kind: "review", url: $i.url, at: $i.updated_at}]
                  | .log += [record($i; "keep"; "review bot (Codex summary completed)")]
                else . end
            else . end
        else
          verdict($i) as $v
          | if $v.keep then
              .seen += [$i.key]
              | .retry |= del(.[$i.key])
              | .events += [{key: $i.key, kind: $i.kind, url: $i.url, at: $i.at}]
              | .log += [record($i; "keep"; $v.reason)]
              | if $i.kind == "comment" then
                  .comments[$i.id] = {updated_at: $i.updated_at, codex: $i.codex}
                else . end
            elif $v.settle then
              .seen += [$i.key] | .log += [record($i; "drop"; $v.reason)]
            else
              # owner-check's exit 1 can't tell a stranger from a failed read,
              # so the item is checked again until the retry window ends.
              (.retry[$i.key]) as $first
              | if $first == null then
                  .retry[$i.key] = $now
                  | .log += [record($i; "drop"; "\($v.reason); rechecked for \($retry_window)s")]
                elif $now - $first >= $retry_window then
                  .seen += [$i.key] | .retry |= del(.[$i.key])
                  | .log += [record($i; "drop"; "\($v.reason); settled")]
                else . end
            end
        end)
    # Edits, including of comments posted before the subscription or still
    # being rechecked: Codex's summary reaching a new completed state, or an
    # edit by the owner, whoever wrote the comment. A comment's entry records
    # only its updated_at (and Codex's state), never who owns it.
    | reduce ($items[] | select(.kind == "comment")) as $i (.;
        (.comments[$i.id]) as $c
        | if $i.codex != null then
            if $c != null and $i.codex != $c.codex then
              .comments[$i.id] += {codex: $i.codex, updated_at: $i.updated_at}
              | if ($i.codex | endswith(":completed")) then
                  .events += [{key: "codex:\($i.id):\($i.codex)", kind: "review", url: $i.url, at: $i.updated_at}]
                  | .log += [record($i; "keep"; "review bot (Codex summary completed)")]
                else . end
            else . end
          # The first pass just kept this comment as it now reads: its event
          # covers the edit.
          elif (edited($i) | not) or $i.updated_at == ($c // {}).updated_at then .
          else
            edit($i) as $e
            | if $e == null then retry_edit($i; "edit, editor unread")
              else
                verdict($e) as $v
                | if $v.keep and $v.reason == "owner" then
                    .comments[$i.id] = {updated_at: $i.updated_at}
                    | .events += [{key: "edit:\($i.id):\($i.updated_at)", kind: "edited", url: $i.url, at: $i.updated_at}]
                    | .log += [record($e; "keep"; "owner (edited)")]
                  elif $v.keep or $v.settle then
                    # A bot's edit, or one by the sessions' own login: nothing
                    # to wake for (Codex's summary has its own rule above).
                    .comments[$i.id] = {updated_at: $i.updated_at}
                    | .log += [record($e; "drop"; "edit: \(if $v.keep then "by a bot" else $v.reason end)")]
                  else retry_edit($e; "edit, \($v.reason)") end
              end
          end)
    # The PR's own state: a merge or a close wakes whoever did it.
    | (if $p.merged == true then {key: "state:merged:\($p.merged_at)", kind: "merged", at: ($p.merged_at // "")}
       elif $p.state == "closed" then {key: "state:closed:\($p.closed_at)", kind: "closed", at: ($p.closed_at // "")}
       else null end) as $s
    | if $s != null and ($seenset[$s.key] | not) then
        .seen += [$s.key]
        | if $s.at >= $baseline then
            .events += [$s + {url: ($p.html_url // "")}]
            | .log += [{key: $s.key, actor: "", verdict: "keep", reason: "PR \($s.kind)"}]
          else . end
      else . end
    | {ps: ($ps + {seen: (($seen + .seen) | unique), retry: .retry, comments: .comments,
                   pr_state: (if $p.merged == true then "merged" else ($p.state // "open") end),
                   closed_at: ($s.at // null)}),
       events: .events, log: .log}
  end
