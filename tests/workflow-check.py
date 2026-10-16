#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Parsing for tests/workflow-check.sh: reads every *.yml and *.yaml file in a
# directory and reports the jobs that could run a fork's pull request on a
# self-hosted runner. Run as: python3 -I tests/workflow-check.py <dir>
#
# stdout: one "<file>\t<job>\t<reason>" line per finding.
# stderr: "workflow-check: <n> workflows, <m> jobs, <k> findings", or the
# error that stopped the run.
# Exit: 0 no findings, 1 at least one, 2 a file that does not parse or is not
# a workflow (named), or no workflow files at all.
import os
import re
import sys

try:
    import yaml
except ImportError:
    print('workflow-check: needs PyYAML (python3 -c "import yaml" fails); in CI it runs under uv run --with pyyaml', file=sys.stderr)
    sys.exit(2)

FORK_GUARD_PARTS = [
    "github.event_name != 'pull_request'",
    'github.event.pull_request.head.repo.full_name == github.repository',
]
FORK_GUARD = ' || '.join(FORK_GUARD_PARTS)
BASE_CONTEXT_TRIGGERS = ('pull_request_target', 'workflow_run')


class WorkflowError(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    # A repeated key (a second if: or runs-on:) would silently replace the
    # first, so it is an error here.
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f'repeated key {key!r}', key_node.start_mark)
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


def clean(text):
    return re.sub(r'\s+', ' ', str(text)).strip()


def guard_problem(job):
    # None when the job's if: is the fork guard, otherwise why it is not.
    expr = job.get('if')
    if expr is None:
        return 'no fork guard: the job has no if:'
    if not isinstance(expr, str):
        return f'no fork guard: if: is not an expression ({clean(expr)})'
    text = clean(expr)
    wrapped = re.fullmatch(r'\$\{\{(.*)\}\}', text)
    if wrapped:
        text = clean(wrapped.group(1))
    parts = [clean(part) for part in text.split('||')]
    if parts == FORK_GUARD_PARTS:
        return None
    return f'fork guard missing or altered: if: must be "{FORK_GUARD}", found "{text[:160]}"'


def is_self_hosted(runs_on):
    # True when runs-on can select a self-hosted runner, or cannot be known here.
    if isinstance(runs_on, dict):
        if 'group' in runs_on:
            return True
        runs_on = runs_on.get('labels', [])
    if isinstance(runs_on, str):
        runs_on = [runs_on]
    if not isinstance(runs_on, list):
        return False
    for label in runs_on:
        if not isinstance(label, str):
            continue
        text = label.strip().lower()
        if text == 'self-hosted' or '${{' in text:
            return True
    return False


def trigger_names(workflow):
    # PyYAML reads the bare key on: as the boolean True.
    on = workflow[True] if True in workflow else workflow.get('on')
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {clean(item) for item in on}
    if isinstance(on, dict):
        return {clean(key) for key in on}
    return set()


def check_workflow(name, workflow, findings):
    triggers = trigger_names(workflow)
    for job_id, job in workflow['jobs'].items():
        job_name = clean(job_id)
        if not isinstance(job, dict):
            raise WorkflowError(f'{name}: job {job_name} is not a mapping')
        if 'uses' in job:
            # The called workflow's runner is not visible here: it is treated
            # as self-hosted.
            if 'pull_request' in triggers and guard_problem(job):
                findings.append((name, job_name,
                                 'reusable workflow call in a pull_request workflow without the fork guard; its runner is not visible here'))
            for trigger in sorted(triggers.intersection(BASE_CONTEXT_TRIGGERS)):
                findings.append((name, job_name,
                                 f'reusable workflow call in a {trigger} workflow, which runs with the base repository context; its runner is not visible here'))
            continue
        if not is_self_hosted(job.get('runs-on')):
            continue
        problem = guard_problem(job)
        if problem:
            findings.append((name, job_name, problem))
        for trigger in sorted(triggers.intersection(BASE_CONTEXT_TRIGGERS)):
            findings.append((name, job_name,
                             f'self-hosted job in a {trigger} workflow, which runs with the base repository context'))


def load(path, name):
    try:
        with open(path, encoding='utf-8') as handle:
            workflow = yaml.load(handle, Loader=UniqueKeyLoader)
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as err:
        raise WorkflowError(f'cannot parse {name}: {clean(err)}')
    if not isinstance(workflow, dict) or not isinstance(workflow.get('jobs'), dict):
        raise WorkflowError(f'{name} is not a workflow: it has no jobs mapping')
    return workflow


def main(argv):
    if len(argv) != 2:
        print('usage: python3 -I tests/workflow-check.py <workflows dir>', file=sys.stderr)
        return 2
    directory = argv[1]
    try:
        names = sorted(name for name in os.listdir(directory)
                       if name.endswith(('.yml', '.yaml'))
                       and os.path.isfile(os.path.join(directory, name)))
    except OSError as err:
        print(f'workflow-check: cannot read {directory}: {clean(err)}', file=sys.stderr)
        return 2
    if not names:
        print(f'workflow-check: no *.yml or *.yaml files in {directory}', file=sys.stderr)
        return 2
    findings = []
    jobs = 0
    try:
        for name in names:
            workflow = load(os.path.join(directory, name), name)
            jobs += len(workflow['jobs'])
            check_workflow(name, workflow, findings)
    except WorkflowError as err:
        print(f'workflow-check: {err}', file=sys.stderr)
        return 2
    for name, job_name, reason in findings:
        print(f'{clean(name)}\t{job_name}\t{reason}')
    print(f'workflow-check: {len(names)} workflows, {jobs} jobs, {len(findings)} findings', file=sys.stderr)
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
