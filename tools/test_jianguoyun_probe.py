import unittest
import io
import urllib.error
from unittest.mock import patch
import jianguoyun_probe as p

def xml(href='/dav/probe/a.wenc', status='200 OK'):
    return f'<d:multistatus xmlns:d="DAV:"><d:response><d:href>{href}</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 {status}</d:status></d:propstat></d:response></d:multistatus>'.encode()
class DavTests(unittest.TestCase):
    def test_short_top_level_folder(self):
        name=p.probe_folder()
        self.assertRegex(name,r'^wp0-[0-9a-f]{16}/$')
        self.assertEqual(len(name.rstrip('/')),20)
    def test_allowlisted_dav_diagnostic(self):
        raw=b'<error><message>sandbox name is too long: SECRET</message></error>'
        self.assertEqual(p.diagnostic_code(raw),'top_level_directory_name_too_long')
        for raw in (b'<error>SECRET</error>',b'not xml',b'<!DOCTYPE x><error/>',b'x'*8193):
            self.assertEqual(p.diagnostic_code(raw),'unclassified')
    def test_mkcol_explicit_empty_body_and_no_content_type(self):
        client=p.Client('test','SECRET')
        with patch.object(client.opener,'open',return_value=io.BytesIO(b'')) as opened, patch.object(p.time,'sleep'):
            client.request('probe/','MKCOL',stage='create_directory')
            request=opened.call_args.args[0]
            self.assertEqual(request.data,b'')
            self.assertEqual(request.get_header('Content-length'),'0')
            self.assertIsNone(request.get_header('Content-type'))
    def test_error_reports_stage_without_sensitive_body(self):
        client=p.Client('private-account','SECRET')
        error=urllib.error.HTTPError('https://private-url',400,'SECRET',{'Content-Type':'text/html'},io.BytesIO(b'SECRET private-account'))
        with patch.object(client.opener,'open',side_effect=error),patch.object(p.time,'sleep'):
            with self.assertRaises(p.ProbeError) as caught:
                client.request('probe/','MKCOL',stage='create_directory')
        report=p.failure_report(caught.exception)
        self.assertEqual(report['stage'],'create_directory')
        self.assertEqual(report['method'],'MKCOL')
        self.assertEqual(report['http_status'],400)
        for private in ('SECRET','private-account','private-url'):
            self.assertNotIn(private,str(report))
    def test_auth_preflight_only_queries_root_properties(self):
        client=p.Client('test','SECRET')
        class Response(io.BytesIO): status=207
        with patch.object(client.opener,'open',return_value=Response(b'')) as opened,patch.object(p.time,'sleep'):
            client.request('','PROPFIND',b'<test/>',stage='authenticate_root',depth='0')
            self.assertEqual(opened.call_args.args[0].get_header('Depth'),'0')
    def test_valid(self): self.assertEqual(p.listing(xml(),'/dav/probe/'),{'a.wenc'})
    def test_reject_partial_or_foreign(self):
        for raw in (xml(status='403 Forbidden'),xml('https://evil.example/dav/probe/a'),xml('/dav/other/a'),b'<!DOCTYPE a><a/>',b'broken'):
            with self.assertRaises(p.ProbeError): p.listing(raw,'/dav/probe/')
    def test_listing_limit(self):
        response=xml().split(b'<d:response>')[1].split(b'</d:response>')[0]
        raw=b'<d:multistatus xmlns:d="DAV:">'+(b'<d:response>'+response+b'</d:response>')*700+b'</d:multistatus>'
        with self.assertRaises(p.ProbeError): p.listing(raw,'/dav/probe/')
    def test_no_redirect(self): self.assertIsNone(p.NoRedirect().redirect_request(None,None,None,None,None,None))
    def test_unsafe_path_before_network(self):
        client=p.Client('test','public-test-password')
        for path in ('../a','https://evil.example/','/a','a?x'):
            with self.assertRaises(p.ProbeError): client.request(path)
if __name__=='__main__': unittest.main()
