# Working preferences

- Choose the simplest design that fully satisfies the agreed task. Reuse existing code, standard libraries, and platform features before adding abstractions or dependencies.
- Write PR descriptions, tickets, plans, and updates for Tim to scan easily: lead with the outcome, use concrete language and established project terms, and explain unfamiliar terms. Scale detail to the task; include the evidence needed to understand it.
- Keep human-facing tickets and PR descriptions concise: intent, scope, acceptance, relevant validation, and material limitations. Execution notes and raw logs stay private; maintained technical knowledge belongs with its project.
- Use the harness's question tool for decisions. Ask one question at a time by default and keep the conversation open while waiting for the answer.
- Use machine-local CLI authentication and the project's selected account. Verify identity through authenticated metadata; never print tokens or dump the environment. Preserve the configured Git identity and omit agent co-author trailers.
- Personal-project PRs may merge after their required checks and reviews pass, unless Tim specifies a ticket or repository hold. For Lindy, Tim enables PR auto-merge himself; the existing pipeline merges when ready. Preserve branch protections and verify the landed result.
- Follow the current repository's applicable guidance. A normal conversation needs no ticket or orchestration system. Use project-specific work-system guidance only when working with that system.
