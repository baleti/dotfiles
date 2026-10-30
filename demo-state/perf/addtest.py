p="tests/test_server.py"; s=open(p).read()
a="    async def test_meta_start_layout_zero(self):"
b='''    async def test_file_changed_on_disk_is_reparsed_not_served_stale(self):
        import os
        data = bytearray(os.urandom(300000)); Path(self.path).write_bytes(data)
        client = await self.client(loading=True)
        await self.load(client.server.app)
        await self.assert_json(client, '/api/meta', dict(self.doc.meta(), start=1))
        self.assertEqual(self.doc_factory.call_count, 1)
        data[150000] ^= 1; Path(self.path).write_bytes(data)       # overwrite save: same size, different content
        await self.assert_json(client, '/api/meta', dict(self.doc.meta(), start=1))
        self.assertEqual(self.doc_factory.call_count, 2)           # parsed again, so no old scene is written under the new key

'''
assert s.count(a)==1; open(p,"w").write(s.replace(a,b+a))
