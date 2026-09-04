# clickhouse-mcp-tunnel

<img width="2040" height="740" alt="image" src="https://github.com/user-attachments/assets/0c3279cd-00d4-4972-b453-aa7ea41a60d0" />

Run the [ClickHouse MCP server](https://github.com/ClickHouse/mcp-clickhouse) against a
ClickHouse Cloud service that is only reachable over AWS PrivateLink.

The MCP server itself assumes it can open a socket to your database. When the service sits
behind a VPC endpoint, it can't. This wraps it with the missing pieces:

- **A keyless tunnel.** AWS SSM port-forwards through a bastion to the endpoint's HTTPS
  port. No SSH, no key, no inbound access — just AWS credentials.
- **SNI that actually resolves.** ClickHouse Cloud terminates TLS at a shared endpoint and
  routes by SNI. A client pointed at `localhost` sends the wrong name and the connection is
  dropped with an opaque TLS error. The wrapper passes the real endpoint hostname as
  `CLICKHOUSE_SERVER_HOST_NAME`, so certificate verification stays **on**.
- **Credentials in the keychain**, not in your MCP client's config file.
- **A tunnel that knows when it's dead.** A stale SSM session keeps its local socket bound
  and fails on the first byte, so a port check reports a healthy tunnel that isn't. Liveness
  is an end-to-end request, and a bound-but-broken listener is recycled rather than trusted.

## Install

```sh
git clone https://github.com/dankelleher/clickhouse-mcp-tunnel
cd clickhouse-mcp-tunnel
./install.sh
```

`install.sh` links the two scripts into `~/.local/bin`, asks for your site's details, writes
a profile, and optionally registers the server with Claude Code. Then:

```sh
clickhouse-mcp-tunnel --set-credentials stg   # into the login keychain
clickhouse-mcp-tunnel --check stg             # proves it authenticates
```

`--check` runs `SELECT currentUser(), version()` and `SHOW DATABASES` through the tunnel, so
you get a straight yes/no instead of discovering a bad credential through a failing tool call.

Requires `aws` (v2), the [SSM Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
[`uv`](https://docs.astral.sh/uv/), and macOS for the keychain.

## Profiles

Site-specific details live in `~/.config/clickhouse-mcp-tunnel/<profile>.env`, outside this
repo. One profile per environment; give each its own `LOCAL_PORT` so several can be open at
once. See [`profiles/example.env`](profiles/example.env) for every key.

Point `REMOTE_HOST_SSM_PARAM` at an SSM parameter rather than pinning `REMOTE_HOST`, and a
re-provisioned service needs no edit here. Likewise, set `BASTION` to a `Name` tag rather
than an instance id and it survives the bastion being replaced.

## Usage

```sh
ch-tunnel stg              # foreground tunnel (Ctrl-C to close)
ch-tunnel --ensure stg     # idempotent background start
ch-tunnel --status stg     # up / broken / down
ch-tunnel --stop stg
```

You rarely need these: the MCP server calls `--ensure` itself on startup, and several
clients starting at once share one tunnel via a lock. If the tunnel isn't up the server
still starts and warns, so queries begin working the moment it appears — no client restart.

## Read-only by default

`CLICKHOUSE_ALLOW_WRITE_ACCESS` and `CLICKHOUSE_ALLOW_DROP` are both forced to `false`.
Treat that as a seatbelt, not a boundary: it's a flag in the MCP server, and the thing
driving it is a language model. **Grant the database user `SELECT` and nothing more**, so
the refusal comes from ClickHouse rather than from a client-side setting.

## Troubleshooting

MCP clients deliberately withhold server stderr, so a failure usually surfaces as nothing
more useful than `Connection closed`. The wrapper keeps its own copy:

```sh
tail ~/.cache/clickhouse-mcp-tunnel/<profile>-mcp.log
```

Two failures worth knowing about, both of which produce exactly that generic error:

- **`uv` refusing an interpreter.** Clients spawn the server from whatever directory they
  like. If that directory belongs to a project whose `requires-python` excludes 3.10, `uv`
  aborts. Hence `--no-project`.
- **Anything printed on stdout.** For a stdio MCP server, stdout *is* the JSON-RPC channel;
  one stray progress line corrupts the stream. Every diagnostic here goes to stderr, and it
  is worth preserving that if you modify the wrapper.

An opaque `SSL_ERROR_SYSCALL` against `localhost` almost always means SNI: the endpoint
closed the connection because the client sent the wrong server name.

## Tests

```sh
test/smoke.sh
```

Offline: syntax, profile validation, CLI surface, and a guard that no organisation's
hostnames, account ids or instance ids have been committed.

## Licence

MIT
