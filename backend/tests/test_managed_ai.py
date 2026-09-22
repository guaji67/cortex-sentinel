"""Native package management integration; only isolated homes and synthetic hooks."""
import base64
import json
import http.server
import threading
import time
from pathlib import Path
import subprocess
import uuid
import unittest

from test_workbench_native import NativeWorkbench, BINARY


class ManagedAI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        NativeWorkbench.setUpClass()
        cls.server = NativeWorkbench()
        cls.root = NativeWorkbench.root
        cls.home = cls.root / 'ai-test-home'
        (cls.home / '.claude').mkdir(parents=True)
        (cls.home / '.codex').mkdir(parents=True)

    @classmethod
    def tearDownClass(cls):
        NativeWorkbench.tearDownClass()

    def req(self, endpoint, body=None, **kwargs):
        return self.server.request('/api/ai/' + endpoint, body, headers={'X-Sentinel-Local': '1'}, **kwargs)

    def source(self, kind='skill'):
        name='fixture-'+uuid.uuid4().hex
        root=self.root / name
        root.mkdir()
        body={'id':name,'title':'合成规则','root':str(root),'kind':kind,'files':['SKILL.md']}
        (root/'SKILL.md').write_text('---\nname: '+name+'\ndescription: Synthetic test only\n---\n自由研究内容\n')
        if kind=='hook':
            (root/'entry.sh').write_text('printf \'%s\\n\' \'{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"synthetic"}}\'\n')
            body.update(files=['entry.sh'],hook={'event':'SessionStart','entry':'entry.sh','interpreter':'/bin/sh','matcher':''})
        code,value=self.req('source',body)
        self.assertEqual(code,200,value)
        return name,root,body

    def install(self, name, **kwargs):
        code,preview=self.req('preview',{'id':name})
        self.assertEqual(code,200,preview)
        body={'id':name,'digest':preview['digest'],'targets':['claude','codex'],**kwargs}
        return self.req('install',body)

    def test_skill_install_update_rollback_and_pause(self):
        name,root,_=self.source()
        code,value=self.install(name,automatic=True)
        self.assertEqual(code,200,value)
        original=value['digest']
        target=self.home/'.claude/skills'/name/'SKILL.md'
        self.assertEqual(target.read_text(),(root/'SKILL.md').read_text())
        with (root/'SKILL.md').open('a') as out: out.write('v2 自由扩展\n')
        self.assertEqual(self.req('sync',{})[0],200)
        self.assertIn('v2',target.read_text())
        code,receipt=self.req('rollback',{'id':name})
        self.assertEqual(code,200,receipt)
        self.assertEqual(receipt['digest'],original)
        self.assertNotIn('v2',target.read_text())
        self.req('sync',{})
        self.assertNotIn('v2',target.read_text())

    def test_local_customization_is_not_overwritten(self):
        name,root,_=self.source()
        self.assertEqual(self.install(name)[0],200)
        target=self.home/'.claude/skills'/name/'SKILL.md'
        target.write_text('my local changes')
        self.assertEqual(self.install(name)[0],409)
        self.assertEqual(target.read_text(),'my local changes')

    def test_existing_unowned_skill_conflicts(self):
        name,_,_=self.source()
        target=self.home/'.claude/skills'/name
        target.mkdir(parents=True)
        (target/'SKILL.md').write_text('user owned')
        self.assertEqual(self.install(name)[0],409)
        self.assertEqual((target/'SKILL.md').read_text(),'user owned')

    def test_path_and_symlink_rejected(self):
        name,root,body=self.source()
        for path in ['../escape','/absolute','.env','settings.json','credentials.json']:
            body['files']=[path]
            self.assertEqual(self.req('source',body)[0],400)
        (root/'linked.md').symlink_to(root/'SKILL.md')
        body['files']=['SKILL.md','linked.md']
        self.assertEqual(self.req('source',body)[0],400)

    def test_preview_revision_race(self):
        name,root,_=self.source()
        _,preview=self.req('preview',{'id':name})
        with (root/'SKILL.md').open('a') as out: out.write('changed after preview')
        self.assertEqual(self.req('install',{'id':name,'digest':preview['digest'],'targets':['claude']})[0],409)

    def test_browser_key_cannot_install_remotely(self):
        name,_,_=self.source()
        code,value=self.req('source',{},remote=True,key=NativeWorkbench.view_key,actor=None)
        self.assertEqual(code,403,value)
        self.assertEqual(self.req('catalog',remote=True,key=NativeWorkbench.view_key,actor=None)[0],200)

    def test_hook_requires_approval_preserves_settings_and_has_test_receipt(self):
        name,_,_=self.source('hook')
        settings=self.home/'.claude/settings.json'
        original={'env':{'SYNTHETIC':'preserve'},'disableAllHooks':True,'hooks':{'PreToolUse':[{'matcher':'Bash','hooks':[{'type':'command','command':'synthetic-existing'}]}]}}
        settings.write_text(json.dumps(original))
        self.assertEqual(self.install(name)[0],409)
        code,value=self.install(name,approve_hook=True)
        self.assertEqual(code,200,value)
        current=json.loads(settings.read_text())
        self.assertEqual(current['hooks']['PreToolUse'],original['hooks']['PreToolUse'])
        self.assertTrue(current['disableAllHooks'])
        self.assertEqual(current['env'],original['env'])
        result=subprocess.run([str(BINARY),'--managed-hook',str(self.root/'ai'),name,value['digest'],'--test'],input=b'{"hook_event_name":"SessionStart","transcript_path":"never-store-this"}',capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('synthetic',result.stdout.decode())
        receipt=json.loads((self.root/'ai/invocations'/f'{name}.json').read_text())
        self.assertTrue(receipt['test'])
        self.assertNotIn('transcript',json.dumps(receipt))
        self.assertNotIn('never-store-this',json.dumps(receipt))
        self.assertEqual(self.req('uninstall',{'id':name})[0],200)
        after=json.loads(settings.read_text())
        self.assertEqual(after['hooks']['PreToolUse'],original['hooks']['PreToolUse'])
        self.assertEqual(after['hooks']['SessionStart'],[])
        self.assertTrue(after['disableAllHooks'])

    def test_peer_public_key_cannot_be_replaced(self):
        _,identity=self.req('identity')
        peer={'id':'fixture-peer','url':f'http://127.0.0.1:{NativeWorkbench.port}','token':NativeWorkbench.view_key,'public_key':identity['public_key']}
        self.assertEqual(self.req('peer',peer)[0],200)
        self.assertEqual(self.req('sync',{})[0],200)
        peer['public_key']=base64.b64encode(b'x'*32).decode()
        self.assertEqual(self.req('peer',peer)[0],409)
        _,state=self.req('status')
        self.assertNotIn(NativeWorkbench.view_key,json.dumps(state))

    def test_two_nodes_lan_install_update_and_offline_cache(self):
        class Other(NativeWorkbench): pass
        Other.setUpClass()
        try:
            peer=Other()
            identity=peer.request('/api/ai/identity')[1]
            name,root,_=self.source()
            local_identity=self.req('identity')[1]
            config={'id':'source-node','url':f'http://127.0.0.1:{NativeWorkbench.port}','token':NativeWorkbench.view_key,'public_key':local_identity['public_key']}
            request=lambda path,body=None: peer.request('/api/ai/'+path,body,headers={'X-Sentinel-Local':'1'})
            (Other.root/'ai-test-home/.claude').mkdir(parents=True)
            self.assertEqual(request('peer',config)[0],200)
            code,preview=request('preview',{'id':name,'source':'source-node'})
            self.assertEqual(code,200,preview)
            install={'id':name,'source':'source-node','digest':preview['digest'],'targets':['claude'],'automatic':True}
            code,value=request('install',install)
            self.assertEqual(code,200,value)
            target=Other.root/'ai-test-home/.claude/skills'/name/'SKILL.md'
            self.assertEqual(target.read_text(),(root/'SKILL.md').read_text())
            with (root/'SKILL.md').open('a') as out: out.write('LAN second version')
            self.assertEqual(request('sync',{})[0],200)
            self.assertIn('LAN second version',target.read_text())
            config['url']='http://127.0.0.1:1'
            request('peer',config)
            self.assertEqual(request('sync',{})[0],200)
            self.assertIn('LAN second version',target.read_text())
            state=request('status')[1]
            self.assertTrue(state['peers'][0]['error'])
            self.assertTrue(state['peers'][0]['last_success'])
        finally: Other.tearDownClass()

    def test_tampered_signed_package_is_rejected(self):
        name,_,_=self.source()
        envelope=self.req('package/'+name)[1]
        wrapper=json.loads(base64.b64decode(envelope['payload']))
        wrapper['body']['files']['SKILL.md']=base64.b64encode(b'altered').decode()
        envelope['payload']=base64.b64encode(json.dumps(wrapper).encode()).decode()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                raw=json.dumps(envelope).encode();self.send_response(200);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            self.req('peer',{'id':'tampered','url':f'http://127.0.0.1:{server.server_port}','token':'synthetic','public_key':envelope['public_key']})
            code,value=self.req('preview',{'id':name,'source':'tampered'})
            self.assertEqual(code,409,value)
        finally: server.shutdown();server.server_close();thread.join()

    def test_hook_update_does_not_self_approve(self):
        name,root,_=self.source('hook')
        self.assertEqual(self.install(name,approve_hook=True,automatic=True)[0],200)
        settings=self.home/'.claude/settings.json';before=settings.read_bytes()
        with (root/'entry.sh').open('a') as out: out.write('# v2\n')
        self.req('sync',{})
        self.assertEqual(settings.read_bytes(),before)
        self.assertEqual(self.install(name)[0],409)

    def test_parent_symlink_and_extra_local_file_are_conflicts(self):
        name,root,body=self.source()
        (root/'linked-dir').symlink_to(root,target_is_directory=True)
        body['files']=['SKILL.md','linked-dir/SKILL.md']
        self.assertEqual(self.req('source',body)[0],400)
        self.assertEqual(self.install(name)[0],200)
        target=self.home/'.claude/skills'/name
        (target/'my-notes.md').write_text('local')
        self.assertEqual(self.install(name)[0],409)
        self.assertEqual(self.req('uninstall',{'id':name})[0],409)

    def test_corrupt_ai_registry_does_not_break_stage_one_board(self):
        class Other(NativeWorkbench): pass
        Other.setUpClass()
        try:
            Other.process.terminate();Other.process.wait(timeout=10)
            (Other.root/'ai/state.json').write_text('{"schema":1,"sources":"corrupt"}')
            from test_workbench_native import REPO
            Other.process=subprocess.Popen([str(BINARY),'--workbench-serve',str(Other.root),str(REPO/'Resources/Workbench')],stdout=Other.log,stderr=Other.log)
            server=Other()
            for _ in range(80):
                try:
                    self.assertEqual(server.request('/api/overview')[0],200)
                    break
                except OSError: time.sleep(.05)
            else: self.fail('board did not recover')
            self.assertEqual(server.request('/api/ai/status')[0],503)
            self.assertEqual(json.loads((Other.root/'ai/state.json').read_text())['sources'],'corrupt')
        finally: Other.tearDownClass()


if __name__=='__main__': unittest.main()
