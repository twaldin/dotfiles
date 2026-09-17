# Conversations and tickets

Read the workspace's configured authoring reference and repository profile. Inspect existing tickets, PRs, ownership and current source before creating or scoping work. Use the native question tool for decisions you cannot establish from that context.

The internal brief is the maintained scope, decisions, constraints and acceptance. Linear presents that agreement concisely and holds durable human questions/answers. Detailed investigations and logs stay private. A Linear edit is new input for the owner to reconcile; it does not replace a saved worker or silently change its repository.

Create one executable ticket per repository, linking tickets for a cross-repository effort. Assign it to the configured user. Select teams, efforts and required labels according to this workspace's rules. Personal policy may create/use a repository label; Lindy may require unrelated conventions such as an on-call label. Infer neither from generic engine rules.

Record a known route with `omp-tickets register <issue> --repo <key>`. A conversation in a registered repository can supply that route directly. This does not dispatch work. Keep ideas deferred; the configured intake state requests an owner. Initially this is Todo in both deployments. Thin tickets may get brief owner investigation, then a question and a wait; authorship by a teammate or agent is not an authorization class.

For a conversation-created scoped ticket, prepare its public scope and private brief before requesting intake. Create it in the workspace's deferred state, register the known repository, save the brief with `refine`, then move it to the configured start state when ready. A human-created ticket can instead arrive through configured label/team/default routing; the owner investigates its supplied context.

After requesting intake, inspect `omp-tickets show <issue>` and live progress. Report started only when a native owner/session exists; Todo, registration or a PR label alone is not proof. If no owner starts, check assignment, configured start state, repository route, explicit hold/dependencies, pilot admission, capacity and preparation errors. Preserve the existing record when correcting these inputs. An active pilot allowlist needs deliberate admission under the rollout policy; do not silently broaden it or create a second owner to bypass it.

For an existing ticket:

- Read `omp-tickets show <issue>`, current Linear discussion and deliverables.
- Owner questions are listed by `omp-tickets attention`; relay them to Tim in chat. Deliver his answer with `refine` (private brief) or, when it is a team-facing decision, as his Linear comment; either wakes the existing owner. Resolve a question through the actual discussion, not a comment prefix or shared account identity.
- When scope changes, save the updated internal brief to a local text file and run `omp-tickets refine <issue> --input <file>`. Keep the concise Linear description consistent with the agreement. This wakes the same owner.
- For an explicit pause, use `omp-tickets hold <issue> --reason '<reason>'` and record the human explanation on Linear. It stops the current turn/helpers and preserves work. `release <issue>` resumes the same owner; a brief edit alone does not release a hold. Configured deferred/start states provide the workspace's Linear control surface too.

Tim coordinates competing conversations. Reread current context and preserve others' changes; do not add semantic conflict arbitration or revision approval rituals.

A finding can be the right deliverable. Preserve useful project knowledge and unrelated work; a docs audit with no justified edit needs no cosmetic PR. Put reusable pipeline rules in the profile, and ticket-specific overrides in its brief and human agreement.
