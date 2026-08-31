---
description: 'Use when asked to adopt, inspect, or clear a ticket-workflow role charter in the current task'
argument-hint: '<planner | epic-coordinator | implementer | none>'
---
Set or clear the current task's role charter: **$ARGUMENTS**

Invoke the `ticket-workflow` skill now. Run only Step 0's active-harness
selection and the selected adapter's `ROLE_STATE` operation; do not run a
ticket phase.

1. Take the first token of `$ARGUMENTS` as the requested value. Valid values are
   `planner`, `epic-coordinator`, `implementer`, and `none`. For an empty or
   invalid value, report those four values plus the current role when
   `ROLE_STATE` can identify one, then stop without changing state.
2. For a role, call `ROLE_STATE(adopt, <role>)`. It must read
   `roles/<role>.md` through `RESOURCES`, adopt the charter as governing for the
   current task/work item, apply the strongest persistence this harness
   supports, and report any persistence or guard limitation.
3. For `none`, call `ROLE_STATE(clear)`. Stop applying the charter and clear
   only the state this harness owns; do not claim to remove a marker or hook
   that the adapter does not provide.
4. Confirm the active harness, resulting role state, what the charter binds,
   and the exact durability/guard guarantees reported by `ROLE_STATE`.

Never implement role persistence here, search for a skill/plugin copy, or fall
back to another harness's state mechanism.
