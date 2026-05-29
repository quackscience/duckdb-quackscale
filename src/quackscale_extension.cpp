#define DUCKDB_EXTENSION_MAIN

#include "quackscale_extension.hpp"
#include "quackscale_defaults.hpp"
#include "tailscale_bridge.hpp"

#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/parser/parsed_data/create_scalar_function_info.hpp"

#include <cstdlib>
#include <cstring>

namespace duckdb {

namespace {

static TailscaleAuthConfig ParseAuthConfig(TableFunctionBindInput &input) {
	TailscaleAuthConfig config;
	if (!input.inputs.empty() && !input.inputs[0].IsNull()) {
		config.hostname = input.inputs[0].GetValue<string>();
	}
	auto hostname_it = input.named_parameters.find("hostname");
	if (hostname_it != input.named_parameters.end()) {
		config.hostname = hostname_it->second.GetValue<string>();
	}
	auto authkey_it = input.named_parameters.find("authkey");
	if (authkey_it != input.named_parameters.end()) {
		config.authkey = authkey_it->second.GetValue<string>();
	}
	auto control_url_it = input.named_parameters.find("control_url");
	if (control_url_it != input.named_parameters.end()) {
		config.control_url = control_url_it->second.GetValue<string>();
	}
	auto state_dir_it = input.named_parameters.find("state_dir");
	if (state_dir_it != input.named_parameters.end()) {
		config.state_dir = state_dir_it->second.GetValue<string>();
	}
	auto ephemeral_it = input.named_parameters.find("ephemeral");
	if (ephemeral_it != input.named_parameters.end()) {
		config.ephemeral = ephemeral_it->second.GetValue<bool>();
	}
	auto loopback_it = input.named_parameters.find("loopback_proxy");
	if (loopback_it != input.named_parameters.end()) {
		config.loopback_proxy = loopback_it->second.GetValue<bool>();
	}
	return config;
}

static void RegisterAuthParameters(TableFunction &function) {
	function.named_parameters["hostname"] = LogicalType::VARCHAR;
	function.named_parameters["authkey"] = LogicalType::VARCHAR;
	function.named_parameters["control_url"] = LogicalType::VARCHAR;
	function.named_parameters["state_dir"] = LogicalType::VARCHAR;
	function.named_parameters["ephemeral"] = LogicalType::BOOLEAN;
	function.named_parameters["loopback_proxy"] = LogicalType::BOOLEAN;
}

struct QuackscaleUpBindData : public TableFunctionData {
	TailscaleAuthConfig config;
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleUpBind(ClientContext &context, TableFunctionBindInput &input,
                                                 vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscaleUpBindData>();
	bind->config = ParseAuthConfig(input);

	return_types = {LogicalType::BOOLEAN, LogicalType::VARCHAR, LogicalType::LIST(LogicalType::VARCHAR)};
	names = {"running", "hostname", "tailnet_ips"};
	return std::move(bind);
}

static void QuackscaleUpFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleUpBindData>();
	if (bind.finished) {
		return;
	}

	auto &bridge = TailscaleBridge::Get();
	bridge.Up(bind.config);
	auto status = bridge.Status();

	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(status.running));
	output.SetValue(1, 0, status.hostname.empty() ? Value() : Value(status.hostname));

	vector<Value> ip_values;
	ip_values.reserve(status.ips.size());
	for (auto &ip : status.ips) {
		ip_values.emplace_back(ip);
	}
	output.SetValue(2, 0, Value::LIST(LogicalType::VARCHAR, std::move(ip_values)));

	bind.finished = true;
}

struct QuackscaleStatusBindData : public TableFunctionData {
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleStatusBind(ClientContext &context, TableFunctionBindInput &input,
                                                     vector<LogicalType> &return_types, vector<string> &names) {
	return_types = {LogicalType::BOOLEAN, LogicalType::BOOLEAN, LogicalType::VARCHAR,
	                LogicalType::LIST(LogicalType::VARCHAR)};
	names = {"libtailscale_linked", "running", "hostname", "tailnet_ips"};
	return make_uniq<QuackscaleStatusBindData>();
}

static void QuackscaleStatusFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleStatusBindData>();
	if (bind.finished) {
		return;
	}

