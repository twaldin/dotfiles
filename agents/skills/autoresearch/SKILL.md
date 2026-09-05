---
name: autoresearch
description: Hillclimb a measurable target within the current session. Use for iterative experiments, benchmark optimization, or requests to keep trying changes and measure what improves.
---

Run experiments in the current conversation using its native tools and context management.

1. Establish the objective, metric command and direction, editable scope, correctness constraints, and stopping condition from the request, ticket, and project. Ask only for consequential missing information. Use the stated time/experiment budget; otherwise state a modest session budget before starting.
2. Work in the assigned repository/worktree. Preserve existing changes and establish a recoverable baseline for your experiment edits. Run the baseline measurement and save its output.
3. Form one hypothesis, make a focused change, run the measurement and applicable correctness checks, and compare with the best verified result. Keep comparison conditions consistent; repeat measurements when noise could explain a claimed improvement.
4. Keep useful improvements that satisfy the constraints. Discard failed trials by reverting only your trial changes. Prefer equal performance with simpler code over added complexity without a meaningful gain.
5. Record each trial's hypothesis, revision or patch identity, measurement, keep/discard/error decision, and evidence location in one small task-local results file. Use outcomes to choose the next experiment; change direction when an approach stops helping.
6. Continue without asking after every trial. Stop at the agreed target or budget, a user interruption, or a blocker that prevents meaningful experiments. This skill starts no daemon, scheduled job, or replacement agent session.
7. Leave the best verified changes and summarize baseline versus best, useful trials, remaining uncertainty, and the results-file location. Follow the project's normal review and commit policy.
