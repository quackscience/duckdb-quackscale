-- QuackTail on Headscale — Quack on loopback, Tailscale Serve exposes it on the tailnet.
--
-- 1) headscale preauth key + control URL (see examples in repo docs)
-- 2) export QUACK_TAILNET_TOKEN='shared-quack-secret'

LOAD quack;

CALL tailscale_up(
    hostname => 'analytics-duck-1',
    control_url => 'http://headscale.example.com:8080',
    authkey => 'YOUR_HEADSCALE_PREAUTH_KEY',
    state_dir => '/var/lib/duckdb/quackscale-headscale',
    ephemeral => true
);

-- Quack listens locally; tailscale_serve_local publishes port 9494 on the tailnet.
CALL quack_serve(
    'quack:127.0.0.1:9494',
    token => quack_token()
);
CALL tailscale_serve_local(port => 9494);

CALL quack_discover();

-- Clients: ATTACH quack:<hostname>.<your-base-domain>:9494 (DISABLE_SSL true for plain HTTP)
