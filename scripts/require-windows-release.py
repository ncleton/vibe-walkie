#!/usr/bin/env python3
"""Hold Mac publication until the matching signed Windows release succeeds."""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from urllib.request import urlopen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    repository = os.environ['GITHUB_REPOSITORY']
    commit = os.environ['GITHUB_SHA']
    tag = os.environ['GITHUB_REF_NAME']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Require a repository and the same three-part version tag for Mac and Windows.')
    deadline = time.monotonic() + args.timeout
    print(f'Waiting for the trusted Windows release of {tag} from {commit}.', flush=True)
    while True:
        result = subprocess.run([
            'gh', 'run', 'list', '--repo', repository, '--workflow', 'release-windows.yml',
            '--commit', commit, '--event', 'push', '--limit', '20',
            '--json', 'status,conclusion,databaseId'
        ], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError('Cannot inspect the Windows signing workflow. Check that release-windows.yml is on the default branch and the token has actions:read. ' + result.stderr.strip())
        runs = json.loads(result.stdout)
        if runs and runs[0]['status'] == 'completed':
            if runs[0]['conclusion'] != 'success':
                raise RuntimeError(f"Windows release run {runs[0]['databaseId']} failed ({runs[0]['conclusion']}). Repair and rerun Windows before publishing Mac.")
            break
        if time.monotonic() >= deadline:
            raise TimeoutError('The matching signed Windows release has not completed. Inspect release-windows.yml and rerun this Mac release after Windows succeeds.')
        time.sleep(min(10, max(0, deadline - time.monotonic())))
    # This public evidence is written only after signing and is served with the
    # exact MSIX. The successful workflow also verifies the served MSIX/feed.
    url = f'https://github.com/{repository}/releases/download/{tag}/windows-release-evidence.json'
    with urlopen(url, timeout=30) as response:
        evidence = json.load(response)
    if (evidence.get('signed') is not True or evidence.get('version') != tag[1:]
            or evidence.get('commit') != commit
            or not re.fullmatch(r'[0-9a-f]{64}', evidence.get('sha256', ''))):
        raise RuntimeError('The public Windows release evidence does not match the signed version and source commit. Mac publication is blocked.')
    print(f'Windows {tag} is signed, published and verified from the same commit. Mac publication may proceed.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Mac/Windows joint release failed: {error}', file=sys.stderr)
        sys.exit(1)
