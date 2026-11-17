import io
import unittest
import urllib.error
from unittest.mock import patch
import onedrive_probe as p

class ProbeTests(unittest.TestCase):
    def test_scope_never_upgrades(self):
        self.assertIn("files.readwrite.appfolder",p.validate_scopes("Files.ReadWrite.AppFolder offline_access"))
        for scope in ("Files.ReadWrite", "Files.ReadWrite.AppFolder Files.ReadWrite.All", "", "Files.ReadWrite.AppFolder User.Read"):
            with self.assertRaises(p.ProbeError): p.validate_scopes(scope)
    def test_callback_state_and_duplicate_code(self):
        self.assertEqual(p.callback_code("/callback?code=secret&state=expected","expected"),"secret")
        self.assertIsNone(p.callback_code("/callback?code=secret&state=wrong","expected"))
        self.assertIsNone(p.callback_code("/else?code=secret&state=expected","expected"))
        with self.assertRaises(p.ProbeError): p.callback_code("/callback?code=x&code=y&state=expected","expected")
    def test_graph_host_pinning(self):
        for url in ("https://evil.example/v1.0/me", "https://graph.microsoft.com.evil/v1.0/me", "http://graph.microsoft.com/v1.0/me", "https://user@graph.microsoft.com/v1.0/me"):
            with self.assertRaises(p.ProbeError): p.graph_url(url)
    def test_redirect_strips_token(self):
        error=urllib.error.HTTPError("hidden",302,"redirect",{"Location":"https://download.example/file?secret"},None)
        class Response(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self,*args): self.close()
        with patch.object(p.urllib.request.OpenerDirector,"open",side_effect=[error,Response(b"ciphertext")]) as mocked:
            self.assertEqual(p.request_bytes(p.GRAPH+"/content",headers={"Authorization":"Bearer SECRET"},allow_redirect=True),b"ciphertext")
            self.assertNotIn("Authorization",dict(mocked.call_args_list[1].args[0].header_items()))
    def test_throttled_get_retries_but_post_does_not(self):
        error=urllib.error.HTTPError("hidden",429,"throttle",{"Retry-After":"0"},None)
        with patch.object(p.urllib.request.OpenerDirector,"open",side_effect=error) as opened,patch.object(p.time,"sleep"):
            with self.assertRaises(p.ProbeError): p.request_bytes(p.GRAPH+"/test")
            self.assertEqual(opened.call_count,3)
            opened.reset_mock()
            with self.assertRaises(p.ProbeError): p.request_bytes(p.GRAPH+"/test",method="POST",data=b"{}")
            self.assertEqual(opened.call_count,1)
    def test_pagination_cross_host_rejected(self):
        graph=p.Graph("TOKEN")
        with patch.object(p,"request_json",return_value={"value":[],"@odata.nextLink":"https://evil.example/v1.0/me"}):
            with self.assertRaises(p.ProbeError): graph.list_all("folder")

if __name__=="__main__": unittest.main()
