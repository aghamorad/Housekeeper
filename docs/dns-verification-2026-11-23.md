# DNS verification — 23 November 2026

Every address below was queried from Morad's Mac (Tehran, Iran) with:

```bash
dig +time=2 +tries=1 @<address> example.com A +short
```

`dig` is macOS's DNS lookup tool. `@<address>` sends the question to that specific
resolver instead of the Mac's configured one. A printed IPv4 address means the
resolver answered; `TIMEOUT` means it did not answer from this connection.

## Anti-sanction resolvers

| Provider | Addresses | Result | Latency |
|---|---|---|---|
| Shecan | 178.22.122.100 / 185.51.200.2 | answered | ~250 ms total, ~25 ms resolver |
| Begzar | 185.55.226.26 / 185.55.225.25 | answered | ~23 ms |
| Shelter | 94.103.125.158 / 94.103.125.157 | answered | ~26 ms |
| Beshkan | 181.41.194.177 / 181.41.194.186 (also 181.41.197.12 / .13) | answered | ~23 ms |
| Electro Public | 194.5.193.5 / 194.5.193.6 | answered | — |
| Electro (ISP) | 78.157.42.100 / 78.157.42.101 | answered | ~24 ms |
| 403.online | 10.202.10.202 / 10.202.10.102 | TIMEOUT (carrier-only) | — |
| Radar | 10.202.10.10 / 10.202.10.11 | TIMEOUT (carrier-only) | — |
| HostIran | 172.29.0.100 / 172.29.2.100 | TIMEOUT (carrier-only) | — |
| Vanilla | 10.139.177.21 / 10.139.177.22 | TIMEOUT (carrier-only) | — |

The `10.x` and `172.29.x` addresses are private ranges served inside specific
Iranian ISPs. They are kept in the app and labelled carrier-only, because they
work for a reader on those ISPs and are not evidence of a dead service.

## Global resolvers checked alongside them

| Provider | Addresses | Result |
|---|---|---|
| Cloudflare | 1.1.1.1 / 1.0.0.1 | answered |
| Cloudflare Family | 1.1.1.3 / 1.0.0.3 | answered |
| Google | 8.8.8.8 / 8.8.4.4 | answered |
| Quad9 | 9.9.9.9 / 149.112.112.112 | answered |
| Mullvad | 194.242.2.2 / 194.242.2.3 | answered |
| NextDNS | 45.90.28.0 / 45.90.30.0 | answered |
| Control D | 76.76.2.0 / 76.76.10.0 | answered |
| DNS0.eu | 193.110.81.0 / 185.253.5.0 | answered |
| Yandex | 77.88.8.8 / 77.88.8.1 | answered |
| AdGuard Family | 94.140.14.15 / 94.140.15.16 | answered |

## What this proves and what it does not

It proves the resolver answers DNS questions from this network. It does not prove
that every sanctioned site becomes usable: a resolver can return a reachable IP
while the site still refuses the request, and TLS certificates can fail through a
proxy. The app's own **Test** buttons measure latency, and the Route Sweep measures
whether traffic actually flows through a tunnel.
