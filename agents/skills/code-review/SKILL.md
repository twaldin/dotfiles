---
name: code-review
description: Review changes against their spec and repository standards using independent reviewers from a different model family than the author. Use for a requested code review or a project's required review step.
---

Read the [upstream review procedure](../../vendor/mattpocock-skills/skills/engineering/code-review/SKILL.md) and follow its separate Standards and Spec reviews, with these adaptations:

- Use the project's configured tracker and documentation locations. Resolve the review scope and source issue from the request, PR, or ticket before asking for missing information.
- Pick the reviewer by the authors' model family. Changing size, version or reasoning effort within a family doesn't make it another family. A project's own reviewer policy takes precedence.
  - Anthropic authors → the `reviewer` agent (omp's `review` role, GPT-6 Astra).
  - OpenAI authors → the `opus` agent.
  - Both families → `reviewer`, plus a `grok` pass when the change is consequential.
  - A small, low-risk diff may use `grok` alone. Never make Grok the only reviewer of security, concurrency, migrations or cross-cutting design.
  - Without omp, choose another available family and harness.
- Run the Standards and Spec reviewers in separate contexts. They may use the same reviewer model; both must differ from all authors' families. Keep the upstream rubric and separate reports.
- Give reviewers the exact changes under review, including uncommitted changes when those are in scope, and read-only access to the relevant repository and evidence. Keep author summaries distinct from primary evidence.
- After corrections, have the independent reviewers check the changes since their last reviewed revision. Include the final corrections before reporting the final head as reviewed; prior clean reports cover only the changes they inspected.
- Verify the actual reviewer model in launch/session metadata; named agents can inherit the author's model despite a different default task role. Record the verified author/reviewer models and families, harness, and reviewed revision or diff snapshot. Count the review only after confirming different families; otherwise report it incomplete.
- Use the current harness's native question and delegation tools. A failure or skipped review is reported explicitly; it does not count as a passed check.

The current session receives the findings and makes any fixes. Review requires no ticket system. The request and project determine when review is required and what happens next; record detailed review evidence locally and summarize relevant findings for the human.
