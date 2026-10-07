from __future__ import annotations

import json
import shlex
import tempfile
import subprocess
import threading
import socket
import time
import unittest
from pathlib import Path
from unittest import mock

from scripts import android_dependency_network as network


class HungProcess:
    """模拟持续分段响应或挂起；结束证据来自 poll/wait，而非只检查 kill 调用。"""

    def __init__(self, advance=None, unreapable=False):
        self.returncode = None
        self.stdin = None
        self.stdout = None
        self.advance = advance
        self.unreapable = unreapable
        self.entered = threading.Event()
        self.terminated = False
        self.killed = False
        self.waited = False
        self.calls = []
        self.on_communicate = None

    def communicate(self, input=None, timeout=None):
        self.entered.set()
        self.calls.append((input, timeout))
        if self.on_communicate:
            self.on_communicate()
        if self.advance:
            self.advance(timeout)
        else:
            self.entered.wait(timeout=timeout)
            # 等待实际有界时间，模拟没有完成输出的网络子进程。
            threading.Event().wait(timeout=timeout)
        raise subprocess.TimeoutExpired('仅测试子进程', timeout, output=b'password=fake-private-segment')

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True
        if not self.unreapable:
            self.returncode = -9

    def wait(self, timeout=None):
        if self.returncode is None:
            if self.advance:
                self.advance(timeout)
            raise subprocess.TimeoutExpired('仅测试子进程', timeout)
        self.waited = True
        return self.returncode


