package http

import (
	"context"
	"net"
	"strings"

	"github.com/metacubex/mihomo/adapter/inbound"
	N "github.com/metacubex/mihomo/common/net"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/socks5"

	"github.com/metacubex/http"
	"github.com/metacubex/tls"
)

func isUpgradeRequest(req *http.Request) bool {
	for _, header := range req.Header["Connection"] {
		for _, elm := range strings.Split(header, ",") {
			if strings.EqualFold(strings.TrimSpace(elm), "Upgrade") {
				return true
			}
		}
	}

	return false
}

func handleUpgrade(conn net.Conn, request *http.Request, tunnel C.Tunnel, additions ...inbound.Addition) {
	handleUpgradeContext(context.Background(), false, conn, request, tunnel, additions...)
}

// 专用入口取消时关闭内部pipe；原入口不净化Trailer且维持原行为。
func handleUpgradeBlindWithContext(ctx context.Context, conn net.Conn, request *http.Request, tunnel C.Tunnel, additions ...inbound.Addition) {
	handleUpgradeContext(ctx, true, conn, request, tunnel, additions...)
}

func handleUpgradeContext(ctx context.Context, blind bool, conn net.Conn, request *http.Request, tunnel C.Tunnel, additions ...inbound.Addition) {
	defer conn.Close()

	removeProxyHeaders(request.Header)
	removeExtraHTTPHostPort(request)

	address := request.Host
	if _, _, err := net.SplitHostPort(address); err != nil {
		address = net.JoinHostPort(address, "80")
	}

	dstAddr := socks5.ParseAddr(address)
	if dstAddr == nil {
		return
	}

	left, right := N.Pipe()
	stopCancel := context.AfterFunc(ctx, func() { _ = left.Close(); _ = right.Close() })
	defer stopCancel()

	routeConn, routeMetadata := inbound.NewHTTP(dstAddr, conn, right, additions...)
	startHTTPRoute(tunnel, routeConn, routeMetadata)

	var bufferedLeft *N.BufferedConn
	if request.TLS != nil {
		tlsConn := tls.Client(left, &tls.Config{
			ServerName: request.URL.Hostname(),
		})

		ctx, cancel := context.WithTimeout(context.Background(), C.DefaultTLSTimeout)
		defer cancel()
		if tlsConn.HandshakeContext(ctx) != nil {
			_ = left.Close()
			return
		}

		bufferedLeft = N.NewBufferedConn(tlsConn)
	} else {
		bufferedLeft = N.NewBufferedConn(left)
	}
	defer func() {
		_ = bufferedLeft.Close()
	}()

	err := request.Write(bufferedLeft)
	if err != nil {
		return
	}

	resp, err := http.ReadResponse(bufferedLeft.Reader(), request)
	if err != nil {
		return
	}

	if blind {
		original := resp
		resp = new(http.Response)
		*resp = *original
		resp.Header = original.Header.Clone()
		resp.Trailer = nil
		for key := range resp.Header {
			if blindAuthField(key) || strings.EqualFold(key, "Trailer") {
				delete(resp.Header, key)
			}
		}
	}
	removeProxyHeaders(resp.Header)

	err = resp.Write(conn)
	if err != nil {
		return
	}

	if resp.StatusCode == http.StatusSwitchingProtocols {
		N.Relay(bufferedLeft, conn)
	}
}
