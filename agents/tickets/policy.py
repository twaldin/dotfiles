"""Workspace conventions translate inputs and publications; owners keep their identity."""


def workflow(config, repo=None, team=None):
    value = {
        'start_states': [],
        'defer_types': ['backlog', 'triage'],
        'cancel_types': ['canceled', 'duplicate'],
        'excluded_labels': [],
        'states': {},
        'attention_labels': [],
    }
    # A supplied states map replaces the defaults, including an empty publication map.
    for override in [config.get('workflow', {}),
                     config.get('teams', {}).get(team, {}).get('workflow', {}),
                     config.get('repos', {}).get(repo, {}).get('workflow', {})]:
        value.update(override)
    return value


def matches(state, choices):
    return state.get('id') in choices or state.get('name') in choices


def starts(issue, config, repo=None):
    return matches(issue['state'], workflow(config, repo, issue['team']['id'])['start_states'])


def deferred(issue, config, repo=None):
    value = workflow(config, repo, issue['team']['id'])
    return (issue['state'].get('type') in value['defer_types'] + value['cancel_types']
            or matches(issue['state'], value.get('defer_states', []) + value.get('cancel_states', [])))


def state_id(config, team, stage, repo=None):
    selected = workflow(config, repo, team)['states'].get(stage)
    if not selected:
        return None
    available = config.get('teams', {}).get(team, {}).get('states', {})
    # State UUIDs or maintained display-name mappings are both supported.
    if selected in available:
        return available[selected]
    if selected in available.values():
        return selected
    return None


def route(issue, config, explicit=None):
    if explicit:
        if explicit not in config['repos']:
            raise ValueError('The recorded repository is not registered on this host')
        return explicit
    routes = config.get('routes', {})
    labels = issue.get('labels', {}).get('nodes', [])
    mapped = {routes.get('labels', {}).get(label['id']) for label in labels}
    mapped.discard(None)
    prefix = routes.get('label_prefix')
    if prefix:
        mapped.update(label['name'][len(prefix):] for label in labels if label['name'].startswith(prefix))
    if len(mapped) > 1:
        return None  # No known route yet; a conversation can record one directly.
    selected = next(iter(mapped), None)
    selected = selected or routes.get('teams', {}).get(issue['team']['id'])
    project = (issue.get('project') or {}).get('id')
    selected = selected or routes.get('projects', config.get('projects', {})).get(project)
    selected = selected or config.get('default_repo')
    if selected and selected not in config['repos']:
        raise ValueError('Repository is not configured on this dispatcher')
    return selected
