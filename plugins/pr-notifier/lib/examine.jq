# examine.jq: one PR's issue timeline and state, turned into wake events.
#
# bin/pr-notifier runs it twice per examined PR, with --arg phase:
#   need    prints the logins (one per line) whose owner-check result the
#           filter needs: new items, at or after the baseline, by an actor
#           that is neither the sessions' own login nor a configured bot
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
  | [ $all[] | select(type == "object") as $e
    | if $e.event == "commented" then
        {key: "comment:\($e.id)", kind: "comment", actor: ($e.user.login // ""),
         type: ($e.user.type // ""), url: ($e.html_url // ""), at: ($e.created_at // ""),
         id: ($e.id | tostring), updated_at: ($e.updated_at // $e.created_at // ""),
         codex: ($e | codex_state)}
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

def verdict($i):
  class($i) as $c
  | if $c == "own" then {keep: false, reason: "own login", settle: true}
    elif $c == "unknown" then {keep: false, reason: "no actor", settle: true}
    elif $c == "other-bot" then {keep: false, reason: "a bot or app not configured", settle: true}
    elif $c == "bot" then {keep: true, reason: "review bot"}
    else ($owners[$i.actor | lc]) as $o
      | if $o == 0 then {keep: true, reason: "owner"}
        elif $o == 3 then {keep: false, reason: "same-account login (owner-check 3)", settle: true}
        else {keep: false, reason: "not the owner (owner-check \($o // "not run"))", settle: false} end
    end;

def record($i; $verdict; $reason):
  {key: $i.key, actor: ($i.actor // ""), verdict: $verdict, reason: $reason};

($psf[0] // {}) as $ps
| ($ps.seen // []) as $seen
| ($seen | map({(.): true}) | add // {}) as $seenset
| items as $items
| [ $items[] | select($seenset[.key] | not) ] as $new
| ($ps.comments // {}) as $tracked
# A new item at or after the baseline: the first pass below decides it.
| def fresh($i): ($seenset[$i.key] | not) and $i.at >= $baseline;
# A comment's updated_at as last recorded. One with no entry was last seen
# unedited, so its creation time stands in.
  def prev_updated($i): (($tracked[$i.id] // {}).updated_at) // $i.at;
# An edit after the baseline of a comment the first pass doesn't decide. Each
# edit gets its own owner check, the same cached one a new item gets: no
# comment pins its author's ownership, so a revoked admin stops waking
# sessions once the cache expires, and a failed read never sticks.
  def edit_candidate($i):
    $i.kind == "comment" and $i.codex == null and class($i) == "check" and (fresh($i) | not)
    and $i.updated_at >= $baseline and $i.updated_at != prev_updated($i);
  if $phase == "need" then
    [ ($new[] | select(.at >= $baseline) | select(class(.) == "check") | .actor),
      ($items[] | select(edit_candidate(.)) | .actor) ]
    | unique_by(lc) | .[]
  else
    ($pr[0] // {}) as $p
    | reduce $new[] as $i (
        {seen: [], retry: ($ps.retry // {}), comments: ($ps.comments // {}), events: [], log: []};
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
    # Edits of comments the first pass didn't decide, including ones posted
    # before the subscription: Codex's summary reaching a new completed state,
    # or an edit after the baseline that the owner check (edit_candidate)
    # says is the owner's. An edit is decided like a new item, and the entry
    # records only the comment's updated_at (and Codex's state), never who
    # owns it.
    | reduce ($items[] | select(.kind == "comment") | select(fresh(.) | not)) as $i (.;
        (.comments[$i.id]) as $c
        | ($tracked[$i.id] // {}) as $old
        | if $i.codex != null then
            if $c != null and $i.codex != $c.codex then
              .comments[$i.id] += {codex: $i.codex, updated_at: $i.updated_at}
              | if ($i.codex | endswith(":completed")) then
                  .events += [{key: "codex:\($i.id):\($i.codex)", kind: "review", url: $i.url, at: $i.updated_at}]
                  | .log += [record($i; "keep"; "review bot (Codex summary completed)")]
                else . end
            else . end
          elif edit_candidate($i) | not then .
          else
            ($owners[$i.actor | lc]) as $o
            | if $o == 0 then
                .comments[$i.id] = {updated_at: $i.updated_at}
                | .events += [{key: "edit:\($i.id):\($i.updated_at)", kind: "edited", url: $i.url, at: $i.updated_at}]
                | .log += [record($i; "keep"; "owner (edited)")]
              elif $o == 3 then
                .comments[$i.id] = {updated_at: $i.updated_at}
                | .log += [record($i; "drop"; "edit by a same-account login (owner-check 3)")]
              elif $old.edit_retry == null then
                # As for a new item: a failed read is retried, so the recorded
                # updated_at stays put and the edit is seen again.
                .comments[$i.id] = {updated_at: prev_updated($i), edit_retry: $now}
                | .log += [record($i; "drop"; "edit, not the owner (owner-check \($o // "not run")); rechecked for \($retry_window)s")]
              elif $now - $old.edit_retry >= $retry_window then
                .comments[$i.id] = {updated_at: $i.updated_at}
                | .log += [record($i; "drop"; "edit, not the owner (owner-check \($o // "not run")); settled")]
              else . end
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