	auto status = TailscaleBridge::Get().Status();
	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(status.linked));
	output.SetValue(1, 0, Value::BOOLEAN(status.running));
	output.SetValue(2, 0, status.hostname.empty() ? Value() : Value(status.hostname));

	vector<Value> ip_values;
	ip_values.reserve(status.ips.size());
	for (auto &ip : status.ips) {
		ip_values.emplace_back(ip);
	}
	output.SetValue(3, 0, Value::LIST(LogicalType::VARCHAR, std::move(ip_values)));
	bind.finished = true;
}

static void QuackscaleQuackUriFunction(DataChunk &args, ExpressionState &state, Vector &result) {
	auto uri = TailscaleBridge::Get().QuackListenURI(QUACKSCALE_DEFAULT_QUACK_PORT);
	result.Reference(Value(uri));
}

static void QuackTokenFunction(DataChunk &args, ExpressionState &state, Vector &result) {
	const char *token = std::getenv("QUACK_TAILNET_TOKEN");
	if (token == nullptr || token[0] == '\0') {
		token = std::getenv("QUACK_TOKEN");
	}
	if (token == nullptr || token[0] == '\0') {
		throw InvalidInputException(
		    "quack_token(): set QUACK_TAILNET_TOKEN or QUACK_TOKEN to the shared Quack auth token for this tailnet");
	}
	if (strlen(token) < 4) {
		throw InvalidInputException("quack_token(): Quack tokens must be at least 4 characters");
	}
	result.Reference(Value(string(token)));
}

struct QuackscaleDiscoverBindData : public TableFunctionData {
	idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT;
	vector<QuackDiscoveryEndpoint> endpoints;
	idx_t offset = 0;
};

static unique_ptr<FunctionData> QuackscaleDiscoverBind(ClientContext &context, TableFunctionBindInput &input,
                                                       vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscaleDiscoverBindData>();
	auto port_it = input.named_parameters.find("port");
	if (port_it != input.named_parameters.end()) {
		auto port = port_it->second.GetValue<int64_t>();
		if (port <= 0 || port > 65535) {
			throw InvalidInputException("quack_discover port must be between 1 and 65535");
		}
		bind->port = NumericCast<idx_t>(port);
	}
	bind->endpoints = TailscaleBridge::Get().QuackDiscoveryEndpoints(bind->port);

	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::INTEGER, LogicalType::VARCHAR};
	names = {"listen_uri", "host", "port", "via"};
	return std::move(bind);
}

static void QuackscaleDiscoverFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleDiscoverBindData>();
	const idx_t count = MinValue<idx_t>(STANDARD_VECTOR_SIZE, bind.endpoints.size() - bind.offset);
	if (count == 0) {
		return;
	}

	for (idx_t i = 0; i < count; i++) {
		auto &endpoint = bind.endpoints[bind.offset + i];
		output.SetValue(0, i, endpoint.listen_uri);
		output.SetValue(1, i, endpoint.host);
		output.SetValue(2, i, Value::INTEGER(NumericCast<int32_t>(endpoint.port)));
		output.SetValue(3, i, endpoint.via);
	}
	output.SetCardinality(count);
	bind.offset += count;
}

struct QuackscaleBeginLoginBindData : public TableFunctionData {
	TailscaleAuthConfig config;
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleBeginLoginBind(ClientContext &context, TableFunctionBindInput &input,
                                                         vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscaleBeginLoginBindData>();
	bind->config = ParseAuthConfig(input);
	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR};
	names = {"status", "login_url", "message"};
	return std::move(bind);
}

static void QuackscaleBeginLoginFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleBeginLoginBindData>();
	if (bind.finished) {
		return;
	}
	TailscaleBridge::Get().BeginInteractiveLogin(bind.config);
	auto login = TailscaleBridge::Get().LoginStatus();
	output.SetCardinality(1);
	output.SetValue(0, 0, login.status);
	output.SetValue(1, 0, login.login_url.empty() ? Value() : Value(login.login_url));
	output.SetValue(2, 0, login.message);
	bind.finished = true;
}

struct QuackscaleLoginStatusBindData : public TableFunctionData {
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleLoginStatusBind(ClientContext &context, TableFunctionBindInput &input,
                                                          vector<LogicalType> &return_types, vector<string> &names) {
	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	                LogicalType::BOOLEAN, LogicalType::VARCHAR, LogicalType::LIST(LogicalType::VARCHAR)};
	names = {"status", "login_url", "message", "running", "hostname", "tailnet_ips"};
	return make_uniq<QuackscaleLoginStatusBindData>();
}

static void QuackscaleLoginStatusFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleLoginStatusBindData>();
	if (bind.finished) {
		return;
	}
	auto login = TailscaleBridge::Get().LoginStatus();
	output.SetCardinality(1);
	output.SetValue(0, 0, login.status);
	output.SetValue(1, 0, login.login_url.empty() ? Value() : Value(login.login_url));
	output.SetValue(2, 0, login.message.empty() ? Value() : Value(login.message));
	output.SetValue(3, 0, Value::BOOLEAN(login.running));
	output.SetValue(4, 0, login.hostname.empty() ? Value() : Value(login.hostname));
	vector<Value> ip_values;
	for (auto &ip : login.ips) {
		ip_values.emplace_back(ip);
	}
	output.SetValue(5, 0, Value::LIST(LogicalType::VARCHAR, std::move(ip_values)));
	bind.finished = true;
}

struct QuackscaleServeLocalBindData : public TableFunctionData {
	idx_t listen_port = QUACKSCALE_DEFAULT_QUACK_PORT;
	idx_t local_port = QUACKSCALE_DEFAULT_QUACK_PORT;
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleServeLocalBind(ClientContext &context, TableFunctionBindInput &input,
                                                         vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscaleServeLocalBindData>();
	auto port_it = input.named_parameters.find("port");
	if (port_it != input.named_parameters.end()) {
		auto port = port_it->second.GetValue<int64_t>();
		if (port <= 0 || port > 65535) {
			throw InvalidInputException("tailscale_serve_local port must be between 1 and 65535");
		}
		bind->listen_port = NumericCast<idx_t>(port);
	}
	auto local_it = input.named_parameters.find("local_port");
	if (local_it != input.named_parameters.end()) {
		auto port = local_it->second.GetValue<int64_t>();
		if (port <= 0 || port > 65535) {
			throw InvalidInputException("tailscale_serve_local local_port must be between 1 and 65535");
		}
		bind->local_port = NumericCast<idx_t>(port);
	} else {
		bind->local_port = bind->listen_port;
	}

	return_types = {LogicalType::INTEGER, LogicalType::INTEGER, LogicalType::VARCHAR};
	names = {"listen_port", "local_port", "local_forward"};
	return std::move(bind);
}

static void QuackscaleServeLocalFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleServeLocalBindData>();
	if (bind.finished) {
		return;
	}

	TailscaleBridge::Get().ServeLocalhostTCP(bind.listen_port, bind.local_port);
	auto forward = StringUtil::Format("127.0.0.1:%d", bind.local_port);

	output.SetCardinality(1);
	output.SetValue(0, 0, Value::INTEGER(NumericCast<int32_t>(bind.listen_port)));
	output.SetValue(1, 0, Value::INTEGER(NumericCast<int32_t>(bind.local_port)));
	output.SetValue(2, 0, forward);
	bind.finished = true;
}

struct QuackscalePingBindData : public TableFunctionData {
	string host;
	idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT;
	idx_t timeout_ms = 5000;
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscalePingBind(ClientContext &context, TableFunctionBindInput &input,
                                                   vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscalePingBindData>();
	auto host_it = input.named_parameters.find("host");
	if (host_it == input.named_parameters.end() || host_it->second.IsNull()) {
		throw InvalidInputException("tailscale_ping requires named parameter host");
	}
	bind->host = host_it->second.GetValue<string>();
	auto port_it = input.named_parameters.find("port");
	if (port_it != input.named_parameters.end()) {
		auto port = port_it->second.GetValue<int64_t>();
		if (port <= 0 || port > 65535) {
			throw InvalidInputException("tailscale_ping port must be between 1 and 65535");
		}
		bind->port = NumericCast<idx_t>(port);
	}
	auto timeout_it = input.named_parameters.find("timeout_ms");
	if (timeout_it != input.named_parameters.end()) {
		auto timeout = timeout_it->second.GetValue<int64_t>();
		if (timeout <= 0) {
			throw InvalidInputException("tailscale_ping timeout_ms must be positive");
		}
		bind->timeout_ms = NumericCast<idx_t>(timeout);
	}

	return_types = {LogicalType::VARCHAR, LogicalType::INTEGER, LogicalType::BOOLEAN};
	names = {"host", "port", "reachable"};
	return std::move(bind);
}

static void QuackscalePingFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscalePingBindData>();
	if (bind.finished) {
		return;
	}

