// Command localderp is the browser spike's stand-in for the Tailscale relay
// fleet, so the end-to-end run needs no internet: one DERP server (TLS with a
// throwaway self-signed certificate, WebSocket-upgradable because a browser
// can reach DERP no other way), one STUN responder for the native side's
// endpoint discovery, and a plain-HTTP /derpmap handing out a one-region map
// that points back at itself with InsecureForTests set.
//
// InsecureForTests is what makes the self-signed certificate workable on
// both ends: derphttp skips TLS verification for such a node, and the browser
// is launched with certificate errors ignored (Playwright's
// ignoreHTTPSErrors). The map endpoint itself is plain HTTP on purpose — the
// guest package fetches it with a verifying net/http client. Nothing here is
// production; a real deployment points at Tailscale's relays or a derper of
// its own (docs/self-hosted.md).
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stunserver"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

func main() {
	host := flag.String("host", "127.0.0.1", "IP the relay listens on and advertises")
	derpPort := flag.Int("derp-port", 0, "TLS+WebSocket DERP port (0 = ephemeral)")
	mapPort := flag.Int("map-port", 0, "plain-HTTP /derpmap port (0 = ephemeral)")
	stunPort := flag.Int("stun-port", 0, "UDP STUN port (0 = ephemeral)")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// DERP over TLS, WebSocket-capable.
	derp := derpserver.New(key.NewNode(), log.Printf)
	defer derp.Close()
	derpLn, err := net.Listen("tcp", net.JoinHostPort(*host, fmt.Sprint(*derpPort)))
	if err != nil {
		log.Fatalf("derp listen: %v", err)
	}
	cert, err := selfSigned(*host)
	if err != nil {
		log.Fatalf("self-signed cert: %v", err)
	}
	mux := http.NewServeMux()
	mux.Handle("/derp", derpserver.AddWebSocketSupport(derp, derpserver.Handler(derp)))
	derpSrv := &http.Server{
		Handler: mux,
		// HTTP/1.1 only: the DERP protocol and the WebSocket upgrade both
		// need it, and the HTTP/2 negotiation would otherwise win the ALPN.
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, NextProtos: []string{"http/1.1"}},
	}
	go func() {
		if err := derpSrv.ServeTLS(derpLn, "", ""); err != nil && err != http.ErrServerClosed {
			log.Printf("derp serve: %v", err)
		}
	}()
	defer derpSrv.Close()

	// STUN, so the native sharer's netcheck can learn its endpoints (the
	// browser cannot use it, and doesn't try).
	stun := stunserver.New(ctx)
	if err := stun.Listen(net.JoinHostPort(*host, fmt.Sprint(*stunPort))); err != nil {
		log.Fatalf("stun listen: %v", err)
	}
	go func() {
		if err := stun.Serve(); err != nil && ctx.Err() == nil {
			log.Printf("stun serve: %v", err)
		}
	}()
	stunAddr := stun.LocalAddr().(*net.UDPAddr)
	derpAddr := derpLn.Addr().(*net.TCPAddr)

	dm := &tailcfg.DERPMap{
		Regions: map[int]*tailcfg.DERPRegion{
			1: {
				RegionID:   1,
				RegionCode: "local",
				RegionName: "localderp",
				Nodes: []*tailcfg.DERPNode{{
					Name:             "local",
					RegionID:         1,
					HostName:         *host,
					IPv4:             *host,
					IPv6:             "none",
					STUNPort:         stunAddr.Port,
					DERPPort:         derpAddr.Port,
					InsecureForTests: true,
					STUNTestIP:       *host,
				}},
			},
		},
	}
	mapJSON, err := json.Marshal(dm)
	if err != nil {
		log.Fatalf("derpmap json: %v", err)
	}

	// The map endpoint: plain HTTP, CORS-open so a page from any origin can
	// read it too (the spike page doesn't need to — the token embeds the
	// region — but a future page fetching an unresolved token's map will).
	mapMux := http.NewServeMux()
	mapMux.HandleFunc("/derpmap", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		w.Write(mapJSON)
	})
	mapLn, err := net.Listen("tcp", net.JoinHostPort(*host, fmt.Sprint(*mapPort)))
	if err != nil {
		log.Fatalf("map listen: %v", err)
	}
	mapSrv := &http.Server{Handler: mapMux}
	go func() {
		if err := mapSrv.Serve(mapLn); err != nil && err != http.ErrServerClosed {
			log.Printf("map serve: %v", err)
		}
	}()
	defer mapSrv.Close()

	// The one line a harness parses. Unbuffered stdout on purpose.
	fmt.Printf("LOCALDERP derpmap=http://%s/derpmap derp=%s stun=%s\n", mapLn.Addr(), derpAddr, stunAddr)
	os.Stdout.Sync()

	<-ctx.Done()
}

// selfSigned mints a throwaway ECDSA certificate for host, valid for a day.
func selfSigned(host string) (tls.Certificate, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "localderp"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
	}
	if ip := net.ParseIP(host); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}, nil
}
