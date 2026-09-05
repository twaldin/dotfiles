"""Apply Tim's selected changes to generated copies, never to pinned upstream."""
import re
from pathlib import Path


def adapt(root: Path) -> None:
    matt = root / 'vendor/mattpocock-skills/skills'

    def edit(relative, old, new):
        path = matt / relative
        text = path.read_text()
        if old not in text:
            raise ValueError(f'Upstream text changed: {relative}: {old[:70]}')
        path.write_text(text.replace(old, new))

    grilling = matt / 'productivity/grilling/SKILL.md'
    text = grilling.read_text()
    start = text.index('Work the tree in **rounds**.')
    end = text.index('Finding _facts_ is your job')
    text = text[:start] + (
        "Ask one decision at a time with the harness's native question tool. "
        "Give concise options and your recommendation, then wait for the answer. "
        "Do not treat elapsed time as an answer. Keep working on independent research "
        "while a question is pending. Recompute the remaining decisions after each answer; "
        "do not ask about a decision whose prerequisites are still unresolved.\n\n"
    ) + text[end:]
    text = text.replace("ask the rest of the frontier now", "continue independent research")
    text = text.replace(
        'Do not act on it until the user confirms you have reached a shared understanding.',
        'Check unresolved decisions with the user; existing explicit authorization remains valid.')
    grilling.write_text(text)

    edit('engineering/codebase-design/SKILL.md',
         'Use these terms exactly: don\'t substitute "component," "service," "API," or "boundary." Consistent language is the whole point.',
         "Use this vocabulary to reason about design, while respecting the project's established terms. Explain unfamiliar terms in plain language.")
    path = matt / 'engineering/codebase-design/SKILL.md'
    path.write_text(re.sub(r' _Avoid_: [^\n]+', '', path.read_text()))

    path = matt / 'engineering/improve-codebase-architecture/SKILL.md'
    text = path.read_text().replace(
        'present them as a visual HTML report', 'present concise recommendations')
    text = text.replace(
        'Use these terms exactly in every suggestion, and don\'t drift into "component," "service," "API," or "boundary."',
        "Respect the project's established terminology and explain unfamiliar terms.")
    start = text.index('### 2. Present candidates as an HTML report')
    end = text.index('### 3. Grilling loop')
    text = text[:start] + '''### 2. Present candidates

Give a concise recommendation in conversation: the affected files, concrete problem,
proposed change, expected benefit, and supporting evidence. Identify any existing
decision it would revisit. Use the project's terms. Include a small diagram only when
it clarifies the change; use HTML or an editor when the user requests that format.
Recommend which candidate to explore first. Use the native question tool for the
user's choice before designing interfaces in detail.

''' + text[end:]
    path.write_text(text)

    path = matt / 'engineering/triage/SKILL.md'
    text = path.read_text()
    start = text.index('Every comment or issue posted')
    end = text.index('## Reference docs')
    text = text[:start] + text[end:]
    text = text.replace('- [OUT-OF-SCOPE.md](OUT-OF-SCOPE.md): how the `.out-of-scope/` knowledge base works\n', '')
    text = text.replace(
        "These are canonical role names. The actual label strings used in the issue tracker may differ. The mapping should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.",
        "These describe roles, not new labels to install. Use the project's existing Linear states: Backlog for ideas and Todo for dispatchable work. Use its existing review, blocked, and canceled states for the other outcomes. Inspect the workspace when the mapping is missing; ask only about genuine ambiguity.")
    text = text.replace('Every triaged issue should carry exactly one category role and one state role.',
                        'Use one current workflow state and existing category labels where useful.')
    text = text.replace('read `.out-of-scope/*.md` and surface any that resembles this request.',
                        'search related and canceled Linear issues and surface relevant prior decisions.')
    text = text.replace('Point to where it lives; do **not** write to `.out-of-scope/` (that KB is for *rejected* requests, not built ones).',
                        'Point to where it lives and close with the appropriate existing state.')
    text = text.replace('write to `.out-of-scope/`, link to it from a comment, then close ([OUT-OF-SCOPE.md](OUT-OF-SCOPE.md)).',
                        'record the reason and supporting evidence on the Linear issue, then close it. Keep no separate rejection log.')
    text = text.replace('Confirm what you\'re about to do (role changes, comment, close), then act.',
                        'Act within that authorization without asking for the same approval again.')
    text = text.replace('If moving to `ready-for-agent` without a grilling session, ask whether they want to write an agent brief.',
                        'Reuse the existing brief; identify any missing acceptance criteria before treating work as dispatchable.')
    path.write_text(text)

    edit('engineering/to-spec/SKILL.md',
         'Apply the `ready-for-agent` triage label - no need for additional triage.',
         'Use the project\'s existing workflow state. Only move to Todo when the user has authorized dispatch and the work is executable; a specification alone is not dispatch authorization.')
    edit('engineering/to-tickets/SKILL.md',
         'Apply the `ready-for-agent` triage label unless instructed otherwise; the tickets are agent-grabbable by construction.',
         'Use the project\'s existing states: Backlog while refining and Todo when dispatch is authorized and the acceptance criteria and dependencies are clear.')
    edit('engineering/to-tickets/SKILL.md', '**Status:** ready-for-agent',
         '**Status:** the project\'s existing state; Todo only when dispatch is authorized')
    edit('engineering/to-tickets/SKILL.md',
         '**How** depends on the tracker `/setup-matt-pocock-skills` configured;',
         '**How** depends on the project\'s configured tracker;')
    edit('engineering/code-review/SKILL.md',
         'The issue tracker should have been provided to you. If `docs/agents/issue-tracker.md` is missing, tell the user to run `/setup-matt-pocock-skills`.',
         'Use the project\'s configured tracker and the ticket or PR supplied with the task. Ask only for missing information that cannot be established from those sources.')

    # OMP loads skill bodies through read/skill://; it has no Claude "Skill" tool.
    for path in matt.rglob('*.md'):
        text = path.read_text()
        text = re.sub(r'[Cc]all the Skill tool twice, for "([^"]+)" and "([^"]+)"',
                      r'Load the "\1" and "\2" skills', text)
        text = re.sub(r'[Cc]all the Skill tool with "([^"]+)"', r'Load the "\1" skill', text)
        text = text.replace('call the Skill tool for whichever skills', 'load whichever skills')
        text = text.replace('should call the Skill tool for', 'should load')
        path.write_text(text)
