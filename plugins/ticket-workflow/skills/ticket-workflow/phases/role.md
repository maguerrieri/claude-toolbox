# ROLE mini-phase (`/role`)

Manage the role in the current task without running a ticket phase:

1. Select and read the active harness adapter exactly as Step 0 specifies,
   then use its `RESOURCES` operation; do not select a child launch harness.
2. Take the first argument as `planner`, `epic-coordinator`, `implementer`, or
   `none`. Empty or invalid input reports those values and the current role
   when `ROLE_STATE` can identify one, then stops without changing state.
3. For a role, call `ROLE_STATE(adopt, <role>)`. It reads
   `roles/<role>.md` through `RESOURCES`, adopts the charter as governing this
   task/work item, applies the strongest persistence the active harness
   supports, and reports its exact persistence and guard limitations.
4. For `none`, call `ROLE_STATE(clear)`. Stop applying the charter and clear
   only state owned by this harness. Confirm the active harness, resulting
   role, charter bounds, and exact durability/guard guarantees.

Do not implement persistence in a command wrapper, search for another skill or
plugin copy, or fall back to a different harness's state mechanism.
