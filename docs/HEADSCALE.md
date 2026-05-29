## Docker (lab / CI)

Uses the [official Headscale container](https://headscale.net/stable/setup/install/container/) (`docker.io/headscale/headscale:0.28.0`) — **no custom images**.

`scripts/lib/headscale_ci.sh` starts it after checkout with config bind-mounts, on Docker network `quacktail-ci` with hostname alias **`headscale`**. Control URL: **`http://headscale:8080`**.

```sh
export HEADSCALE_CI_ROOT=$PWD
source scripts/lib/headscale_ci.sh
headscale_ci_start /tmp/headscale-data
./scripts/ci_headscale_smoke.sh   # after make release
headscale_ci_stop
```
