-- QuackTail on a self-hosted Headscale control plane
-- https://github.com/juanfont/headscale
--
-- Headscale speaks the Tailscale control protocol; QuackScale uses the same
-- `control_url` + preauth key flow as `tailscale up --login-server`.
--
-- 1) On the Headscale server (or admin host):
--      headscale users create myuser
--      headscale preauthkeys create --user <USER_ID> --reusable --expiration 24h
--
-- 2) Export the key and your Headscale URL (must match server_url in config):
--      export HEADSCALE_URL='http://headscale.example.com:8080'
--      export HEADSCALE_PREAUTH_KEY='<key from headscale>'
--      export QUACK_TAILNET_TOKEN='shared-quack-secret'

LOAD quack;
LOAD quackscale;

CALL tailscale_up(
    hostname => 'analytics-duck-1',
    control_url => 'https://headscale.example.com',  -- same as Headscale server_url
    authkey => 'YOUR_HEADSCALE_PREAUTH_KEY',
    state_dir => '~/.local/share/duckdb/quackscale-headscale'
);

CALL quack_serve(
    quack_uri(),
    allow_other_hostname => true,
    token => quack_token()
);

CALL quack_discover();

-- Clients: same QUACK_TAILNET_TOKEN, ATTACH quack:<hostname>:9494 (DISABLE_SSL true for http-only labs)
