#!/usr/bin/env python3
"""Optional AI CLI. The App owns persistence, LAN, installation and trust decisions."""
import argparse
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request


def main():
    parser=argparse.ArgumentParser(description='管理本机哨兵的 Skill / Hook；无需源码常驻')
    parser.add_argument('--port',type=int,default=8935)
    sub=parser.add_subparsers(dest='action',required=True)
    sub.add_parser('status')
    sub.add_parser('sync')
    for action in ['source','peer']:
        p=sub.add_parser(action); p.add_argument('--file',required=True,help='JSON 清单；- 表示 stdin。peer 清单含配对密钥，请勿入库')
    for action in ['preview','install','pause','rollback','uninstall']:
        p=sub.add_parser(action);p.add_argument('id')
        if action in ['preview','install']: p.add_argument('--source',default='local')
        if action=='install':
            p.add_argument('--digest',required=True,help='先 preview 获得的精确版本')
            p.add_argument('--target',action='append',default=[])
            p.add_argument('--automatic',action='store_true')
            p.add_argument('--approve-hook',action='store_true')
    args=parser.parse_args()
    if args.action in ['source','peer']:
        body=json.load(sys.stdin) if args.file=='-' else json.loads(Path(args.file).read_text())
    else:
        body={k:v for k,v in vars(args).items() if k not in ['action','port','target']}
        if args.action=='install': body['targets']=args.target
    data=None if args.action=='status' else json.dumps(body).encode()
    request=urllib.request.Request(f'http://127.0.0.1:{args.port}/api/ai/{args.action}',data=data,headers={'Content-Type':'application/json','X-Sentinel-Local':'1'})
    try:
        with urllib.request.urlopen(request,timeout=70) as response: result=json.load(response)
    except urllib.error.HTTPError as error:
        result=json.load(error); print(json.dumps(result,ensure_ascii=False));return 1
    except OSError:
        print('本机哨兵不可达；没有通过 SSH 或别的机器权限安装。',file=sys.stderr);return 1
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0


if __name__=='__main__': sys.exit(main())
