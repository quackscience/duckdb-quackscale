#pragma once

#include "duckdb/common/string.hpp"
#include "duckdb/common/typedefs.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>

namespace duckdb {

struct QuackForwardStatus {
	bool active = false;
	string remote_host;
	idx_t remote_port = 0;
	string local_host = "127.0.0.1";
	idx_t local_port = 0;
	string quack_uri;
};

//! Localhost TCP listener that dials the tailnet peer via tailscale_dial (libtailscale native path).
class TailscaleForwarder {
public:
	TailscaleForwarder() = default;
	~TailscaleForwarder();

	TailscaleForwarder(const TailscaleForwarder &) = delete;
	TailscaleForwarder &operator=(const TailscaleForwarder &) = delete;

	using DialFn = std::function<int(const string &network, const string &addr, int *conn_out)>;

	void Start(DialFn dial_fn, const string &remote_host, idx_t remote_port, idx_t local_port);
	void Stop();
	QuackForwardStatus Status() const;

private:
	void AcceptLoop();

	mutable std::mutex status_mutex;
	QuackForwardStatus status;
	DialFn dial_fn;
	string dial_addr;
	std::atomic<bool> stop_requested {false};
	int listen_fd = -1;
	std::thread accept_thread;
};

} // namespace duckdb
