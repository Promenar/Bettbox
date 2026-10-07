#!/usr/bin/env python3
"""本项目官方 Android 依赖的任务专用 CONNECT 代理；导入与计划不发起网络请求。"""
from __future__ import annotations

import ipaddress
import json
import math
import os
import re
import queue
import selectors
import socket
import errno
import shlex
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DOH_ENDPOINT = "https://cloudflare-dns.com/dns-query"
HOSTS = (
    "plugins.gradle.org", "plugins-artifacts.gradle.org", "repo.maven.apache.org",
    "repo1.maven.org", "dl.google.com", "storage.googleapis.com", "services.gradle.org",
    "github.com", "release-assets.githubusercontent.com",
)
SOURCES = {
    "plugins.gradle.org": "android/settings.gradle.kts:gradlePluginPortal",
    "plugins-artifacts.gradle.org": "https://plugins.gradle.org/docs/mirroring:官方插件重定向",
    "repo.maven.apache.org": "android/settings.gradle.kts:mavenCentral",
    "repo1.maven.org": "plugins/flutter_qjs/android/build.gradle:既有官方 Maven Central 兼容入口",
    "dl.google.com": "android/settings.gradle.kts:google",
    "storage.googleapis.com": "Flutter 官方 download.flutter.io 仓库",
    "services.gradle.org": "android/gradle/wrapper/gradle-wrapper.properties",
    "github.com": "Gradle 官方分发重定向",
    "release-assets.githubusercontent.com": "Gradle 官方 GitHub 分发资产重定向",
}
DOMAIN = re.compile(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")


class NetworkError(RuntimeError):
    """只使用固定类别或白名单格式域名，不携带响应正文及签名 URL。"""


class HeaderError(NetworkError):
    """固定请求头原因不携带目标值、请求头或传输正文。"""

    def __init__(self, category: str):
        messages = {'header-timeout': 'CONNECT 请求头时间预算耗尽',
                    'header-too-large': 'CONNECT 请求头超出范围',
                    'header-malformed': 'CONNECT 请求头格式拒绝',
                    'target-outside-allowlist': 'CONNECT 目标越出批准范围'}
        if category not in messages:
            raise NetworkError('代理诊断事件越出固定范围')
        self.category = category
        super().__init__(messages[category])


def plan() -> dict[str, object]:
    return {"hosts": list(HOSTS), "resolver": DOH_ENDPOINT, "tls_verification": "Java 原 host/SNI 默认校验",
            "transport": "仅任务 JVM 的 127.0.0.1 随机端口 HTTPS CONNECT；DNS 不缓存",
            "nonofficial_sources": "不映射 JCenter/JitPack；未知主机停止", "writes": "仅执行模式任务目录"}


def checked_url(value: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or parsed.hostname not in HOSTS or parsed.username or parsed.password \
            or parsed.port not in (None, 443):
        raise NetworkError("依赖 HTTPS 入口越出批准范围")
    return parsed


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise NetworkError("DoH 入口不允许重定向")


def _query_direct(host: str, record_type: int, *, timeout: float = 10) -> dict[str, object]:
    if host not in HOSTS or record_type not in (1, 28):
        raise NetworkError("DNS 查询越出批准范围")
    url = DOH_ENDPOINT + "?" + urllib.parse.urlencode({"name": host, "type": record_type})
    request = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    fetched = time.time()
    queried = time.monotonic()
    try:
        with opener.open(request, timeout=timeout) as response:
            if response.status != 200:
                raise NetworkError("DoH HTTP 状态无效")
            raw = response.read(65537)
            if len(raw) > 65536:
                raise NetworkError("DoH 响应超过上限")
        data = json.loads(raw)
    except NetworkError:
        raise
    except Exception:
        raise NetworkError("批准 DoH 入口解析或默认 TLS 请求失败") from None
    received = time.monotonic()
    question = data.get('Question')
    if data.get("Status") != 0 or not isinstance(question, list) or len(question) != 1 \
            or question[0].get('name', '').rstrip('.').lower() != host or question[0].get('type') != record_type:
        raise NetworkError("DoH 查询身份或状态不匹配")
    answers = data.get('Answer', [])
    if not isinstance(answers, list) or len(answers) > 64:
        raise NetworkError("DoH 记录数量无效")
    names = {host}
    chain_ttls = []
    for _ in range(16):
        changed = False
        for answer in answers:
            if answer.get('type') == 5 and answer.get('name', '').rstrip('.').lower() in names:
                target = answer.get('data', '').rstrip('.').lower()
                ttl = answer.get('TTL')
                if not DOMAIN.fullmatch(target) or type(ttl) is not int or not 0 <= ttl <= 86400:
                    raise NetworkError("DoH CNAME 链无效")
                chain_ttls.append(ttl)
                if target not in names:
                    names.add(target); changed = True
        if not changed:
            break
    else:
        raise NetworkError("DoH CNAME 链超过上限")
    records = []
    for answer in answers:
        if answer.get("type") != record_type:
            continue
        if answer.get('name', '').rstrip('.').lower() not in names:
            raise NetworkError("DoH 地址记录不属于查询链")
        try:
            address = ipaddress.ip_address(answer["data"])
        except (ValueError, KeyError):
            raise NetworkError("DoH 地址无效") from None
        ttl = answer.get("TTL")
        if not address.is_global or address.version != (4 if record_type == 1 else 6) \
                or type(ttl) is not int or not 0 <= ttl <= 86400:
            raise NetworkError("DoH 地址作用域或 TTL 无效")
        address_ttl = ttl
        ttl = min([ttl, *chain_ttls])
        records.append({"address": str(address), "ttl": ttl, "fetched_at": fetched,
                        "expires_at": fetched + ttl, "expires_monotonic": queried + ttl,
                        "address_ttl": address_ttl, "cname_ttls": chain_ttls})
    return {"host": host, "type": record_type, "records": records, "fetched_at": fetched,
            "queried_monotonic": queried, "received_monotonic": received}


class DohWorkers:
    """只管理本实例创建的子进程，取消不涉及其它任务或系统进程。"""

    def __init__(self):
        self.cancelled = threading.Event()
        self._lock = threading.Lock()
        self._processes: set[subprocess.Popen] = set()

    def spawn(self) -> subprocess.Popen:
        # 不继承代理或凭据；TLS 使用系统默认信任。子进程留在任务进程组内。
        env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        with self._lock:
            if self.cancelled.is_set():
                raise NetworkError("任务 DNS 查询已取消")
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--doh-worker'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, env=env)
            self._processes.add(process)
            return process

    def reap(self, process: subprocess.Popen, deadline: float) -> bool:
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=max(.001, min(.25, deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=max(.001, deadline - time.monotonic()))
            verified = process.poll() is not None
        except (OSError, subprocess.TimeoutExpired):
            verified = process.poll() is not None
        if verified:
            with self._lock:
                self._processes.discard(process)
        return verified

    def close(self) -> bool:
        self.cancelled.set()
        deadline = time.monotonic() + 2
        with self._lock:
            processes = tuple(self._processes)
        verified = True
        for process in processes:
            verified = self.reap(process, deadline) and verified
        with self._lock:
            return verified and not self._processes


def query(host: str, record_type: int, *, timeout: float = 10,
          deadline: float | None = None, workers: DohWorkers | None = None) -> dict[str, object]:
    if host not in HOSTS or record_type not in (1, 28):
        raise NetworkError("DNS 查询越出批准范围")
    if not math.isfinite(timeout) or not 0 < timeout <= 10:
        raise NetworkError("DNS 查询时间预算无效")
    end = min(time.monotonic() + timeout, deadline if deadline is not None else float('inf'))
    owned = workers or DohWorkers()
    process = None
    try:
        if time.monotonic() >= end:
            raise NetworkError("DNS 总体时间预算耗尽")
        process = owned.spawn()
        payload = json.dumps({'host': host, 'type': record_type, 'timeout': timeout}).encode()
        while True:
            remaining = end - time.monotonic()
            if owned.cancelled.is_set():
                raise NetworkError("任务 DNS 查询已取消")
            if remaining <= 0:
                raise NetworkError("DoH 查询绝对时间预算耗尽")
            try:
                output, _ = process.communicate(input=payload, timeout=min(.2, remaining))
                break
            except subprocess.TimeoutExpired:
                # communicate 会继续收集分段输出；进度不能延长父进程的绝对截止时间。
                payload = None
        if process.returncode != 0 or len(output) > 131072:
            raise NetworkError("批准 DoH 子进程查询失败")
        result = json.loads(output)
        if not isinstance(result, dict) or result.get('host') != host or result.get('type') != record_type:
            raise NetworkError("DoH 子进程查询身份无效")
        return result
    except NetworkError:
        raise
    except Exception:
        raise NetworkError("批准 DoH 子进程查询失败") from None
    finally:
        if process is not None:
            if not owned.reap(process, time.monotonic() + 1):
                raise NetworkError("任务 DoH 子进程退出未验证")
            # 通信调用已结束且子进程已退出，此时关闭本查询拥有的管道。
            for stream in (process.stdin, process.stdout):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass  # 已确认退出，管道关闭错误不改变进程终止证据。


def connect_host(header: bytes) -> tuple[str, bytes]:
    """只解析 CONNECT authority；TLS 提前到达的字节原样保留。"""
    marker = header.find(b'\r\n\r\n')
    if marker < 0 or marker + 4 > 4096:
        raise HeaderError("header-too-large")
    try:
        lines = header[:marker].decode('ascii').split('\r\n')
        match = re.fullmatch(r'CONNECT ([A-Za-z0-9.-]+):443 HTTP/1\.[01]', lines[0])
        if match is None or match[1].lower() not in HOSTS:
            raise HeaderError("target-outside-allowlist")
        for line in lines[1:]:
            if not re.fullmatch(r'[A-Za-z0-9-]+: [\x20-\x7e]*', line):
                raise HeaderError("header-malformed")
        return match[1].lower(), header[marker + 4:]
    except (UnicodeError, IndexError):
        raise HeaderError("header-malformed") from None


def unknown_hosts(output: str) -> list[str]:
    hosts = set()
    for match in re.finditer(r"(?:UnknownHostException:\s*|Unknown host\s+['\"]?)([a-zA-Z0-9.-]{1,253})", output[-65536:]):
        host = match.group(1).lower().rstrip('.')
        if DOMAIN.fullmatch(host) and host not in HOSTS and host != "localhost":
            hosts.add(host)
    for match in re.finditer(r"Could not (?:GET|HEAD)\s+['\"]https://([a-zA-Z0-9.-]{1,253})(?:/|['\"])", output[-65536:]):
        host = match.group(1).lower().rstrip('.')
        if DOMAIN.fullmatch(host) and host not in HOSTS:
            hosts.add(host)
    return sorted(hosts)[:4]


def jvm_environment(env: dict[str, str], home: Path, properties: Path, proxy_port: int) -> dict[str, str]:
    if type(proxy_port) is not int or not 1 <= proxy_port <= 65535:
        raise NetworkError("任务代理端口无效")
    raw = properties.read_text()
    values = re.findall(r"^\s*org\.gradle\.jvmargs\s*=\s*(.+)$", raw, re.M)
    if len(values) != 1 or '\\' in values[0] or '\n' in values[0] or any(
            option in values[0] for option in ('jdk.net.hosts.file', 'java.security.properties', 'proxyHost', 'proxyPort', 'nonProxyHosts', 'useSystemProxies')):
        raise NetworkError("项目 Gradle JVM 参数不符合任务网络注入契约")
    hosts = home / "official-dependency.hosts"
    security = home / "dns-cache.security"
    extra = [f"-Djdk.net.hosts.file={hosts}", f"-Djava.security.properties={security}",
             "-Dhttps.proxyHost=127.0.0.1", f"-Dhttps.proxyPort={proxy_port}",
             "-Dhttp.proxyHost=127.0.0.1", f"-Dhttp.proxyPort={proxy_port}",
             "-Dhttp.nonProxyHosts=", "-Djava.net.useSystemProxies=false"]
    # wrapper 客户端与单次 Gradle JVM 各自注入，保留项目原有堆和元空间参数。
    daemon = values[0] + " " + shlex.join(extra)
    result = dict(env)
    # Gradle 将普通 -D 属性延后设置；受控启动环境确保 resolver/Security 初始化前生效。
    # 只生成公开 extra，覆盖旧值，不读取或继承用户 JAVA_TOOL_OPTIONS 内容。
    result.update({"GRADLE_USER_HOME": str(home), "JAVA_TOOL_OPTIONS": shlex.join(extra), "JAVA_OPTS": shlex.join(extra),
                   "GRADLE_OPTS": shlex.join(['-Dorg.gradle.daemon=false', *extra,
                                               '-Dorg.gradle.jvmargs=' + daemon])})
    return result


JAVA_PROBE = r'''import java.net.*; import javax.net.ssl.*;
class DependencyProbe {
  static final java.util.Set<String> allowed = java.util.Set.of(HOST_LIST);
  static void verifyProxy(URI uri) throws Exception {
    java.util.List<Proxy> proxies=ProxySelector.getDefault().select(uri);
    if (proxies.size()!=1 || proxies.get(0).type()!=Proxy.Type.HTTP) throw new Exception("任务代理选择失败");
    InetSocketAddress endpoint=(InetSocketAddress)proxies.get(0).address();
    if (!"127.0.0.1".equals(endpoint.getHostString()) || endpoint.getPort()!=PROXY_PORT) throw new Exception("任务代理地址失败");
  }
  static void check(String input) throws Exception {
    URI uri = new URI(input);
    for (int hop=0; hop<6; hop++) {
      if (!"https".equals(uri.getScheme()) || !allowed.contains(uri.getHost()) || uri.getUserInfo()!=null || (uri.getPort()!=-1 && uri.getPort()!=443)) throw new Exception("入口范围失败");
      verifyProxy(uri);
      HttpsURLConnection connection=(HttpsURLConnection)uri.toURL().openConnection();
      connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(10000); connection.setReadTimeout(10000); connection.setRequestMethod("HEAD");
      int code=connection.getResponseCode(); String next=connection.getHeaderField("Location"); connection.disconnect();
      System.out.println("OFFICIAL_TLS " + uri.getHost() + " " + code);
      if (code==200) return;
      if ((code==301 || code==302 || code==303 || code==307 || code==308) && next!=null) { uri=uri.resolve(next); continue; }
      throw new Exception("官方 TLS 探测 HTTP 失败");
    }
    throw new Exception("官方重定向次数超限");
  }
  public static void main(String[] args) {
    try {
      for (String key: new String[]{"networkaddress.cache.ttl","networkaddress.cache.negative.ttl","networkaddress.cache.stale.ttl"}) if (!"0".equals(java.security.Security.getProperty(key))) throw new Exception("任务 DNS 缓存策略失败");
      try { InetAddress.getByName("bettbox-unapproved.invalid"); throw new Exception("DNS 闭包失败"); } catch (UnknownHostException expected) {}
      for (String host:allowed) { try { InetAddress.getByName(host); throw new Exception("官方主机直接解析未被拒绝"); } catch (UnknownHostException expected) {} }
      for (InetAddress address:InetAddress.getAllByName("localhost")) if (!address.isLoopbackAddress()) throw new Exception("本机 localhost 解析越出回环");
      try (ServerSocket server=new ServerSocket(0,1,InetAddress.getByName("localhost")); Socket client=new Socket("localhost",server.getLocalPort()); Socket accepted=server.accept()) {}
      // 仅检查选择器，不发送这些未批准或明文目标的请求。
      for (String input:new String[]{"http://8.8.8.8/","http://bettbox-unapproved.invalid/","https://8.8.8.8/","https://bettbox-unapproved.invalid/"}) verifyProxy(new URI(input));
      for (String arg:args) check(arg);
    } catch (Exception error) { System.err.println("官方 Java TLS 或 DNS 边界探测失败"); System.exit(1); }
  }
}
'''


def prepare_files(home: Path, proxy_port: int) -> Path:
    if type(proxy_port) is not int or not 1 <= proxy_port <= 65535:
        raise NetworkError("任务代理端口无效")
    (home / "official-dependency.hosts").write_text("127.0.0.1 localhost\n::1 localhost\n")
    security = home / "dns-cache.security"
    # 单等号追加安全属性，只关闭任务 DNS 缓存，不替换 TLS 信任或算法策略。
    security.write_text("networkaddress.cache.ttl=0\nnetworkaddress.cache.negative.ttl=0\nnetworkaddress.cache.stale.ttl=0\n")
    source = home / "DependencyProbe.java"
    source.write_text(JAVA_PROBE.replace("HOST_LIST", ','.join(json.dumps(host) for host in HOSTS)).replace("PROXY_PORT", str(proxy_port)))
    init = home / "init.d/task-network.gradle"
    init.parent.mkdir()
    literal = "'" + str(home / 'official-dependency.hosts').replace('\\', '\\\\').replace("'", "\\'") + "'"
    init.write_text("// 实际 Gradle JVM 必须使用任务代理及仅 localhost 的 DNS 闭包。\n" +
                   "['http','https'].each { protocol -> if (System.getProperty(protocol + '.proxyHost') != '127.0.0.1' || System.getProperty(protocol + '.proxyPort') != '" + str(proxy_port) + "') throw new GradleException('任务 HTTP 与 HTTPS 代理未注入实际 Gradle JVM') }\n" +
                   "if (System.getProperty('http.nonProxyHosts') != '' || System.getProperty('java.net.useSystemProxies') != 'false') throw new GradleException('任务代理禁止绕过策略未生效')\n" +
                   "if (System.getProperty('jdk.net.hosts.file') != " + literal + ") throw new GradleException('任务 DNS 映射未注入实际 Gradle JVM')\n" +
                   "if (['networkaddress.cache.ttl','networkaddress.cache.negative.ttl','networkaddress.cache.stale.ttl'].any { java.security.Security.getProperty(it) != '0' }) throw new GradleException('任务 DNS 缓存策略未生效')\n" +
                   "try { java.net.InetAddress.getByName('bettbox-unapproved.invalid'); throw new GradleException('未知主机未被拒绝') } catch (java.net.UnknownHostException expected) {}\n" +
                   "[" + ','.join(json.dumps(host) for host in HOSTS) + "].each { host -> try { java.net.InetAddress.getByName(host); throw new GradleException('官方主机直接解析未被拒绝') } catch (java.net.UnknownHostException expected) {} }\n" +
                   "if (!java.net.InetAddress.getAllByName('localhost').every { it.isLoopbackAddress() }) throw new GradleException('本机 localhost 解析越出回环')\n" +
                   "println('BETTBOX_TASK_DNS_VERIFIED')\n")
    return source


def probe_urls(root: Path) -> tuple[str, ...]:
    wrapper = (root / "android/gradle/wrapper/gradle-wrapper.properties").read_text()
    values = re.findall(r"^distributionUrl=(.+)$", wrapper, re.M)
    if len(values) != 1:
        raise NetworkError("Gradle 官方分发入口缺失")
    distribution = values[0].replace('\\:', ':')
    checked_url(distribution)
    return ("https://plugins.gradle.org/m2/org/gradle/kotlin/gradle-kotlin-dsl-plugins/5.2.0/gradle-kotlin-dsl-plugins-5.2.0.pom",
            "https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/2.2.20/kotlin-gradle-plugin-2.2.20.pom",
            distribution)


class NetworkLease:
    """任务专用透明 CONNECT；不缓存 DNS，不接触 TLS 明文或证书。"""

    def __init__(self, home: Path, deadline: float):
        self.home, self.deadline = home, deadline
        self.proxy_port = 0
        self._failure = False
        self._stop = threading.Event()
        self._workers = DohWorkers()
        self._lock = threading.Lock()
        self._sockets: set[socket.socket] = set()
        self._threads: list[threading.Thread] = []
        # 长 TCP 转发与 DNS/连接阶段分开限流：33线程、12排队、最多6查询子进程。
        # 32条relay的双向缓冲上限16MiB；达到真实容量后仍可能有界拒绝。
        self._resolution_slots = threading.BoundedSemaphore(6)
        self._queue: queue.Queue = queue.Queue(maxsize=12)
        self._listener: socket.socket | None = None
        self.history: list[dict[str, object]] = []
        self._event_counts = {name: 0 for name in ('overload', 'queue-expired', 'upstream-unavailable',
                                                  'header-timeout', 'header-too-large', 'header-malformed', 'target-outside-allowlist',
                                                  'relay-failed', 'resolution-slot-expired')}
        self._event_summary: dict[str, object] | None = None

    def _publish_events(self) -> None:
        with self._lock:
            if self._event_summary is None:
                self._event_summary = {'category': 'proxy-events', 'counts': self._event_counts}
                self.history.append(self._event_summary)

    def _event(self, name: str) -> None:
        if name not in self._event_counts:
            raise NetworkError("代理诊断事件越出固定范围")
        self._publish_events()
        with self._lock:
            self._event_counts[name] += 1

    def _track(self, stream: socket.socket) -> None:
        with self._lock:
            if self._stop.is_set():
                stream.close()
                raise NetworkError("任务代理已取消")
            self._sockets.add(stream)

    def _drop(self, stream: socket.socket) -> None:
        try:
            stream.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass  # 已关闭或尚未连接的 owned socket 同样需要回收。
        stream.close()
        with self._lock:
            self._sockets.discard(stream)

    def start(self) -> None:
        self.check()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._track(listener)
        try:
            listener.bind(('127.0.0.1', 0))
            listener.listen(12)
            listener.settimeout(.2)
            self.proxy_port = listener.getsockname()[1]
            self._listener = listener
            for index in range(32):
                self._threads.append(threading.Thread(target=self._serve, name=f'bettbox-connect-{index}'))
            self._threads.append(threading.Thread(target=self._accept, name='bettbox-connect-accept'))
            for thread in self._threads:
                thread.start()
        except Exception:
            self._failure = True
            self.close()
            raise NetworkError("任务代理启动失败") from None

    def _accept(self) -> None:
        while not self._stop.is_set() and time.monotonic() < self.deadline:
            try:
                client, _ = self._listener.accept()
                client.settimeout(.2)
                self._track(client)
                try:
                    self._queue.put_nowait((client, time.monotonic()))
                except queue.Full:
                    self._event('overload')
                    # 普通并发超限只拒绝该连接，允许客户端有界重试，不标记未知目标。
                    try:
                        client.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n')
                    except OSError:
                        pass  # 过载拒绝期间客户端退出不构成全任务网络故障。
                    finally:
                        self._drop(client)
            except socket.timeout:
                continue
            except OSError:
                if not self._stop.is_set():
                    self._failure = True
                return
            except NetworkError:
                return

    def _header(self, client: socket.socket, accepted: float) -> tuple[str, bytes]:
        data = bytearray()
        end = min(self.deadline, accepted + 15)
        while b'\r\n\r\n' not in data:
            self.check()
            if time.monotonic() >= end:
                raise HeaderError("header-timeout")
            try:
                part = client.recv(4096)
            except socket.timeout:
                continue
            if not part:
                raise EOFError()
            data.extend(part)
            marker = data.find(b'\r\n\r\n')
            if marker < 0 and len(data) >= 4096:
                raise HeaderError("header-too-large")
        return connect_host(bytes(data))

    def _address_connect(self, address: str, end: float) -> socket.socket:
        stream = socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM)
        self._track(stream)
        try:
            stream.setblocking(False)
            code = stream.connect_ex((address, 443))
            if code not in (0, errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY):
                raise OSError()
            while code != 0:
                self.check()
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError()
                with selectors.DefaultSelector() as selector:
                    selector.register(stream, selectors.EVENT_WRITE)
                    if not selector.select(min(.2, remaining)):
                        continue
                code = stream.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if code != 0:
                    raise OSError()
            if time.monotonic() >= end:
                raise TimeoutError()
            return stream
        except BaseException:
            self._drop(stream)
            raise

    def _upstream(self, host: str, *, deadline: float | None = None) -> socket.socket:
        end = min(self.deadline, deadline if deadline is not None else float('inf'), time.monotonic() + 30)
        for _ in range(3):
            for kind in (1, 28):
                answer = query(host, kind, deadline=end, workers=self._workers)
                for record in answer['records']:
                    address = ipaddress.ip_address(record['address'])
                    ttl, expiry = record['ttl'], record['expires_monotonic']
                    if not address.is_global or address.version != (4 if kind == 1 else 6) \
                            or type(ttl) is not int or not 0 <= ttl <= 86400 \
                            or expiry != answer['queried_monotonic'] + ttl:
                        raise NetworkError("DoH 连接记录无效")
                    if ttl and time.monotonic() >= expiry:
                        continue
                    # TTL0 不入缓存，只把当前回答用于这一次立即连接；没有未来有效期声明。
                    connect_end = min(end, time.monotonic() + 10, expiry if ttl else end)
                    try:
                        upstream = self._address_connect(str(address), connect_end)
                    except (OSError, TimeoutError):
                        if ttl == 0:
                            break  # TTL0 回答只用于一次立即连接尝试，不复用到另一地址。
                        continue
                    if ttl and time.monotonic() >= expiry:
                        self._drop(upstream)
                        continue
                    with self._lock:
                        if len(self.history) >= 9999:
                            self._drop_unlocked(upstream)
                            raise NetworkError("任务代理连接总量预算耗尽")
                        self.history.append({'host': host, 'address': str(address), 'ttl': ttl,
                                             'fetched_at': answer['fetched_at'], 'resolver': DOH_ENDPOINT,
                                             'source': SOURCES[host], 'address_ttl': record['address_ttl'],
                                             'cname_ttls': record['cname_ttls'],
                                             'queried_monotonic': answer['queried_monotonic'],
                                             'received_monotonic': answer['received_monotonic'],
                                             'expires_monotonic': expiry,
                                             'category': 'fresh-single-use' if ttl == 0 else 'tcp-connected-before-expiry'})
                    return upstream
            if time.monotonic() >= end:
                break
        raise NetworkError("官方地址在有界解析与连接期间不可用")

    def _drop_unlocked(self, stream: socket.socket) -> None:
        # 仅在持有注册表锁时调用，避免再次获取同一把锁。
        stream.close()
        self._sockets.discard(stream)

    def _relay(self, client: socket.socket, upstream: socket.socket, initial: bytes) -> None:
        streams = (client, upstream)
        peers = {client: upstream, upstream: client}
        pending = {client: bytearray(), upstream: bytearray(initial)}
        eof = set()
        shut = set()
        last = time.monotonic()
        for stream in streams:
            stream.setblocking(False)
        with selectors.DefaultSelector() as selector:
            while not self._stop.is_set():
                self.check()
                if time.monotonic() - last >= 30:
                    return
                for stream in streams:
                    # 缓冲排空后传播半关闭，另一方向继续转发直至 EOF。
                    if peers[stream] in eof and not pending[stream] and stream not in shut:
                        stream.shutdown(socket.SHUT_WR)
                        shut.add(stream)
                if len(eof) == 2 and not any(pending.values()):
                    return
                for key in list(selector.get_map().values()):
                    selector.unregister(key.fileobj)
                for stream in streams:
                    events = 0
                    if stream not in eof and len(pending[peers[stream]]) < 262144:
                        events |= selectors.EVENT_READ
                    if pending[stream]:
                        events |= selectors.EVENT_WRITE
                    if events:
                        selector.register(stream, events)
                for key, events in selector.select(.2):
                    stream = key.fileobj
                    if events & selectors.EVENT_READ:
                        try:
                            data = stream.recv(min(65536, 262144 - len(pending[peers[stream]])))
                        except BlockingIOError:
                            data = None
                        if data:
                            pending[peers[stream]].extend(data)
                            last = time.monotonic()
                        elif data == b'':
                            eof.add(stream)
                    if events & selectors.EVENT_WRITE:
                        try:
                            count = stream.send(pending[stream])
                        except BlockingIOError:
                            count = 0
                        if count:
                            del pending[stream][:count]
                            last = time.monotonic()

    def _serve(self) -> None:
        while not self._stop.is_set() and time.monotonic() < self.deadline:
            try:
                client, accepted = self._queue.get(timeout=.2)
            except queue.Empty:
                continue
            upstream = None
            stage = 'header-malformed'
            try:
                if time.monotonic() - accepted >= 15:
                    self._event('queue-expired')
                    client.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n')
                    continue
                host, initial = self._header(client, accepted)
                stage = 'upstream-unavailable'
                # 等待解析slot和真正查询/连接共用30秒绝对期限，获取slot后不重置。
                end = min(self.deadline, time.monotonic() + 30)
                acquired = False
                while not acquired and time.monotonic() < end:
                    self.check()
                    acquired = self._resolution_slots.acquire(timeout=max(.001, min(.2, end - time.monotonic())))
                if not acquired:
                    self._event('resolution-slot-expired')
                    client.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n')
                    continue
                try:
                    upstream = self._upstream(host, deadline=end)
                finally:
                    self._resolution_slots.release()
                stage = 'relay-failed'
                client.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                self._relay(client, upstream, initial)
            except HeaderError as error:
                if not self._stop.is_set() and not self._failure:
                    self._event(error.category)
                    if error.category == 'header-timeout':
                        # 单连接慢请求只返回408；总体截止仍由check统一拒绝。
                        try:
                            client.sendall(b'HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n')
                        except OSError:
                            pass  # 客户端已退出不影响其它已授权连接。
                    else:
                        self._failure = True
            except NetworkError:
                if not self._stop.is_set() and not self._failure:
                    if time.monotonic() < self.deadline:
                        self._event(stage)
                    self._failure = True
            except (OSError, EOFError):
                pass  # 客户端取消或已关闭的 owned socket 不输出任何传输正文。
            except Exception:
                if not self._stop.is_set():
                    self._failure = True
            finally:
                if upstream is not None:
                    self._drop(upstream)
                self._drop(client)
                self._queue.task_done()

    def check(self) -> None:
        if self._stop.is_set() or self._failure or time.monotonic() >= self.deadline:
            raise NetworkError("任务代理失败、取消或时间预算耗尽")

    def close(self) -> bool:
        self._stop.set()
        with self._lock:
            streams = tuple(self._sockets)
        for stream in streams:
            self._drop(stream)
        verified = self._workers.close()
        end = time.monotonic() + 3
        for thread in self._threads:
            if thread.ident is not None:
                thread.join(timeout=max(.001, end - time.monotonic()))
        self._publish_events()
        with self._lock:
            return verified and not self._sockets and all(not thread.is_alive() for thread in self._threads)


def _worker_main() -> int:
    """子进程仅返回公开 DNS 记录；异常正文和 HTTP 响应不回传。"""
    try:
        raw = sys.stdin.buffer.read(1025)
        if len(raw) > 1024:
            return 1
        request = json.loads(raw)
        host, kind, timeout = request['host'], request['type'], request['timeout']
        if host not in HOSTS or kind not in (1, 28) or type(timeout) not in (int, float) \
                or not math.isfinite(timeout) or not 0 < timeout <= 10:
            return 1
        result = _query_direct(host, kind, timeout=timeout)
        sys.stdout.write(json.dumps(result))
        return 0
    except Exception:
        return 1


if __name__ == '__main__':
    if sys.argv[1:] == ['--doh-worker']:
        sys.exit(_worker_main())
    print(json.dumps(plan(), ensure_ascii=False))
