# MB1107 — IPv6 country lookups

The IRC WHOIS callback already passes the host to the asynchronous
country worker. The lookup formerly required an IPv4 result from
gethostbyname, so IPv6 literals and names with only an IPv6 address
returned N/A before the request to country.is.

An IPv6 literal is parsed and rendered through Socket without DNS. For
hostnames, one getaddrinfo call can return both families; the lookup
selects IPv4 when available, otherwise the first IPv6 answer without
an interface scope. Only the selected numeric IP enters the country API
path. An invalid colon-containing literal does not reach the resolver.
The IPv4 literal path retains its compatibility hooks.

The request still uses the existing verified HTTPS client and the same
timeout. The async worker and WHOIS reply routing are unchanged. Hidden
Undernet hosts continue to bypass both DNS and the provider.

The native fixture supplies actual packed socket addresses and intercepts
the resolver and HTTP client. It reproduces the old IPv6 failure, then
checks canonicalization, IPv6-only and dual-stack resolution, malformed
input, hidden hosts and failed HTTP or JSON. No external DNS or API call
is required to run it. No database or configuration change is needed.
