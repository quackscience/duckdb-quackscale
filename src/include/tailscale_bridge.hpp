#pragma once

#include "duckdb/common/string.hpp"
#include "duckdb/common/vector.hpp"
#include "quackscale_defaults.hpp"
#include "tailscale_log_capture.hpp"
#include "tailscale_forwarder.hpp"

#include <thread>

namespace duckdb {

struct TailscaleAuthConfig {
	string hostname;
	string authkey;
	string control_url;
	string state_dir;
	bool ephemeral = false;
	//! Start libtailscale loopback SOCKS for Quack HTTP via CALL tailscale_quack_proxy().
	bool loopback_proxy = false;
};

struct TailscaleProxyStatus {
	bool enabled = false;
	bool active = false;
	string listen_addr;
	//! socks5h://tsnet:***@127.0.0.1:port — password redacted for display
	string proxy_url;
};

struct TailscaleLoginStatus {
	//! `starting`, `needs_login`, `up`, `error`, or `idle`
	string status;
	string login_url;
	string message;
	bool running = false;
	string hostname;
	vector<string> ips;
};

//! A Quack endpoint advertised on the tailnet for client discovery (default port 9494).
struct QuackDiscoveryEndpoint {
	string listen_uri;
	string host;
	idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT;
	//! `magicdns` when host is the tailnet machine name; `tailnet_ip` for each assigned IP.
	string via;
};

struct TailscaleStatus {
	bool linked = false;
	bool running = false;
	string hostname;
	vector<string> ips;
	string last_error;
};

class TailscaleBridge {
public:
	static TailscaleBridge &Get();

	TailscaleStatus Status() const;
	void Up(const string &hostname, const string &authkey, const string &control_url, const string &state_dir,
	        bool ephemeral);
	void Up(const TailscaleAuthConfig &config);
	void BeginInteractiveLogin(const TailscaleAuthConfig &config);
	TailscaleLoginStatus LoginStatus() const;
	TailscaleProxyStatus ProxyStatus() const;
	QuackForwardStatus ForwardStatus() const;
	//! Enable tsnet SOCKS for Quack HTTP (legacy; prefer tailscale_quack_forward).
	void EnableQuackProxy();
	//! Listen on 127.0.0.1 and dial the tailnet peer via tailscale_dial (no ALL_PROXY).
	QuackForwardStatus StartQuackForward(const string &host, idx_t port, idx_t local_port);
	void Shutdown();

	//! Tailscale Serve: expose listen_port on the tailnet, TCP-forward to 127.0.0.1:local_port.
	void ServeLocalhostTCP(idx_t listen_port, idx_t local_port);
	void ClearServe();

	//! Dial host:port over the tailnet via tsnet (peer connectivity check).
	void PingTCP(const string &host, idx_t port, idx_t timeout_ms);

	string PrimaryTailnetIP() const;
	string FormatQuackURI(const string &host, idx_t port) const;
	string QuackListenURI(idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT) const;
	vector<QuackDiscoveryEndpoint> QuackDiscoveryEndpoints(idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT) const;

private:
	TailscaleBridge() = default;
	~TailscaleBridge();

	TailscaleBridge(const TailscaleBridge &) = delete;
	TailscaleBridge &operator=(const TailscaleBridge &) = delete;

	void EnsureHandle();
	void ApplyConfig(const TailscaleAuthConfig &config);
	void RefreshIPs();
	string LastErrorMessage() const;
	void JoinLoginThread();
	void DetachLoginThread();
	string ResolveAuthKey(const string &authkey) const;
	void MaybeStartLoopbackProxy(bool enable);
	void StartLoopbackProxy();
	void ClearProxyEnvironment();

	struct SavedProxyEnv {
		bool all_proxy = false;
		bool no_proxy = false;
		string all_proxy_value;
		string no_proxy_value;
	};

#ifdef QUACKSCALE_WITH_TAILSCALE
	int handle = -1;
#endif
	bool running = false;
	string hostname;
	vector<string> ips;
	string login_state = "idle";
	string login_message;
	string pending_login_url;
	std::thread login_thread;
	TailscaleLogCapture log_capture;
	TailscaleProxyStatus proxy_status;
	SavedProxyEnv saved_proxy_env;
	TailscaleForwarder forwarder;
};

} // namespace duckdb
