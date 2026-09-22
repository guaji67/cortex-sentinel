#!/usr/bin/env python3
"""Pairing bootstrap only. Output contains a view token: pipe via a trusted channel, never log."""
import argparse
import json
import urllib.request

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--id',required=True)
parser.add_argument('--url',required=True)
parser.add_argument('--port',type=int,default=8935)
args=parser.parse_args()
def read(path):
    with urllib.request.urlopen(f'http://127.0.0.1:{args.port}/api/'+path,timeout=10) as response: return json.load(response)
print(json.dumps({'id':args.id,'url':args.url,'public_key':read('ai/identity')['public_key'],'token':read('settings')['view_key']}))
