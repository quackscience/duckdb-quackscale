#include "tailscale_bridge.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "quackscale_defaults.hpp"

#include <chrono>
#include <cstdlib>
#include <mutex>
#include <sstream>
#include <thread>

#ifdef QUACKSCALE_WITH_TAILSCALE
extern "C" {
#include "tailscale.h"
}
#endif

namespace duckdb {

namespace {

std::mutex g_tailscale_mutex;

vector<string> SplitCommaSeparatedIPs(const string &csv) {
	vector<string> result;
	if (csv.empty()) {
		return result;
	}
	std::stringstream stream(csv);
	string item;
	while (std::getline(stream, item, ',')) {
		StringUtil::Trim(item);
		if (!item.empty()) {
			result.push_back(item);
		}
	}
	return result;
}

} // namespace

TailscaleBridge::~TailscaleBridge() {
	Shutdown();
}

TailscaleBridge &TailscaleBridge::Get() {
	static TailscaleBridge instance;
	return instance;
}

void TailscaleBridge::EnsureHandle() {
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (handle >= 0) {
		return;
	}
	handle = tailscale_new();
	if (handle < 0) {
		throw IOException("tailscale_new failed");
	}
#else
	throw NotImplementedException("QuackScale was built without libtailscale (QUACKSCALE_WITH_TAILSCALE=OFF). "
	                              "Install Go and rebuild with QUACKSCALE_WITH_TAILSCALE=ON.");
#endif
}

string TailscaleBridge::LastErrorMessage() const {
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (handle < 0) {
		return "tailscale handle not initialized";
	}
	char buf[1024];
	if (tailscale_errmsg(handle, buf, sizeof(buf)) != 0) {
		return "unknown tailscale error";
	}
	return string(buf);
#else
	return "libtailscale not linked";
#endif
}

string TailscaleBridge::ResolveAuthKey(const string &authkey) const {
	if (!authkey.empty()) {
		return authkey;
	}
	if (const char *env = std::getenv("TS_AUTHKEY")) {
		return string(env);
	}
	return string();
}

void TailscaleBridge::ApplyConfig(const TailscaleAuthConfig &config) {
#ifdef QUACKSCALE_WITH_TAILSCALE
	EnsureHandle();

	if (!config.state_dir.empty() && tailscale_set_dir(handle, config.state_dir.c_str()) != 0) {
		throw IOException("tailscale_set_dir failed: %s", LastErrorMessage());
	}
	if (!config.hostname.empty() && tailscale_set_hostname(handle, config.hostname.c_str()) != 0) {
		throw IOException("tailscale_set_hostname failed: %s", LastErrorMessage());
	}
	auto resolved_key = ResolveAuthKey(config.authkey);
	if (!resolved_key.empty() && tailscale_set_authkey(handle, resolved_key.c_str()) != 0) {
		throw IOException("tailscale_set_authkey failed: %s", LastErrorMessage());
	}
	if (!config.control_url.empty() && tailscale_set_control_url(handle, config.control_url.c_str()) != 0) {
		throw IOException("tailscale_set_control_url failed: %s", LastErrorMessage());
	}
	if (config.ephemeral && tailscale_set_ephemeral(handle, 1) != 0) {
		throw IOException("tailscale_set_ephemeral failed: %s", LastErrorMessage());
	}
	hostname = config.hostname;
#else
	(void)config;
	throw NotImplementedException(
	    "QuackScale was built without libtailscale. Rebuild with Go installed and QUACKSCALE_WITH_TAILSCALE=ON.");
#endif
}

void TailscaleBridge::RefreshIPs() {
	ips.clear();
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (handle < 0) {
		return;
	}
	char buf[512];
	if (tailscale_getips(handle, buf, sizeof(buf)) != 0) {
		return;
	}
	ips = SplitCommaSeparatedIPs(string(buf));
#endif
}

void TailscaleBridge::JoinLoginThread() {
	if (login_thread.joinable()) {
		login_thread.join();
	}
}

void TailscaleBridge::DetachLoginThread() {
	if (login_thread.joinable()) {
		login_thread.detach();
	}
}

TailscaleStatus TailscaleBridge::Status() const {
	TailscaleStatus status;
	status.linked =
#ifdef QUACKSCALE_WITH_TAILSCALE
	    true;
#else
	    false;
#endif
	status.running = running;
	status.hostname = hostname;
	status.ips = ips;
	if (!running && !ips.empty()) {
		status.running = true;
	}
	return status;
}

void TailscaleBridge::Up(const string &hostname_in, const string &authkey, const string &control_url,
                         const string &state_dir, bool ephemeral) {
	TailscaleAuthConfig config;
	config.hostname = hostname_in;
	config.authkey = authkey;
	config.control_url = control_url;
	config.state_dir = state_dir;
	config.ephemeral = ephemeral;
	Up(config);
}

void TailscaleBridge::ClearProxyEnvironment() {
	if (!proxy_status.active) {
		return;
	}
	auto restore = [](const char *name, const string &value, bool had) {
		if (had) {
			setenv(name, value.c_str(), 1);
		} else {
			unsetenv(name);
		}
	};
	restore("ALL_PROXY", saved_proxy_env.all_proxy_value, saved_proxy_env.all_proxy);
	restore("all_proxy", saved_proxy_env.all_proxy_value, saved_proxy_env.all_proxy);
	restore("NO_PROXY", saved_proxy_env.no_proxy_value, saved_proxy_env.no_proxy);
	restore("no_proxy", saved_proxy_env.no_proxy_value, saved_proxy_env.no_proxy);
	proxy_status = TailscaleProxyStatus {};
	saved_proxy_env = SavedProxyEnv {};
}

void TailscaleBridge::StartLoopbackProxy() {
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (proxy_status.active) {
		return;
	}
	if (!running) {
		throw InvalidInputException("tailscale loopback proxy: call tailscale_up() first");
	}
	EnsureHandle();

	char addr_buf[256] = {};
	char proxy_cred[33] = {};
	char local_cred[33] = {};
	if (tailscale_loopback(handle, addr_buf, sizeof(addr_buf), proxy_cred, local_cred) != 0) {
		throw IOException("tailscale loopback proxy failed: %s", LastErrorMessage());
	}

	auto save_env = [](const char *name, string &dest, bool &had) {
		if (const char *value = std::getenv(name)) {
			dest = value;
			had = true;
		}
	};
	save_env("ALL_PROXY", saved_proxy_env.all_proxy_value, saved_proxy_env.all_proxy);
	save_env("NO_PROXY", saved_proxy_env.no_proxy_value, saved_proxy_env.no_proxy);

	auto proxy_url = StringUtil::Format("socks5h://tsnet:%s@%s", proxy_cred, addr_buf);
	// Only ALL_PROXY — do not set HTTP_PROXY/HTTPS_PROXY to socks5h (breaks tsnet LocalClient / curl).
	setenv("ALL_PROXY", proxy_url.c_str(), 1);
	setenv("all_proxy", proxy_url.c_str(), 1);

	string no_proxy = "localhost,127.0.0.1,::1,headscale";
	if (saved_proxy_env.no_proxy && !saved_proxy_env.no_proxy_value.empty()) {
		no_proxy = saved_proxy_env.no_proxy_value + "," + no_proxy;
	}
	setenv("NO_PROXY", no_proxy.c_str(), 1);
	setenv("no_proxy", no_proxy.c_str(), 1);

	proxy_status.enabled = true;
	proxy_status.active = true;
	proxy_status.listen_addr = addr_buf;
	proxy_status.proxy_url = StringUtil::Format("socks5h://tsnet:***@%s", addr_buf);
#else
	throw NotImplementedException("QuackScale was built without libtailscale.");
#endif
}

void TailscaleBridge::MaybeStartLoopbackProxy(bool enable) {
	proxy_status.enabled = enable;
	if (!enable) {
		return;
	}
	StartLoopbackProxy();
}

void TailscaleBridge::EnableQuackProxy() {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
	proxy_status.enabled = true;
	StartLoopbackProxy();
}

QuackForwardStatus TailscaleBridge::StartQuackForward(const string &host, idx_t port, idx_t local_port) {
#ifdef QUACKSCALE_WITH_TAILSCALE
	int ts_handle = -1;
	{
		std::lock_guard<std::mutex> guard(g_tailscale_mutex);
		if (!running) {
			throw InvalidInputException("tailscale_quack_forward: call tailscale_up() first");
		}
		EnsureHandle();
		ts_handle = handle;
	}
	auto listen_port = local_port == 0 ? QUACKSCALE_DEFAULT_FORWARD_LOCAL_PORT : local_port;
	auto dial_fn = [ts_handle](const string &network, const string &addr, int *conn_out) -> int {
		std::lock_guard<std::mutex> dial_guard(g_tailscale_mutex);
		tailscale_conn conn = -1;
		auto rc = tailscale_dial(ts_handle, network.c_str(), addr.c_str(), &conn);
		if (rc != 0) {
			return rc;
		}
		*conn_out = conn;
		return 0;
	};
	forwarder.Start(dial_fn, host, port, listen_port);
	return forwarder.Status();
#else
	(void)host;
	(void)port;
	(void)local_port;
	throw NotImplementedException("QuackScale was built without libtailscale.");
#endif
}

QuackForwardStatus TailscaleBridge::ForwardStatus() const {
	return forwarder.Status();
}

TailscaleProxyStatus TailscaleBridge::ProxyStatus() const {
	return proxy_status;
}

void TailscaleBridge::Up(const TailscaleAuthConfig &config) {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
#ifdef QUACKSCALE_WITH_TAILSCALE
	JoinLoginThread();
	ApplyConfig(config);

	if (tailscale_up(handle) != 0) {
		auto login_url = log_capture.ExtractLoginURL();
		if (!login_url.empty()) {
			throw IOException("tailscale_up needs browser login. Open: %s (or use tailscale_login)", login_url);
		}
		throw IOException("tailscale_up failed: %s", LastErrorMessage());
	}

	running = true;
	login_state = "up";
	RefreshIPs();
	MaybeStartLoopbackProxy(config.loopback_proxy);
#else
	(void)config;
	throw NotImplementedException(
	    "QuackScale was built without libtailscale. Rebuild with Go installed and QUACKSCALE_WITH_TAILSCALE=ON.");
#endif
}

void TailscaleBridge::BeginInteractiveLogin(const TailscaleAuthConfig &config) {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
#ifdef QUACKSCALE_WITH_TAILSCALE
	JoinLoginThread();
	ApplyConfig(config);

	log_capture.Start(handle);
	login_state = "starting";
	login_message = "Joining tailnet";
	pending_login_url.clear();
	running = false;
	ips.clear();

	auto config_copy = config;
	login_thread = std::thread([this, config_copy]() {
		if (tailscale_up(handle) != 0) {
			login_state = "error";
			login_message = LastErrorMessage();
			return;
		}
		running = true;
		login_state = "up";
		login_message = "Connected";
		hostname = config_copy.hostname;
		RefreshIPs();
		if (config_copy.loopback_proxy) {
			std::lock_guard<std::mutex> guard(g_tailscale_mutex);
			MaybeStartLoopbackProxy(true);
		}
	});

	// Give tsnet a moment to print the interactive login URL on the log fd.
	for (int i = 0; i < 50; i++) {
		pending_login_url = log_capture.ExtractLoginURL();
		if (!pending_login_url.empty()) {
			login_state = "needs_login";
			login_message = "Open login_url in a browser to authorize this node";
			return;
		}
		if (running) {
			return;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
	}

	if (ResolveAuthKey(config.authkey).empty()) {
		login_message = "Waiting for tailnet login (poll tailscale_login_status or watch DuckDB stderr)";
	}
#else
	(void)config;
	throw NotImplementedException(
	    "QuackScale was built without libtailscale. Rebuild with Go installed and QUACKSCALE_WITH_TAILSCALE=ON.");
#endif
}

TailscaleLoginStatus TailscaleBridge::LoginStatus() const {
	TailscaleLoginStatus result;
	auto status = Status();
	result.running = status.running;
	result.hostname = status.hostname;
	result.ips = status.ips;
	result.status = login_state;
	result.message = login_message;
	result.login_url = pending_login_url.empty() ? log_capture.ExtractLoginURL() : pending_login_url;
	if (result.login_url.empty() && result.status == "starting") {
		result.login_url = log_capture.ExtractLoginURL();
	}
	if (result.running && result.status != "error") {
		result.status = "up";
	}
	return result;
}

void TailscaleBridge::Shutdown() {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
	log_capture.Stop();
	// Do not join — interactive login or tsnet teardown can block indefinitely.
	DetachLoginThread();
	forwarder.Stop();
	ClearProxyEnvironment();
#ifdef QUACKSCALE_WITH_TAILSCALE
	int closing = handle;
	handle = -1;
	running = false;
	if (closing >= 0) {
		tailscale_clear_serve(closing);
		// tailscale_close waits for AuthLoop; detach so CALL tailscale_down() returns.
		std::thread([closing]() { tailscale_close(closing); }).detach();
	}
#else
#endif
	ips.clear();
	login_state = "idle";
	login_message.clear();
	pending_login_url.clear();
}

void TailscaleBridge::ServeLocalhostTCP(idx_t listen_port, idx_t local_port) {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (!running) {
		throw InvalidInputException("tailscale_serve_local: call tailscale_up() first");
	}
	EnsureHandle();
	if (listen_port == 0 || listen_port > 65535 || local_port == 0 || local_port > 65535) {
		throw InvalidInputException("tailscale_serve_local: ports must be between 1 and 65535");
	}
	if (tailscale_serve_localhost_tcp(handle, static_cast<int>(listen_port), static_cast<int>(local_port)) != 0) {
		throw IOException("tailscale_serve_local failed: %s", LastErrorMessage());
	}
#else
	(void)listen_port;
	(void)local_port;
	throw NotImplementedException("QuackScale was built without libtailscale.");
#endif
}

void TailscaleBridge::ClearServe() {
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (handle >= 0) {
		tailscale_clear_serve(handle);
	}
#endif
}

void TailscaleBridge::PingTCP(const string &host, idx_t port, idx_t timeout_ms) {
	std::lock_guard<std::mutex> guard(g_tailscale_mutex);
#ifdef QUACKSCALE_WITH_TAILSCALE
	if (!running) {
		throw InvalidInputException("tailscale_ping: call tailscale_up() first");
	}
	if (host.empty()) {
		throw InvalidInputException("tailscale_ping: host must not be empty");
	}
	if (port == 0 || port > 65535) {
		throw InvalidInputException("tailscale_ping: port must be between 1 and 65535");
	}
	EnsureHandle();
	auto timeout = timeout_ms == 0 ? 5000 : static_cast<int>(timeout_ms);
	if (tailscale_ping_tcp(handle, host.c_str(), static_cast<int>(port), timeout) != 0) {
		throw IOException("tailscale_ping failed: %s", LastErrorMessage());
	}
#else
	(void)host;
	(void)port;
	(void)timeout_ms;
	throw NotImplementedException("QuackScale was built without libtailscale.");
#endif
}

string TailscaleBridge::PrimaryTailnetIP() const {
	if (ips.empty()) {
		throw InvalidInputException("Tailscale is not up or has no tailnet IPs yet. Call tailscale_up() first.");
	}
	return ips[0];
}

string TailscaleBridge::FormatQuackURI(const string &host, idx_t port) const {
	if (host.find(':') != string::npos) {
		return StringUtil::Format("quack:[%s]:%d", host, port);
	}
	return StringUtil::Format("quack:%s:%d", host, port);
}

string TailscaleBridge::QuackListenURI(idx_t port) const {
	if (!hostname.empty()) {
		return FormatQuackURI(hostname, port);
	}
	return FormatQuackURI(PrimaryTailnetIP(), port);
}

vector<QuackDiscoveryEndpoint> TailscaleBridge::QuackDiscoveryEndpoints(idx_t port) const {
	vector<QuackDiscoveryEndpoint> endpoints;
	if (!running && ips.empty()) {
		return endpoints;
	}

	if (!hostname.empty()) {
		QuackDiscoveryEndpoint entry;
		entry.host = hostname;
		entry.port = port;
		entry.via = "magicdns";
		entry.listen_uri = FormatQuackURI(hostname, port);
		endpoints.push_back(std::move(entry));
	}

	for (auto &ip : ips) {
		QuackDiscoveryEndpoint entry;
		entry.host = ip;
		entry.port = port;
		entry.via = "tailnet_ip";
		entry.listen_uri = FormatQuackURI(ip, port);
		endpoints.push_back(std::move(entry));
	}
	return endpoints;
}

} // namespace duckdb