	TailscaleBridge::Get().PingTCP(bind.host, bind.port, bind.timeout_ms);
	output.SetCardinality(1);
	output.SetValue(0, 0, Value(bind.host));
	output.SetValue(1, 0, Value::INTEGER(NumericCast<int32_t>(bind.port)));
	output.SetValue(2, 0, Value::BOOLEAN(true));
	bind.finished = true;
}

struct QuackscaleProxyStatusBindData : public TableFunctionData {
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleProxyStatusBind(ClientContext &context, TableFunctionBindInput &input,
                                                          vector<LogicalType> &return_types, vector<string> &names) {
	return_types = {LogicalType::BOOLEAN, LogicalType::BOOLEAN, LogicalType::VARCHAR, LogicalType::VARCHAR};
	names = {"enabled", "active", "listen_addr", "proxy_url"};
	return make_uniq<QuackscaleProxyStatusBindData>();
}

static void QuackscaleProxyStatusFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleProxyStatusBindData>();
	if (bind.finished) {
		return;
	}
	auto proxy = TailscaleBridge::Get().ProxyStatus();
	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(proxy.enabled));
	output.SetValue(1, 0, Value::BOOLEAN(proxy.active));
	output.SetValue(2, 0, proxy.listen_addr.empty() ? Value() : Value(proxy.listen_addr));
	output.SetValue(3, 0, proxy.proxy_url.empty() ? Value() : Value(proxy.proxy_url));
	bind.finished = true;
}

struct QuackscaleQuackProxyBindData : public TableFunctionData {
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleQuackProxyBind(ClientContext &context, TableFunctionBindInput &input,
                                                         vector<LogicalType> &return_types, vector<string> &names) {
	return_types = {LogicalType::BOOLEAN, LogicalType::VARCHAR, LogicalType::VARCHAR};
	names = {"active", "listen_addr", "proxy_url"};
	return make_uniq<QuackscaleQuackProxyBindData>();
}

static void QuackscaleQuackProxyFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleQuackProxyBindData>();
	if (bind.finished) {
		return;
	}
	TailscaleBridge::Get().EnableQuackProxy();
	auto proxy = TailscaleBridge::Get().ProxyStatus();
	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(proxy.active));
	output.SetValue(1, 0, proxy.listen_addr.empty() ? Value() : Value(proxy.listen_addr));
	output.SetValue(2, 0, proxy.proxy_url.empty() ? Value() : Value(proxy.proxy_url));
	bind.finished = true;
}

struct QuackscaleQuackForwardBindData : public TableFunctionData {
	string host;
	idx_t port = QUACKSCALE_DEFAULT_QUACK_PORT;
	idx_t local_port = QUACKSCALE_DEFAULT_FORWARD_LOCAL_PORT;
	bool finished = false;
};

static unique_ptr<FunctionData> QuackscaleQuackForwardBind(ClientContext &context, TableFunctionBindInput &input,
                                                           vector<LogicalType> &return_types, vector<string> &names) {
	auto bind = make_uniq<QuackscaleQuackForwardBindData>();
	auto host_it = input.named_parameters.find("host");
	if (host_it == input.named_parameters.end() || host_it->second.IsNull()) {
		throw InvalidInputException("tailscale_quack_forward requires named parameter host");
	}
	bind->host = host_it->second.GetValue<string>();
	auto port_it = input.named_parameters.find("port");
	if (port_it != input.named_parameters.end()) {
		auto port = port_it->second.GetValue<int64_t>();
		if (port <= 0 || port > 65535) {
			throw InvalidInputException("tailscale_quack_forward port must be between 1 and 65535");
		}
		bind->port = NumericCast<idx_t>(port);
	}
	auto local_it = input.named_parameters.find("local_port");
	if (local_it != input.named_parameters.end()) {
		auto port = local_it->second.GetValue<int64_t>();
		if (port < 0 || port > 65535) {
			throw InvalidInputException("tailscale_quack_forward local_port must be between 0 and 65535");
		}
		bind->local_port = NumericCast<idx_t>(port);
	}

	return_types = {LogicalType::BOOLEAN, LogicalType::VARCHAR, LogicalType::INTEGER, LogicalType::INTEGER,
	                LogicalType::VARCHAR};
	names = {"active", "remote_host", "remote_port", "local_port", "quack_uri"};
	return std::move(bind);
}

static void QuackscaleQuackForwardFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<QuackscaleQuackForwardBindData>();
	if (bind.finished) {
		return;
	}
	auto forward = TailscaleBridge::Get().StartQuackForward(bind.host, bind.port, bind.local_port);
	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(forward.active));
	output.SetValue(1, 0, forward.remote_host.empty() ? Value() : Value(forward.remote_host));
	output.SetValue(2, 0, Value::INTEGER(NumericCast<int32_t>(forward.remote_port)));
	output.SetValue(3, 0, Value::INTEGER(NumericCast<int32_t>(forward.local_port)));
	output.SetValue(4, 0, forward.quack_uri.empty() ? Value() : Value(forward.quack_uri));
	bind.finished = true;
}

static void LoadInternal(ExtensionLoader &loader) {
	TableFunction up_function("tailscale_up", {}, QuackscaleUpFunction, QuackscaleUpBind);
	RegisterAuthParameters(up_function);
	loader.RegisterFunction(up_function);

	TableFunction login_function("tailscale_login", {}, QuackscaleBeginLoginFunction,
	                             QuackscaleBeginLoginBind);
	RegisterAuthParameters(login_function);
	loader.RegisterFunction(login_function);

	loader.RegisterFunction(
	    TableFunction("tailscale_login_status", {}, QuackscaleLoginStatusFunction, QuackscaleLoginStatusBind));

	loader.RegisterFunction(TableFunction("tailscale_status", {}, QuackscaleStatusFunction, QuackscaleStatusBind));

	loader.RegisterFunction(
	    TableFunction("tailscale_proxy_status", {}, QuackscaleProxyStatusFunction, QuackscaleProxyStatusBind));

	loader.RegisterFunction(TableFunction("tailscale_quack_proxy", {}, QuackscaleQuackProxyFunction,
	                                      QuackscaleQuackProxyBind));

	TableFunction forward_function("tailscale_quack_forward", {}, QuackscaleQuackForwardFunction,
	                               QuackscaleQuackForwardBind);
	forward_function.named_parameters["host"] = LogicalType::VARCHAR;
	forward_function.named_parameters["port"] = LogicalType::BIGINT;
	forward_function.named_parameters["local_port"] = LogicalType::BIGINT;
	loader.RegisterFunction(forward_function);

	TableFunction discover_function("quack_discover", {}, QuackscaleDiscoverFunction, QuackscaleDiscoverBind);
	discover_function.named_parameters["port"] = LogicalType::BIGINT;
	loader.RegisterFunction(discover_function);

	TableFunction serve_local_function("tailscale_serve_local", {}, QuackscaleServeLocalFunction,
	                                   QuackscaleServeLocalBind);
	serve_local_function.named_parameters["port"] = LogicalType::BIGINT;
	serve_local_function.named_parameters["local_port"] = LogicalType::BIGINT;
	loader.RegisterFunction(serve_local_function);

	TableFunction ping_function("tailscale_ping", {}, QuackscalePingFunction, QuackscalePingBind);
	ping_function.named_parameters["host"] = LogicalType::VARCHAR;
	ping_function.named_parameters["port"] = LogicalType::BIGINT;
	ping_function.named_parameters["timeout_ms"] = LogicalType::BIGINT;
	loader.RegisterFunction(ping_function);

	loader.RegisterFunction(ScalarFunction("quack_uri", {}, LogicalType::VARCHAR, QuackscaleQuackUriFunction));
	loader.RegisterFunction(ScalarFunction("quack_token", {}, LogicalType::VARCHAR, QuackTokenFunction));
}

} // namespace

void QuackscaleExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string QuackscaleExtension::Name() {
	return "quackscale";
}

std::string QuackscaleExtension::Version() const {
#ifdef EXT_VERSION_QUACKSCALE
	return EXT_VERSION_QUACKSCALE;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(quackscale, loader) {
	duckdb::LoadInternal(loader);
}
}
