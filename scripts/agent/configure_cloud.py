"""Preview/apply PR Gate, PR Gate Single Machine and Release using the working Cloud workflow's IDs.

Destination, Xcode, macOS, repository and product come from the existing
workflow. Preview is the default. No build is started by this command.

PR Gate Single Machine has one BUILD action for the Simulator: its build
machine runs the gate's tests itself (ci_scripts/ci_pre_xcodebuild.sh), so
nothing is handed to a test machine. gate-config.json selects it with
xcodeCloudPrGateMode = build-machine.
"""
import argparse
import copy
import json
import os

from appstoreconnect import from_environment


SINGLE_MACHINE = 'PR Gate Single Machine'


def single_machine_attributes():
    return {'name': SINGLE_MACHINE, 'description': 'Struis verification and delivery policy (tests on the build machine)',
            'containerFilePath': 'strius.xcodeproj', 'isEnabled': True, 'clean': False,
            'branchStartCondition': None, 'tagStartCondition': None, 'pullRequestStartCondition': None,
            'scheduledStartCondition': None, 'manualPullRequestStartCondition': None, 'manualTagStartCondition': None,
            'manualBranchStartCondition': {'source': {'isAllMatch': True}},
            'actions': [{'name': 'Ready HEAD tests on the build machine', 'actionType': 'BUILD', 'scheme': 'StruisPRGate',
                         'destination': 'ANY_IOS_SIMULATOR', 'platform': 'IOS', 'isRequiredToPass': True}]}


def attributes(source, release=False):
    test = next((copy.deepcopy(action) for action in source['attributes']['actions']
                 if action.get('actionType') == 'TEST'), None)
    if not test:
        raise RuntimeError('The source workflow needs an existing Simulator TEST destination')
    test.update(name='All UI and unit tests' if release else 'Ready HEAD tests',
                scheme='StruisRelease' if release else 'StruisPRGate', isRequiredToPass=True)
    configuration = test.setdefault('testConfiguration', {})
    configuration.update(kind='USE_SCHEME_SETTINGS')
    configuration.pop('testPlanName', None)
    result = {'name': 'Release' if release else 'PR Gate', 'description': 'Struis verification and delivery policy',
              'containerFilePath': 'strius.xcodeproj', 'isEnabled': True, 'clean': False,
              'branchStartCondition': None, 'tagStartCondition': None, 'pullRequestStartCondition': None,
              'scheduledStartCondition': None, 'manualPullRequestStartCondition': None, 'manualTagStartCondition': None,
              'manualBranchStartCondition': {'source': {'isAllMatch': True}},
              'actions': [test]}
    if release:
        result['actions'].append({'name': 'Internal TestFlight archive', 'actionType': 'ARCHIVE', 'scheme': 'StruisRelease',
                                  'destination': 'ANY_IOS_DEVICE', 'platform': 'IOS',
                                  'buildDistributionAudience': 'INTERNAL_ONLY', 'isRequiredToPass': True})
    return result


KINDS = ('pr', 'single', 'release')


def configure(client, source_id, apply=False, only=KINDS):
    source = client.request('GET', f'/v1/ciWorkflows/{source_id}?include=product,repository,xcodeVersion,macOsVersion')['data']
    product = source['relationships']['product']['data']['id']
    workflows = client.paginate(f'/v1/ciProducts/{product}/workflows?limit=200')
    result = []
    for kind in (kind for kind in KINDS if kind in only):
        attrs = single_machine_attributes() if kind == 'single' else attributes(source, kind == 'release')
        matching = [workflow for workflow in workflows if workflow['attributes']['name'] == attrs['name']]
        if len(matching) > 1:
            raise RuntimeError(f'Duplicate workflow name: {attrs["name"]}')
        target = matching[0] if matching else source if kind == 'pr' else None
        if target:
            path, method = f'/v1/ciWorkflows/{target["id"]}', 'PATCH'
            body = {'data': {'type': 'ciWorkflows', 'id': target['id'], 'attributes': attrs}}
        else:
            path, method = '/v1/ciWorkflows', 'POST'
            relationships = {name: {'data': source['relationships'][name]['data']}
                             for name in ('product', 'repository', 'xcodeVersion', 'macOsVersion')}
            body = {'data': {'type': 'ciWorkflows', 'attributes': attrs, 'relationships': relationships}}
        entry = {'method': method, 'path': path, 'body': body}
        if apply:
            entry['workflowId'] = client.request(method, path, body)['data']['id']
        result.append(entry)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-workflow', required=True)
    parser.add_argument('--apply', action='store_true')
    # Apply only what changes: re-applying Release would replace its actions and the post-action set in the UI.
    parser.add_argument('--only', choices=KINDS, action='append')
    args = parser.parse_args()
    result = configure(from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH']), args.source_workflow, args.apply,
                       tuple(args.only or KINDS))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print('Release: set the internal TestFlight group in the Xcode Cloud post-action UI. No build was started.')


if __name__ == '__main__':
    main()
