package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestNormalizedSubscription(t *testing.T) {
	yamlBody := "defaults: &defaults {type: socks5, server: 127.0.0.1, port: 1080}\nproxies:\n - {<<: *defaults, name: '香港 A'}\n - {name: B, type: socks5, server: localhost, port: 1081}\nproxy-groups:\n - {name: 选择, type: select, proxies: ['香港 A', B]}\n"
	for _, body := range []string{yamlBody, "\ufeff" + yamlBody, base64.StdEncoding.EncodeToString([]byte(yamlBody))} {
		result := normalizedSubscription(normalizeInput{Body: body})
		if !result.OK || !strings.Contains(result.YAML, "香港 A") || !strings.Contains(result.YAML, "server:") {
			t.Fatalf("YAML/anchor/base64 normalization failed: %s", result.Error)
		}
	}
	links := "trojan://secret@example.com:443#test\nvless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=ws&path=%2F#vless"
	for _, body := range []string{links, base64.StdEncoding.EncodeToString([]byte(links))} {
		result := normalizedSubscription(normalizeInput{Body: body})
		if !result.OK || !strings.Contains(result.YAML, "trojan") || !strings.Contains(result.YAML, "vless") {
			t.Fatalf("link conversion failed: %s", result.Error)
		}
	}
	for _, body := range []string{"<html>login required</html>", yamlBody + " - invalid", "trojan://secret@example.com:443#test\nunsupported://bad", "proxies: [{name: A, type: invalid, server: localhost, port: 1}]", "proxies: [{name: A, type: socks5, server: localhost, port: 1}, {name: A, type: socks5, server: localhost, port: 2}]"} {
		result := normalizedSubscription(normalizeInput{Body: body})
		if result.OK {
			t.Fatalf("invalid input accepted: %s", body)
		}
	}
}

func TestNormalizedSubscriptionProvider(t *testing.T) {
	body := "proxy-providers:\n  remote: {type: http, url: 'https://example.com/sub'}\nproxy-groups:\n - {name: Select, type: select, use: [remote]}"
	result := normalizedSubscription(normalizeInput{Body: body})
	if !result.OK || len(result.Providers) != 1 {
		t.Fatalf("provider discovery: %+v", result)
	}
	result = normalizedSubscription(normalizeInput{Body: body, Providers: []providerPayload{{Name: "remote", Body: "proxies: [{name: A, type: socks5, server: localhost, port: 1080}]"}}})
	if !result.OK || !strings.Contains(result.YAML, "- A") || strings.Contains(result.YAML, "use:") {
		t.Fatalf("provider expansion: %+v", result)
	}
}
func TestSubscriptionCompatibility(t *testing.T) {
	links := "trojan://secret@example.com:443#test\nvless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=ws&path=%2F#vless"
	encoded := base64.RawURLEncoding.EncodeToString([]byte(links))
	encoded = encoded[:20] + " \r\n" + encoded[20:]
	if result := normalizedSubscription(normalizeInput{Body: encoded}); !result.OK {
		t.Fatal(result.Error)
	}
	body := `proxy-providers:
  first:
    type: inline
    override: {additional-prefix: "X-", skip-cert-verify: true}
    payload:
      - {name: HK1, type: socks5, server: localhost, port: 1080}
      - {name: US1, type: socks5, server: localhost, port: 1081}
proxy-groups:
  - {name: Auto, type: url-test, url: "http://www.gstatic.com/generate_204", include-all-providers: true, filter: "^(?!.*US).*"}
`
	result := normalizedSubscription(normalizeInput{Body: body})
	if !result.OK || !strings.Contains(result.YAML, "- X-HK1") || strings.Contains(result.YAML, "- X-US1") {
		t.Fatalf("provider/filter: %+v", result)
	}
	cycle := `proxies: [{name: A, type: socks5, server: localhost, port: 1080}]
proxy-groups: [{name: One, type: select, proxies: [Two]}, {name: Two, type: select, proxies: [One, A]}]`
	if result := normalizedSubscription(normalizeInput{Body: cycle}); result.OK {
		t.Fatal("cyclic groups accepted")
	}
	duplicate := `proxy-providers:
  one: {type: inline, payload: [{name: A, type: socks5, server: localhost, port: 1080}]}
  two: {type: inline, payload: [{name: A, type: socks5, server: localhost, port: 1081}]}`
	if result := normalizedSubscription(normalizeInput{Body: duplicate}); result.OK {
		t.Fatal("conflicting provider nodes accepted")
	}
}
