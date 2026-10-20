"""Preview/apply PR Gate and Release using the working Cloud workflow's IDs.

Destination, Xcode, macOS, repository and product come from the existing
workflow. Preview is the default. No build is started by this command.
"""
import argparse
import copy
import json
import os

from appstoreconnect import from_environment


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


def configure(client, source_id, apply=False):
    source = client.request('GET', f'/v1/ciWorkflows/{source_id}?include=product,repository,xcodeVersion,macOsVersion')['data']
    product = source['relationships']['product']['data']['id']
    workflows = client.paginate(f'/v1/ciProducts/{product}/workflows?limit=200')
    result = []
    for release in (False, True):
        attrs = attributes(source, release)
        matching = [workflow for workflow in workflows if workflow['attributes']['name'] == attrs['name']]
        if len(matching) > 1:
            raise RuntimeError(f'Duplicate workflow name: {attrs["name"]}')
        target = matching[0] if matching else None if release else source
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
    args = parser.parse_args()
    result = configure(from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH']), args.source_workflow, args.apply)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print('Release: set the internal TestFlight group in the Xcode Cloud post-action UI. No build was started.')


if __name__ == '__main__':
    main()
