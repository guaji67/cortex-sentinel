"""哨兵专用 PR 合入，GitHub 检查与分支头均须保持一致。"""
import argparse
import json
import re
import subprocess

REPO = 'guaji67/cortex-sentinel'


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('命令未成功：' + ' '.join(args[:3]))
    return result.stdout.strip()


def checked_pr(row, number, head):
    if row.get('number') != number or row.get('baseRefName') != 'main':
        raise ValueError('PR 或目标分支不一致')
    if row.get('headRepositoryOwner', {}).get('login') != 'guaji67':
        raise ValueError('不合外部仓分支')
    if row.get('headRefOid') != head:
        raise ValueError('分支头已变，先重新验证')
    if row.get('state') != 'OPEN' or row.get('isDraft'):
        raise ValueError('PR 未开放或仍是草稿')
    if row.get('mergeable') != 'MERGEABLE' or row.get('mergeStateStatus') not in ['CLEAN', 'UNSTABLE']:
        raise ValueError('PR 不能干净合入，先更新基线或解决冲突')
    checks = row.get('statusCheckRollup')
    if not isinstance(checks, list):
        raise ValueError('检查结果没读到')
    for check in checks:
        if check.get('status') == 'COMPLETED' and check.get('conclusion') == 'SUCCESS':
            continue
        if check.get('state') == 'SUCCESS':
            continue
        raise ValueError('检查未通过：' + str(check.get('name') or check.get('context') or '未知检查'))
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('pr', type=int)
    parser.add_argument('--head', required=True, help='本轮实际验证过的完整 SHA')
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.head):
        raise ValueError('需要完整的已验证 SHA')
    origin = command('git', 'remote', 'get-url', 'origin')
    if origin not in ['git@github.com:guaji67/cortex-sentinel.git', 'https://github.com/guaji67/cortex-sentinel.git']:
        raise ValueError('只合当前哨兵 origin，不改远端')
    fields = 'number,state,isDraft,baseRefName,baseRefOid,headRefOid,headRepositoryOwner,mergeable,mergeStateStatus,statusCheckRollup'
    def read():
        return json.loads(command('gh', 'pr', 'view', str(args.pr), '--repo', REPO, '--json', fields))
    row = read()
    checks = checked_pr(row, args.pr, args.head)
    branch = json.loads(command('gh', 'api', f'repos/{REPO}/branches/main'))
    if branch['commit']['sha'] != row['baseRefOid']:
        raise ValueError('主线已变，重读后再核')
    # 本仓现有主线未设必检；保护开启后不能把空检查当通过。
    if branch.get('protected') and not checks:
        raise ValueError('受保护主线的检查为空')
    fresh = read()
    checked_pr(fresh, args.pr, args.head)
    if fresh['baseRefOid'] != row['baseRefOid']:
        raise ValueError('核验期间主线已变')
    if args.check_only:
        print('合入核验通过，未合并')
        return
    command('gh', 'pr', 'merge', str(args.pr), '--repo', REPO, '--squash', '--match-head-commit', args.head)
    result = json.loads(command('gh', 'pr', 'view', str(args.pr), '--repo', REPO, '--json', 'state,mergeCommit,url'))
    if result.get('state') != 'MERGED' or not result.get('mergeCommit', {}).get('oid'):
        raise ValueError('GitHub 未确认合入')
    command('git', 'fetch', 'origin', 'main')
    command('git', 'merge-base', '--is-ancestor', result['mergeCommit']['oid'], 'origin/main')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
