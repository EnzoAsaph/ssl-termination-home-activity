# SSL Termination + UFW — Home Activity

Home activity for the web infrastructure lab (web-01, web-02, lb-01):

1. **Configure HAProxy for SSL termination** on the load balancer, using a
   self-signed certificate.
2. **Set UFW rules on web-01 and web-02** so they accept plain-text HTTP
   **only from the load balancer**.

## How it works

```
                        HTTPS (TLS, self-signed cert)
        client ─────────────────────────────► lb-01 (HAProxy, :443)
                                                │  TLS is TERMINATED here
                                                │
                              plain HTTP :80    │    plain HTTP :80
                            ┌───────────────────┴───────────────────┐
                            ▼                                       ▼
                     web-01 (172.25.0.11)                web-02 (172.25.0.12)
                     UFW: port 80 allowed                UFW: port 80 allowed
                     ONLY from 172.25.0.10               ONLY from 172.25.0.10
```

- **SSL termination:** HAProxy on lb-01 binds `:443` with a self-signed
  cert (`bind *:443 ssl crt /etc/haproxy/certs/lb-01.pem`) and decrypts
  incoming HTTPS. Traffic to the backends travels as plain HTTP. The plain
  `:80` frontend 301-redirects everything to HTTPS.
- **Firewall:** on each web server, UFW defaults to *deny incoming*, allows
  SSH (so we can still manage the box), and allows port 80 **only** from the
  load balancer's IP `172.25.0.10`. Any other source hitting port 80 is
  dropped — combined with SSL termination, the only unencrypted hop is the
  private lb → web leg.

## Contents

- [`config/haproxy.cfg`](config/haproxy.cfg) — HAProxy config: HTTPS frontend
  terminating TLS, HTTP→HTTPS redirect, round-robin plain-HTTP backend to
  web-01/web-02 with health checks.
- [`scripts/setup-lb-ssl.sh`](scripts/setup-lb-ssl.sh) — installs HAProxy on
  lb-01, generates the self-signed cert (`openssl req -x509 ...`, bundled as
  cert+key in one PEM as HAProxy expects), deploys the config, validates it
  (`haproxy -c`), and restarts the service.
- [`scripts/setup-ufw-web.sh`](scripts/setup-ufw-web.sh) — installs UFW (and
  nginx if nothing serves :80 yet) on a web server and applies the rules:
  deny incoming by default, allow SSH, allow 80/tcp from 172.25.0.10 only.

## Usage

```bash
# lab environment up (web-01: ssh 2211, web-02: ssh 2212, lb-01: ssh 2210)
./scripts/setup-lb-ssl.sh          # lb-01: HAProxy + self-signed cert + SSL termination
./scripts/setup-ufw-web.sh 2211    # web-01: HTTP only from the LB
./scripts/setup-ufw-web.sh 2212    # web-02: HTTP only from the LB
```

> UFW inside a container needs the `NET_ADMIN` capability — if `ufw enable`
> fails, add `cap_add: [NET_ADMIN]` to the web services in the lab's
> `compose.yml` and re-create the containers.

## Verification

```bash
# 1. TLS is terminated at the LB with the self-signed cert (-k to accept it)
curl -k https://localhost:4443/
curl -kv https://localhost:4443/ 2>&1 | grep -E 'subject|issuer'   # CN=lb-01

# 2. Plain HTTP through the LB redirects to HTTPS
curl -i http://localhost:8082/        # HTTP/1.1 301 ... Location: https://...

# 3. Round-robin: alternates between web-01 and web-02
for i in 1 2 3 4; do curl -sk https://localhost:4443/; done

# 4. Web servers reject direct HTTP from anywhere but the LB
curl --max-time 5 http://localhost:8080/   # web-01: times out (blocked by UFW)
curl --max-time 5 http://localhost:8081/   # web-02: times out (blocked by UFW)
docker exec lb-01 curl -s http://172.25.0.11/   # from the LB: works
docker exec lb-01 curl -s http://172.25.0.12/   # from the LB: works
```

## Status

- [x] HAProxy SSL-termination config written (self-signed cert, HTTPS :443,
      HTTP→HTTPS redirect, plain-HTTP round-robin backend)
- [x] UFW script written (web-01/web-02 accept HTTP only from 172.25.0.10)
- [ ] Applied on live lab servers — pending Docker Desktop install on host
- [ ] End-to-end verification (curl checks above)
