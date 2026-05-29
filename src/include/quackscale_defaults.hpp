#pragma once

#include "duckdb/common/typedefs.hpp"

namespace duckdb {

//! Default Quack remote protocol port (see https://duckdb.org/docs/current/quack/overview).
static const idx_t QUACKSCALE_DEFAULT_QUACK_PORT = 9494;

//! Default local port for tailscale_quack_forward (127.0.0.1 → tailnet peer via tailscale_dial).
static const idx_t QUACKSCALE_DEFAULT_FORWARD_LOCAL_PORT = 19494;

} // namespace duckdb