class DependencyNetworkTest(unittest.TestCase):
    def test_plan_has_no_network_or_filesystem_side_effects(self):
        with mock.patch.object(network, "query") as query, mock.patch.object(Path, "write_text") as write:
            plan = network.plan()
        query.assert_not_called()
        write.assert_not_called()
        self.assertEqual(set(plan['hosts']), set(network.HOSTS))
        self.assertNotIn('jitpack.io', plan['hosts'])
        self.assertNotIn('jcenter.bintray.com', plan['hosts'])

    def test_doh_no_proxy_default_tls_no_redirect_and_query_identity(self):
        answer = {'Status': 0, 'Question': [{'name': 'plugins.gradle.org', 'type': 1}],
                  'Answer': [{'name': 'plugins.gradle.org', 'type': 1, 'TTL': 60, 'data': '8.8.8.8'}]}
        response = mock.MagicMock(status=200)
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(answer).encode()
        opener = mock.Mock(); opener.open.return_value = response
        with mock.patch.object(network.urllib.request, 'build_opener', return_value=opener) as builder, \
                mock.patch.object(network.time, 'time', return_value=100):
            result = network._query_direct('plugins.gradle.org', 1)
        self.assertEqual(result['records'][0]['expires_at'], 160)
        self.assertEqual(builder.call_args.args[0].proxies, {})
        tls = builder.call_args.args[2]._context
        self.assertEqual(tls.verify_mode, network.ssl.CERT_REQUIRED)
        self.assertTrue(tls.check_hostname)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_header('Accept'), 'application/dns-json')
        self.assertTrue(request.full_url.startswith(network.DOH_ENDPOINT + '?'))
        with self.assertRaises(network.NetworkError):
            network.NoRedirect().redirect_request(None, None, 303, None, None, 'https://other.example')
        with mock.patch.object(network.urllib.request, 'build_opener') as build:
            with self.assertRaises(network.NetworkError): network.query('jitpack.io', 1)
        build.assert_not_called()

    def test_both_jvms_keep_project_options_and_task_scope(self):
        with tempfile.TemporaryDirectory(prefix='network with spaces ') as temp:
            home = Path(temp)
            props = home / 'project.properties'
            original = '-Xmx4G -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError'
            props.write_text('org.gradle.jvmargs=' + original + '\n')
            env = network.jvm_environment({'JAVA_HOME': '/selected/jdk'}, home, props, 12345)
            wrapper = shlex.split(env['JAVA_OPTS'])
            gradle = shlex.split(env['GRADLE_OPTS'])
            mapping = '-Djdk.net.hosts.file=' + str(home / 'official-dependency.hosts')
            self.assertIn(mapping, wrapper)
            self.assertIn(mapping, gradle)
            daemon = next(arg.removeprefix('-Dorg.gradle.jvmargs=') for arg in gradle if arg.startswith('-Dorg.gradle.jvmargs='))
            self.assertTrue(daemon.startswith(original + ' '))
            self.assertIn(mapping, shlex.split(daemon))
            for protocol in ('http', 'https'):
                self.assertIn(f'-D{protocol}.proxyHost=127.0.0.1', shlex.split(daemon))
                self.assertIn(f'-D{protocol}.proxyPort=12345', shlex.split(daemon))
            self.assertIn('-Dorg.gradle.daemon=false', gradle)
            self.assertEqual(env['GRADLE_USER_HOME'], str(home))
            self.assertEqual(props.read_text(), 'org.gradle.jvmargs=' + original + '\n')
            source = network.prepare_files(home, 12345)
            self.assertIn('HttpsURLConnection', source.read_text())
            security = (home / 'dns-cache.security').read_text()
            self.assertNotIn('trustStore', security)
            self.assertNotIn('disabledAlgorithms', security)
            self.assertIn('BETTBOX_TASK_DNS_VERIFIED', (home / 'init.d/task-network.gradle').read_text())

    def test_preexisting_mapping_or_proxy_parameters_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            props = Path(temp) / 'project.properties'
            for extra in ['-Djdk.net.hosts.file=/global', '-Dhttps.proxyHost=other', '-Djava.security.properties==/replace-all']:
                props.write_text('org.gradle.jvmargs=-Xmx4G ' + extra + '\n')
                with self.assertRaises(network.NetworkError): network.jvm_environment({}, Path(temp), props, 12345)

    def test_cname_ttl_is_conservative_and_unrelated_addresses_rejected(self):
        answer = {'Status': 0, 'Question': [{'name': 'plugins.gradle.org.', 'type': 1}],
            'Answer': [{'name': 'plugins.gradle.org.', 'type': 5, 'TTL': 20, 'data': 'canonical.example.'},
                       {'name': 'canonical.example.', 'type': 1, 'TTL': 60, 'data': '8.8.8.8'}]}
        response = mock.MagicMock(status=200); response.__enter__.return_value = response
        response.read.side_effect = lambda _: json.dumps(answer).encode()
        opener = mock.Mock(); opener.open.return_value = response
        with mock.patch.object(network.urllib.request, 'build_opener', return_value=opener), \
                mock.patch.object(network.time, 'time', return_value=100):
            result = network._query_direct('plugins.gradle.org', 1)
            self.assertEqual(result['records'][0]['expires_at'], 120)
            answer['Answer'][1]['name'] = 'unrelated.example.'
            with self.assertRaises(network.NetworkError): network._query_direct('plugins.gradle.org', 1)

    def test_redirect_and_wrapper_urls_cannot_expand_scope(self):
        for url in ['http://plugins.gradle.org/a', 'https://jitpack.io/a', 'https://user:pass@plugins.gradle.org/a', 'https://plugins.gradle.org:8443/a']:
            with self.assertRaises(network.NetworkError): network.checked_url(url)
        self.assertEqual(network.checked_url('https://release-assets.githubusercontent.com/a?temporary=signed').hostname, 'release-assets.githubusercontent.com')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            props = root / 'android/gradle/wrapper/gradle-wrapper.properties'
            props.parent.mkdir(parents=True)
            props.write_text('distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n')
            self.assertEqual(network.probe_urls(root)[-1], 'https://services.gradle.org/distributions/gradle-8.14-all.zip')
            props.write_text('distributionUrl=https\\://unapproved.example/gradle.zip\n')
            with self.assertRaises(network.NetworkError): network.probe_urls(root)

    def test_unknown_source_has_only_bounded_domain_fields(self):
        self.assertEqual(network.unknown_hosts('java.net.UnknownHostException: jitpack.io\nUnknown host jcenter.bintray.com'), ['jcenter.bintray.com', 'jitpack.io'])
        self.assertEqual(network.unknown_hosts('java.net.UnknownHostException: plugins.gradle.org'), [])

    def test_lease_unverified_worker_exit_is_not_claimed_complete(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 60)
            thread = mock.Mock(ident=1)
            thread.is_alive.return_value = True
            lease._threads = [thread]
            self.assertFalse(lease.close())
            thread.join.assert_called_once()
            self.assertLessEqual(thread.join.call_args.kwargs['timeout'], 3)
            lease._failure = True
            with self.assertRaises(network.NetworkError): lease.check()


    def test_segmented_output_cannot_extend_absolute_deadline(self):
        clock = [10.0]
        process = HungProcess(advance=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        with mock.patch.object(network.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(network.subprocess, 'Popen', return_value=process) as spawn:
            with self.assertRaises(network.NetworkError) as error:
                network.query(network.HOSTS[0], 1, timeout=.6)
        self.assertIn('绝对时间', str(error.exception))
        self.assertNotIn('fake-private-segment', str(error.exception))
        self.assertLessEqual(clock[0], 11.6)
        self.assertTrue(process.terminated and process.killed and process.waited)
        self.assertIsNotNone(process.poll())
        self.assertGreaterEqual(len(process.calls), 3)
        self.assertIsNotNone(process.calls[0][0])
        self.assertTrue(all(payload is None for payload, _ in process.calls[1:]))
        self.assertTrue(all(0 < timeout <= .2 for _, timeout in process.calls))
        self.assertEqual(spawn.call_args.kwargs['stderr'], subprocess.DEVNULL)
        self.assertNotIn('HTTPS_PROXY', spawn.call_args.kwargs['env'])
        self.assertNotIn('start_new_session', spawn.call_args.kwargs)

    def test_initial_query_cancellation_reaps_child_and_stops_queries(self):
        clock = [10.0]
        workers = network.DohWorkers()
        process = HungProcess(advance=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        process.on_communicate = workers.close
        with mock.patch.object(network.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(network.subprocess, 'Popen', return_value=process) as spawn:
            with self.assertRaises(network.NetworkError):
                network.query(network.HOSTS[0], 1, deadline=100, workers=workers)
        spawn.assert_called_once()
        self.assertTrue(process.killed and process.waited)
        self.assertTrue(workers.close())

    def test_completed_child_returns_only_matching_public_records_and_closes_pipes(self):
        process = mock.Mock(returncode=0)
        process.poll.return_value = 0
        result = {'host': network.HOSTS[0], 'type': 1, 'records': []}
        process.communicate.return_value = (json.dumps(result).encode(), None)
        with mock.patch.object(network.subprocess, 'Popen', return_value=process):
            self.assertEqual(network.query(network.HOSTS[0], 1), result)
        sent = json.loads(process.communicate.call_args.kwargs['input'])
        self.assertEqual(sent, {'host': network.HOSTS[0], 'type': 1, 'timeout': 10})
        process.terminate.assert_not_called()
        process.stdin.close.assert_called_once()
        process.stdout.close.assert_called_once()
        result['host'] = 'jitpack.io'
        process.communicate.return_value = (json.dumps(result).encode(), None)
        with mock.patch.object(network.subprocess, 'Popen', return_value=process):
            with self.assertRaises(network.NetworkError):
                network.query(network.HOSTS[0], 1)

    def test_unknown_scope_never_spawns_worker(self):
        with mock.patch.object(network.subprocess, 'Popen') as spawn:
            with self.assertRaises(network.NetworkError):
                network.query('jitpack.io', 1)
        spawn.assert_not_called()

    def test_unreapable_owned_child_is_not_reported_verified(self):
        clock = [10.0]
        process = HungProcess(advance=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
                              unreapable=True)
        workers = network.DohWorkers()
        with mock.patch.object(network.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(network.subprocess, 'Popen', return_value=process):
            workers.spawn()
            self.assertFalse(workers.close())
        self.assertTrue(process.terminated and process.killed)
        self.assertIsNone(process.poll())
        self.assertIn(process, workers._processes)

    def test_worker_rejects_unknown_query_and_never_returns_raw_error(self):
        stream = mock.Mock()
        stream.buffer.read.return_value = json.dumps({'host': 'jitpack.io', 'type': 1, 'timeout': 1}).encode()
        with mock.patch.object(network.sys, 'stdin', stream), \
                mock.patch.object(network, '_query_direct') as direct:
            self.assertEqual(network._worker_main(), 1)
        direct.assert_not_called()
        stream.buffer.read.return_value = json.dumps({'host': network.HOSTS[0], 'type': 1, 'timeout': 1}).encode()
        with mock.patch.object(network.sys, 'stdin', stream), \
                mock.patch.object(network.sys, 'stdout') as output, \
                mock.patch.object(network, '_query_direct', side_effect=RuntimeError('password=fake')):
            self.assertEqual(network._worker_main(), 1)
        output.write.assert_not_called()


    def public_answer(self, ttl=20, started=None, addresses=('8.8.8.8',)):
        started = time.monotonic() if started is None else started
        return {'host': network.HOSTS[0], 'type': 1, 'fetched_at': time.time(),
                'queried_monotonic': started, 'received_monotonic': time.monotonic(),
                'records': [{'address': address, 'ttl': ttl, 'expires_monotonic': started + ttl,
                             'address_ttl': ttl, 'cname_ttls': []} for address in addresses]}

    def test_files_contain_only_localhost_and_jvms_use_task_https_proxy(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            props = home / 'properties'
            props.write_text('org.gradle.jvmargs=-Xmx4G\n')
            env = network.jvm_environment({'HTTP_PROXY': 'unchanged-public-fixture'}, home, props, 12345)
            source = network.prepare_files(home, 12345)
            self.assertEqual((home / 'official-dependency.hosts').read_text(), '127.0.0.1 localhost\n::1 localhost\n')
            for key in ('JAVA_OPTS', 'GRADLE_OPTS'):
                args = shlex.split(env[key])
                self.assertIn('-Dhttps.proxyHost=127.0.0.1', args)
                self.assertIn('-Dhttps.proxyPort=12345', args)
                self.assertIn('-Dhttp.proxyHost=127.0.0.1', args)
                self.assertIn('-Dhttp.proxyPort=12345', args)
                self.assertIn('-Dhttp.nonProxyHosts=', args)
            self.assertEqual(env['HTTP_PROXY'], 'unchanged-public-fixture')
            self.assertNotIn('HTTPS_PROXY', env)
            text = source.read_text()
            self.assertIn('ProxySelector.getDefault().select(uri)', text)
            self.assertIn('uri.toURL().openConnection()', text)
            self.assertNotIn('Proxy.NO_PROXY', text)
            self.assertNotIn('setSSLSocketFactory', text)
            self.assertNotIn('setHostnameVerifier', text)
            init = (home / 'init.d/task-network.gradle').read_text()
            self.assertIn("['http','https'].each", init)
            self.assertIn("protocol + '.proxyPort'", init)
            self.assertIn("System.getProperty('http.nonProxyHosts') != ''", init)
            for url in ('http://8.8.8.8/', 'http://bettbox-unapproved.invalid/',
                        'https://8.8.8.8/', 'https://bettbox-unapproved.invalid/'):
                self.assertIn('"' + url + '"', text)
            self.assertIn('verifyProxy(new URI(input))', text)
            selector = text[text.index('static void verifyProxy'):text.index('static void check')]
            self.assertNotIn('openConnection', selector)


    def test_connect_authority_scope_and_pipelined_tls_are_preserved(self):
        extra = b'\x16\x03\x03PUBLIC_TLS_BYTES'
        self.assertEqual(network.connect_host(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\nHost: plugins.gradle.org:443\r\n\r\n' + extra),
                         ('plugins.gradle.org', extra))
        for request in [b'GET https://plugins.gradle.org/ HTTP/1.1', b'CONNECT jitpack.io:443 HTTP/1.1',
                        b'CONNECT 8.8.8.8:443 HTTP/1.1', b'CONNECT user:pass@plugins.gradle.org:443 HTTP/1.1',
                        b'CONNECT plugins.gradle.org:80 HTTP/1.1', b'CONNECT plugins.gradle.org.:443 HTTP/1.1']:
            with self.assertRaises(network.NetworkError):
                network.connect_host(request + b'\r\n\r\n')
        with self.assertRaises(network.NetworkError):
            network.connect_host(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\nX: ' + b'x' * 4096 + b'\r\n\r\n')

    def test_short_and_zero_ttl_remain_original_minimum_in_worker(self):
        for ttl in (0, 1):
            answer = {'Status': 0, 'Question': [{'name': network.HOSTS[0], 'type': 1}],
                      'Answer': [{'name': network.HOSTS[0], 'type': 5, 'TTL': ttl, 'data': 'canonical.example'},
                                 {'name': 'canonical.example', 'type': 1, 'TTL': 60, 'data': '8.8.8.8'}]}
            response = mock.MagicMock(status=200); response.__enter__.return_value = response
            response.read.return_value = json.dumps(answer).encode()
            opener = mock.Mock(); opener.open.return_value = response
            with mock.patch.object(network.urllib.request, 'build_opener', return_value=opener), \
                    mock.patch.object(network.time, 'monotonic', side_effect=[100, 100.5]):
                result = network._query_direct(network.HOSTS[0], 1)
            self.assertEqual(result['records'][0]['ttl'], ttl)
            self.assertEqual(result['records'][0]['expires_monotonic'], 100 + ttl)
            self.assertEqual(result['records'][0]['address_ttl'], 60)
            self.assertNotEqual(result['queried_monotonic'], result['received_monotonic'])

    def test_expired_answer_requeries_and_zero_ttl_is_single_use(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 30)
            expired = self.public_answer(ttl=1, started=time.monotonic() - 2)
            empty = self.public_answer(addresses=())
            fresh = self.public_answer(ttl=1)
            upstream, peer = socket.socketpair()
            self.addCleanup(peer.close)
            with mock.patch.object(network, 'query', side_effect=[expired, empty, fresh]) as query, \
                    mock.patch.object(lease, '_address_connect', return_value=upstream) as connect:
                self.assertIs(lease._upstream(network.HOSTS[0]), upstream)
            self.assertEqual(query.call_count, 3)
            connect.assert_called_once()
            self.assertEqual(lease.history[0]['ttl'], 1)
            upstream.close()
            lease.history.clear()
            upstream, peer = socket.socketpair(); self.addCleanup(peer.close)
            with mock.patch.object(network, 'query', return_value=self.public_answer(ttl=0)) as query, \
                    mock.patch.object(lease, '_address_connect', return_value=upstream):
                self.assertIs(lease._upstream(network.HOSTS[0]), upstream)
            query.assert_called_once()
            self.assertEqual(lease.history[0]['category'], 'fresh-single-use')
            self.assertEqual(lease.history[0]['ttl'], 0)
            upstream.close()
            self.assertTrue(lease.close())

    def test_expiry_after_connect_closes_address_and_never_claims_usable(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 30)
            clock = [10.0]
            connected = []
            def delayed(address, end):
                clock[0] = end + .1
                upstream, peer = socket.socketpair()
                connected.append(upstream); self.addCleanup(peer.close)
                lease._track(upstream)
                return upstream
            with mock.patch.object(network.time, 'monotonic', side_effect=lambda: clock[0]), \
                    mock.patch.object(network, 'query', side_effect=lambda *a, **kw: self.public_answer(ttl=1, started=clock[0])), \
                    mock.patch.object(lease, '_address_connect', side_effect=delayed), \
                    self.assertRaises(network.NetworkError):
                lease._upstream(network.HOSTS[0])
            self.assertTrue(all(stream.fileno() == -1 for stream in connected))
            self.assertEqual(lease.history, [])
            self.assertTrue(lease.close())

    def test_loopback_proxy_forwards_tls_tail_and_unknown_host_fails_task(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            upstream, peer = socket.socketpair(); peer.settimeout(2)
            def supplied(host, **kwargs):
                lease._track(upstream)
                return upstream
            with mock.patch.object(lease, '_upstream', side_effect=supplied):
                lease.start()
                self.assertEqual(lease._listener.getsockname()[0], '127.0.0.1')
                client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                try:
                    client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\nPUBLIC_TLS_TAIL')
                    self.assertIn(b'200 Connection Established', client.recv(4096))
                    self.assertEqual(peer.recv(4096), b'PUBLIC_TLS_TAIL')
                    peer.sendall(b'PUBLIC_TLS_RESPONSE')
                    self.assertEqual(client.recv(4096), b'PUBLIC_TLS_RESPONSE')
                finally:
                    client.close(); peer.close(); self.assertTrue(lease.close())
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            lease.start()
            try:
                client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                client.sendall(b'CONNECT jitpack.io:443 HTTP/1.1\r\n\r\n')
                self.assertEqual(client.recv(1), b'')
                client.close()
                with self.assertRaises(network.NetworkError): lease.check()
                self.assertEqual(lease._event_counts['target-outside-allowlist'], 1)
            finally:
                self.assertTrue(lease.close())

    def test_rejected_repository_diagnostics_never_retain_raw_target(self):
        for host, label in [('jcenter.bintray.com', 'nonofficial-jcenter'),
                            ('jitpack.io', 'nonofficial-jitpack'), ('private-token.invalid', 'outside-other')]:
            with self.assertRaises(network.HeaderError) as caught:
                network.connect_host(f'CONNECT {host}:443 HTTP/1.1\r\n\r\n'.encode())
            error = caught.exception
            self.assertEqual(error.category, 'target-outside-allowlist')
            self.assertEqual(error.source, label)
            self.assertNotIn(host, str(error))
            self.assertNotIn(host, json.dumps(error.__dict__))

    def test_slow_header_timeout_is_local_while_authorized_tunnel_stays_usable(self):
        clock = time.monotonic
        offset = [0]
        entered = threading.Event()
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), clock() + 100)
            upstream, peer = socket.socketpair()
            peer.settimeout(2)
            original_header = lease._header
            def header(client, accepted):
                entered.set()
                return original_header(client, accepted)
            def supplied(host, **kwargs):
                lease._track(upstream)
                return upstream
            with mock.patch.object(network.time, 'monotonic', side_effect=lambda: clock() + offset[0]), \
                    mock.patch.object(lease, '_upstream', side_effect=supplied):
                lease.start()
                active = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                slow = None
                try:
                    active.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                    self.assertIn(b'200 Connection Established', active.recv(4096))
                    with mock.patch.object(lease, '_header', side_effect=header):
                        slow = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                        slow.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n')
                        self.assertTrue(entered.wait(2))
                        offset[0] = 16
                        self.assertIn(b'408 Request Timeout', slow.recv(4096))
                    lease.check()
                    self.assertFalse(lease._failure)
                    self.assertEqual(lease._event_counts['header-timeout'], 1)
                    self.assertEqual(lease._event_counts['target-outside-allowlist'], 0)
                    peer.sendall(b'PUBLIC_CONCURRENT_TLS')
                    self.assertEqual(active.recv(4096), b'PUBLIC_CONCURRENT_TLS')
                finally:
                    active.close(); peer.close()
                    if slow is not None:
                        slow.close()
                    self.assertTrue(lease.close())

    def test_header_security_reasons_are_fixed_and_fail_closed(self):
        cases = [(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\nBAD\r\n\r\n', 'header-malformed'),
                 (b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\nX: ' + b'A' * 4096, 'header-too-large'),
                 (b'CONNECT unknown.invalid:443 HTTP/1.1\r\n\r\n', 'target-outside-allowlist')]
        for request, category in cases:
            with self.subTest(category=category), tempfile.TemporaryDirectory() as temp:
                lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
                with mock.patch.object(lease, '_upstream') as supplied:
                    lease.start()
                    client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                    try:
                        client.sendall(request)
                        try:
                            self.assertEqual(client.recv(4096), b'')
                        except ConnectionResetError:
                            pass  # 超长头尚有未读取字节，关闭连接可能返回RST。
                        with self.assertRaises(network.NetworkError):
                            lease.check()
                        self.assertEqual(lease._event_counts[category], 1)
                        supplied.assert_not_called()
                        self.assertNotIn('unknown.invalid', json.dumps(lease.history))
                    finally:
                        client.close(); self.assertTrue(lease.close())

    def test_close_cancels_owned_live_doh_and_all_proxy_threads(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 30)
            process = HungProcess()
            with mock.patch.object(network.subprocess, 'Popen', return_value=process):
                lease.start()
                client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                try:
                    client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                    self.assertTrue(process.entered.wait(timeout=1))
                    self.assertTrue(lease.close())
                    self.assertTrue(process.killed and process.waited)
                    self.assertTrue(all(not thread.is_alive() for thread in lease._threads))
                    self.assertEqual(lease._sockets, set())
                finally:
                    client.close(); lease.close()


    def test_zero_ttl_failed_attempt_is_not_reused_for_another_address(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 30)
            zero = self.public_answer(ttl=0, addresses=('8.8.8.8', '1.1.1.1'))
            empty = self.public_answer(addresses=())
            with mock.patch.object(network, 'query', side_effect=[zero, empty] * 3), \
                    mock.patch.object(lease, '_address_connect', side_effect=OSError()) as connect, \
                    self.assertRaises(network.NetworkError):
                lease._upstream(network.HOSTS[0])
            self.assertEqual(connect.call_count, 3)
            self.assertTrue(all(call.args[0] == '8.8.8.8' for call in connect.call_args_list))
            self.assertEqual(lease.history, [])
            self.assertTrue(lease.close())

    def test_relay_partial_send_bounded_buffers_and_bidirectional_half_close(self):
        class LimitedSocket:
            def __init__(self, stream):
                self.stream = stream
                self.largest_buffer = 0
                self.partial_sends = 0
            def fileno(self): return self.stream.fileno()
            def setblocking(self, value): return self.stream.setblocking(value)
            def recv(self, size): return self.stream.recv(size)
            def shutdown(self, how): return self.stream.shutdown(how)
            def send(self, data):
                self.largest_buffer = max(self.largest_buffer, len(data))
                if len(data) > 512: self.partial_sends += 1
                return self.stream.send(data[:512])
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            proxy_client, client = socket.socketpair()
            proxy_upstream, upstream = socket.socketpair()
            streams = (proxy_client, client, proxy_upstream, upstream)
            for stream in streams: self.addCleanup(stream.close)
            client.settimeout(3); upstream.settimeout(3)
            limited_client, limited_upstream = LimitedSocket(proxy_client), LimitedSocket(proxy_upstream)
            request, response = b'R' * 400000, b'S' * 400000
            seen = []
            errors = []
            def serve_upstream():
                try:
                    data = bytearray()
                    while True:
                        part = upstream.recv(65536)
                        if not part: break
                        data.extend(part)
                    seen.append(bytes(data))
                    upstream.sendall(response)
                    upstream.shutdown(socket.SHUT_WR)
                except Exception as error: errors.append(type(error).__name__)
            def relay():
                try: lease._relay(limited_client, limited_upstream, b'INITIAL_TLS')
                except Exception as error: errors.append(type(error).__name__)
            server = threading.Thread(target=serve_upstream)
            forwarder = threading.Thread(target=relay)
            server.start(); forwarder.start()
            try:
                client.sendall(request); client.shutdown(socket.SHUT_WR)
                data = bytearray()
                while True:
                    part = client.recv(65536)
                    if not part: break
                    data.extend(part)
                self.assertEqual(bytes(data), response)
                server.join(timeout=2); forwarder.join(timeout=2)
                self.assertFalse(server.is_alive() or forwarder.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(seen, [b'INITIAL_TLS' + request])
                self.assertGreater(limited_client.partial_sends + limited_upstream.partial_sends, 0)
                self.assertLessEqual(max(limited_client.largest_buffer, limited_upstream.largest_buffer), 262144)
            finally:
                lease.close()
                for stream in streams: stream.close()
                server.join(timeout=2); forwarder.join(timeout=2)

    def test_resolution_six_and_relay_thirty_two_then_bounded_queue_overload(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            gate, occupied = threading.Event(), threading.Event()
            lock = threading.Lock(); active = [0]; maximum = [0]
            def hold(host, **kwargs):
                with lock:
                    active[0] += 1; maximum[0] = max(maximum[0], active[0])
                    if active[0] == 6: occupied.set()
                gate.wait(timeout=3)
                with lock: active[0] -= 1
                raise EOFError()
            clients = []
            with mock.patch.object(lease, '_upstream', side_effect=hold):
                lease.start()
                try:
                    for _ in range(32):
                        client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                        client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                        clients.append(client)
                    self.assertTrue(occupied.wait(timeout=1))
                    until = time.monotonic() + 1
                    while lease._queue.qsize() and time.monotonic() < until:
                        threading.Event().wait(.01)
                    self.assertEqual(lease._queue.qsize(), 0)
                    for _ in range(13):
                        client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                        client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                        clients.append(client)
                    self.assertIn(b'503 Service Unavailable', clients[-1].recv(4096))
                    self.assertEqual(maximum[0], 6)
                    self.assertFalse(lease._failure)
                    self.assertEqual(lease._event_counts['overload'], 1)
                finally:
                    gate.set()
                    for client in clients: client.close()
                    self.assertTrue(lease.close())


    def test_existing_tunnel_survives_dns_ttl_and_wall_clock_change(self):
        original_monotonic = time.monotonic
        offset = [0]
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), original_monotonic() + 10)
            upstream, peer = socket.socketpair(); peer.settimeout(2)
            def connected(address, end):
                lease._track(upstream)
                return upstream
            with mock.patch.object(network.time, 'monotonic', side_effect=lambda: original_monotonic() + offset[0]), \
                    mock.patch.object(network, 'query', side_effect=lambda *a, **kw: self.public_answer(ttl=1)), \
                    mock.patch.object(lease, '_address_connect', side_effect=connected):
                lease.start()
                client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                try:
                    client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\nFIRST_TLS')
                    self.assertIn(b'200 Connection Established', client.recv(4096))
                    self.assertEqual(peer.recv(4096), b'FIRST_TLS')
                    offset[0] = 2
                    self.assertLess(lease.history[0]['expires_monotonic'], time.monotonic())
                    with mock.patch.object(network.time, 'time', return_value=-100000):
                        peer.sendall(b'TLS_AFTER_TTL')
                        self.assertEqual(client.recv(4096), b'TLS_AFTER_TTL')
                        lease.check()
                finally:
                    client.close(); peer.close(); self.assertTrue(lease.close())


    def test_plain_http_ip_and_domain_are_rejected_without_dns_or_upstream(self):
        for authority in ('8.8.8.8', 'plugins.gradle.org'):
            with self.subTest(authority=authority), tempfile.TemporaryDirectory() as temp:
                lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
                with mock.patch.object(network, 'query') as query, \
                        mock.patch.object(lease, '_upstream') as upstream:
                    lease.start()
                    client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                    try:
                        client.sendall(('GET http://' + authority + '/ HTTP/1.1\r\nHost: ' + authority + '\r\n\r\n').encode())
                        self.assertEqual(client.recv(1), b'')
                        with self.assertRaises(network.NetworkError): lease.check()
                        query.assert_not_called(); upstream.assert_not_called()
                        self.assertEqual(lease._event_counts['target-outside-allowlist'], 1)
                        self.assertEqual(lease.history, [{'category': 'proxy-events', 'counts': lease._event_counts}])
                    finally:
                        client.close(); self.assertTrue(lease.close())


    def test_early_jvm_environment_is_generated_public_flags_only(self):
        with tempfile.TemporaryDirectory(prefix='public task with spaces ') as temp:
            home = Path(temp)
            props = home / 'project.properties'
            original = '-Xmx4G -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError'
            props.write_text('org.gradle.jvmargs=' + original + '\n')
            previous = {'JAVA_TOOL_OPTIONS': '-javaagent:/fictional/user-agent -Dfictional.private=value',
                        'JAVA_HOME': '/public/jdk'}
            env = network.jvm_environment(previous, home, props, 12345)
            expected = [f'-Djdk.net.hosts.file={home / "official-dependency.hosts"}',
                        f'-Djava.security.properties={home / "dns-cache.security"}',
                        '-Dhttps.proxyHost=127.0.0.1', '-Dhttps.proxyPort=12345',
                        '-Dhttp.proxyHost=127.0.0.1', '-Dhttp.proxyPort=12345',
                        '-Dhttp.nonProxyHosts=', '-Djava.net.useSystemProxies=false']
            self.assertEqual(shlex.split(env['JAVA_TOOL_OPTIONS']), expected)
            self.assertEqual(shlex.split(env['JAVA_OPTS']), expected)
            self.assertNotIn('fictional', env['JAVA_TOOL_OPTIONS'])
            self.assertEqual(previous['JAVA_TOOL_OPTIONS'], '-javaagent:/fictional/user-agent -Dfictional.private=value')
            self.assertNotIn('-Djava.security.properties==', env['JAVA_TOOL_OPTIONS'])
            gradle = shlex.split(env['GRADLE_OPTS'])
            jvmargs = next(arg.removeprefix('-Dorg.gradle.jvmargs=') for arg in gradle if arg.startswith('-Dorg.gradle.jvmargs='))
            self.assertTrue(jvmargs.startswith(original + ' '))
            self.assertEqual(props.read_text(), 'org.gradle.jvmargs=' + original + '\n')

    def test_probe_and_actual_gradle_init_check_all_official_direct_dns_and_loopback(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            source = network.prepare_files(home, 12345).read_text()
            init = (home / 'init.d/task-network.gradle').read_text()
            for host in network.HOSTS:
                self.assertIn('"' + host + '"', source)
                self.assertIn('"' + host + '"', init)
            self.assertIn('for (String host:allowed)', source)
            self.assertIn('InetAddress.getByName(host)', source)
            self.assertIn('java.net.InetAddress.getByName(host)', init)
            for code in (source, init):
                self.assertIn('UnknownHostException expected', code)
                self.assertIn('官方主机直接解析未被拒绝', code)
                self.assertIn('getAllByName', code)
                self.assertIn('isLoopbackAddress()', code)
                self.assertIn('本机 localhost 解析越出回环', code)
                self.assertNotIn('setHostnameVerifier', code)
                self.assertNotIn('setSSLSocketFactory', code)
                self.assertNotIn('trustStore', code)
            self.assertIn('uri.toURL().openConnection()', source)
            self.assertEqual((home / 'dns-cache.security').read_text(),
                             'networkaddress.cache.ttl=0\nnetworkaddress.cache.negative.ttl=0\nnetworkaddress.cache.stale.ttl=0\n')


    def test_proxy_diagnostic_counts_are_public_bounded_and_zero_values_published(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            self.assertTrue(lease.close())
            self.assertEqual(lease.history[0]['category'], 'proxy-events')
            self.assertTrue(all(value == 0 for value in lease.history[0]['counts'].values()))
            for _ in range(100): lease._event('overload')
            self.assertEqual(len(lease.history), 1)
            self.assertEqual(lease.history[0]['counts']['overload'], 100)
            with self.assertRaises(network.NetworkError): lease._event('GET fictional-secret-url')
            self.assertNotIn('fictional', json.dumps(lease.history))

    def test_failed_upstream_and_expired_queue_have_distinct_events(self):
        for expired in (False, True):
            with self.subTest(expired=expired), tempfile.TemporaryDirectory() as temp:
                lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
                client, peer = socket.socketpair(); peer.settimeout(2)
                lease._track(client)
                lease._queue.put((client, time.monotonic() - (16 if expired else 0)))
                peer.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                with mock.patch.object(lease, '_upstream', side_effect=network.NetworkError('固定测试错误')):
                    thread = threading.Thread(target=lease._serve); lease._threads = [thread]; thread.start()
                    try:
                        data = peer.recv(4096)
                        if expired:
                            self.assertIn(b'503', data)
                            self.assertEqual(lease._event_counts['queue-expired'], 1)
                            self.assertFalse(lease._failure)
                        else:
                            self.assertEqual(data, b'')
                            self.assertEqual(lease._event_counts['upstream-unavailable'], 1)
                            self.assertTrue(lease._failure)
                    finally:
                        peer.close(); self.assertTrue(lease.close())


    def test_six_long_relays_do_not_hold_resolution_slots_or_block_twelfth(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 10)
            peers, clients = [], []
            def connected(address, deadline):
                stream, peer = socket.socketpair()
                lease._track(stream); peers.append(peer)
                return stream
            with mock.patch.object(network, 'query', side_effect=lambda *a, **kw: self.public_answer()), \
                    mock.patch.object(lease, '_address_connect', side_effect=connected):
                lease.start()
                try:
                    for _ in range(12):
                        client = socket.create_connection(('127.0.0.1', lease.proxy_port), timeout=2)
                        clients.append(client)
                        client.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
                        self.assertIn(b'200 Connection Established', client.recv(4096))
                    self.assertEqual(len(lease._threads), 33)
                    self.assertEqual(len(lease.history), 12)
                    # 所有12条 relay 保持打开时，6个解析槽仍全部可用。
                    for _ in range(6): self.assertTrue(lease._resolution_slots.acquire(blocking=False))
                    self.assertFalse(lease._resolution_slots.acquire(blocking=False))
                    for _ in range(6): lease._resolution_slots.release()
                    self.assertTrue(all(value == 0 for value in lease._event_counts.values()))
                finally:
                    for client in clients: client.close()
                    for peer in peers: peer.close()
                    self.assertTrue(lease.close())
                    self.assertTrue(all(not thread.is_alive() for thread in lease._threads))
                    self.assertEqual(lease._sockets, set())

    def test_resolution_slot_expiry_is_retryable_503_and_does_not_start_lookup(self):
        original = time.monotonic; offset = [0]
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), original() + 90)
            client, peer = socket.socketpair(); peer.settimeout(2)
            lease._track(client)
            lease._queue.put((client, original()))
            peer.sendall(b'CONNECT plugins.gradle.org:443 HTTP/1.1\r\n\r\n')
            slot = mock.Mock()
            def timed_out(**kwargs):
                offset[0] += 31
                return False
            slot.acquire.side_effect = timed_out
            lease._resolution_slots = slot
            with mock.patch.object(network.time, 'monotonic', side_effect=lambda: original() + offset[0]), \
                    mock.patch.object(lease, '_upstream') as upstream:
                thread = threading.Thread(target=lease._serve); lease._threads = [thread]; thread.start()
                try:
                    self.assertIn(b'503 Service Unavailable', peer.recv(4096))
                    upstream.assert_not_called(); slot.release.assert_not_called()
                    self.assertEqual(lease._event_counts['resolution-slot-expired'], 1)
                    self.assertFalse(lease._failure)
                finally:
                    peer.close(); self.assertTrue(lease.close())

    def test_upstream_obeys_original_stage_deadline_after_slot_wait(self):
        with tempfile.TemporaryDirectory() as temp:
            lease = network.NetworkLease(Path(temp), time.monotonic() + 90)
            stream, peer = socket.socketpair(); self.addCleanup(peer.close)
            now = time.monotonic(); deadline = now + 2
            with mock.patch.object(network, 'query', return_value=self.public_answer(ttl=60)) as query, \
                    mock.patch.object(lease, '_address_connect', return_value=stream) as connect:
                self.assertIs(lease._upstream(network.HOSTS[0], deadline=deadline), stream)
                self.assertEqual(query.call_args.kwargs['deadline'], deadline)
                self.assertLessEqual(connect.call_args.args[1], deadline)
            stream.close(); self.assertTrue(lease.close())


if __name__ == '__main__':
    unittest.main()
