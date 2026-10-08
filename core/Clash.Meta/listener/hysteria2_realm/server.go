package hysteria2_realm

import (
	"context"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/ech"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp"

	"github.com/metacubex/http"
	"github.com/metacubex/tls"
)

type Listener struct {
	closed      bool
	config      LC.Hysteria2RealmServer
	listeners   []net.Listener
	httpServers []*http.Server
	server      *server
	cancel      func()
	closeMu     sync.Mutex
	admissionMu sync.Mutex
	workers     sync.WaitGroup
	handlers    sync.WaitGroup
}

const (
	DefaultMaxRealms        = 65536
	DefaultMaxRealmsPerIP   = 4
	DefaultRealmNamePattern = defaultRealmNamePattern
)

func DefaultALPN() []string { return []string{"h2", "http/1.1"} }

func New(config LC.Hysteria2RealmServer, lc C.InboundListenConfig, tunnel C.Tunnel, additions ...inbound.Addition) (result *Listener, resultErr error) {
	if len(additions) == 0 {
		additions = []inbound.Addition{
			inbound.WithInName("DEFAULT-HYSTERIA2-REALM"),
			inbound.WithSpecialRules(""),
		}
	}

	pat, err := regexp.Compile(config.RealmNamePattern)
	if err != nil {
		return nil, fmt.Errorf("invalid realm name pattern %q: %v", config.RealmNamePattern, err)
	}
	s := newServer(serverConfig{
		realmToken:     config.Token,
		maxRealms:      config.MaxRealms,
		maxRealmsPerIP: config.MaxRealmsPerIP,
		proxyHeader:    config.TrustedProxyHeader,
		realmIDPattern: pat,
	})

	tlsConfig := &tls.Config{Time: ntp.Now}
	if config.Certificate != "" && config.PrivateKey != "" {
		certLoader, err := ca.NewTLSKeyPairLoader(config.Certificate, config.PrivateKey)
		if err != nil {
			return nil, err
		}
		tlsConfig.GetCertificate = func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			return certLoader()
		}

		if config.EchKey != "" {
			err = ech.LoadECHKey(config.EchKey, tlsConfig)
			if err != nil {
				return nil, err
			}
		}
	}
	tlsConfig.ClientAuth = ca.ClientAuthTypeFromString(config.ClientAuthType)
	if len(config.ClientAuthCert) > 0 {
		if tlsConfig.ClientAuth == tls.NoClientCert {
			tlsConfig.ClientAuth = tls.RequireAndVerifyClientCert
		}
	}
	if tlsConfig.ClientAuth == tls.VerifyClientCertIfGiven || tlsConfig.ClientAuth == tls.RequireAndVerifyClientCert {
		pool, err := ca.LoadCertificates(config.ClientAuthCert)
		if err != nil {
			return nil, err
		}
		tlsConfig.ClientCAs = pool
	}

	sl := &Listener{config: config, server: s}
	// 多地址错误不丢弃前面已经绑定的真实资源；未知关闭保留对象责任。
	defer func() {
		if resultErr != nil {
			if cleanupErr := sl.Close(); cleanupErr != nil {
				result = sl
				resultErr = errors.Join(resultErr, cleanupErr)
			}
		}
	}()

	for _, addr := range strings.Split(config.Listen, ",") {
		addr := addr

		//TCP
		l, err := lc.Listen(context.Background(), "tcp", addr)
		if err != nil {
			return nil, err
		}
		if tlsConfig.GetCertificate != nil {
			l = tls.NewListener(l, tlsConfig)
		}
		sl.listeners = append(sl.listeners, l)

		srv := &http.Server{
			Handler:           sl.trackHandler(s.routes()),
			ReadHeaderTimeout: 10 * time.Second,
		}

		sl.httpServers = append(sl.httpServers, srv)
	}
	// 所有绑定通过后才发布服务，失败构造不产生可用的部分服务。
	for i, srv := range sl.httpServers {
		lis := sl.listeners[i]
		sl.workers.Add(1)
		go func(srv *http.Server, lis net.Listener) {
			defer sl.workers.Done()
			_ = srv.Serve(lis)
		}(srv, lis)
	}
	ctx, cancel := context.WithCancel(context.Background())
	sl.cancel = cancel
	sl.workers.Add(1)
	go func() {
		defer sl.workers.Done()
		s.reaper(ctx)
	}()

	return sl, nil
}

func (l *Listener) Close() error {
	if l == nil {
		return nil
	}
	l.closeMu.Lock()
	defer l.closeMu.Unlock()
	l.admissionMu.Lock()
	l.closed = true
	l.admissionMu.Unlock()
	if l.cancel != nil {
		l.cancel()
	}
	var errs []error
	// Server.Close 在底层关闭失败后仍会等待 Accept；先确认实际 socket 已关闭。
	for _, lis := range l.listeners {
		if err := realmCloseError(lis.Close()); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) != 0 {
		return errors.Join(errs...)
	}
	for _, srv := range l.httpServers {
		if err := realmCloseError(srv.Close()); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) != 0 {
		return errors.Join(errs...)
	}
	l.workers.Wait()
	l.handlers.Wait()
	// 任务完成后移除会话，避免迟到处理器在清理后重新登记。
	l.server.mu.Lock()
	for _, sess := range l.server.sessions {
		l.server.removeSessionLocked(sess)
	}
	l.server.mu.Unlock()
	return nil
}

// 聚合错误只移除已关闭分支；其中任何真实失败都必须保留。
func realmCloseError(err error) error {
	if err == nil || err == net.ErrClosed {
		return nil
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		children := joined.Unwrap()
		if len(children) == 0 {
			return err
		}
		var remaining []error
		for _, child := range children {
			if child = realmCloseError(child); child != nil {
				remaining = append(remaining, child)
			}
		}
		return errors.Join(remaining...)
	}
	if wrapped, ok := err.(interface{ Unwrap() error }); ok {
		if child := wrapped.Unwrap(); child != nil && realmCloseError(child) == nil {
			return nil
		}
	}
	return err
}

func (l *Listener) trackHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.admissionMu.Lock()
		if l.closed {
			l.admissionMu.Unlock()
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		l.handlers.Add(1)
		l.admissionMu.Unlock()
		defer l.handlers.Done()
		next.ServeHTTP(w, r)
	})
}

func (l *Listener) Config() string {
	return l.config.String()
}

func (l *Listener) AddrList() (addrList []net.Addr) {
	for _, lis := range l.listeners {
		addrList = append(addrList, lis.Addr())
	}
	return
}

func debugf(format string, v ...any) {
	log.Debugln("[RealmServer] "+format, v...)
}
