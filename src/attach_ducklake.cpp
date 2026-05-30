#include "attach_ducklake.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/main/materialized_query_result.hpp"

#include <regex>

namespace duckdb {

namespace {

static constexpr const char *kIdentPattern = "^[A-Za-z_][A-Za-z0-9_]*$";

static void ValidateIdentifier(const string &name, const char *label) {
	std::regex re(kIdentPattern);
	if (!std::regex_match(name, re)) {
		throw InvalidInputException("%s must match %s (got '%s')", label, kIdentPattern, name);
	}
}

static string EscapeSqlString(const string &value) {
	return StringUtil::Replace(value, "'", "''");
}

static string BuildQuackQueryFromClause(const string &quack_uri, const string &remote_sql, const string &token,
                                        bool disable_ssl) {
	string sql = "FROM quack_query('" + EscapeSqlString(quack_uri) + "', '" + EscapeSqlString(remote_sql) + "'";
	if (!token.empty()) {
		sql += ", token => '" + EscapeSqlString(token) + "'";
	}
	if (disable_ssl) {
		sql += ", disable_ssl => true";
	}
	sql += ")";
	return sql;
}

static void EnsureQuackLoaded(Connection &conn) {
	auto result = conn.Query("SELECT COUNT(*) FROM duckdb_functions() WHERE function_name = 'quack_query'");
	if (result->HasError()) {
		throw InvalidInputException("attach_ducklake requires LOAD quack; %s", result->GetError());
	}
	auto count = result->GetValue(0, 0).GetValue<int64_t>();
	if (count == 0) {
		throw InvalidInputException("attach_ducklake requires LOAD quack (quack_query not registered)");
	}
}

static void RunStatement(Connection &conn, const string &sql) {
	auto result = conn.Query(sql);
	if (result->HasError()) {
		throw InvalidInputException("attach_ducklake failed: %s\nStatement: %s", result->GetError(), sql);
	}
}

struct RemoteLakeAttachBindData : public TableFunctionData {
	string quack_uri;
	string remote_catalog;
	string alias;
	string token;
	bool disable_ssl = true;
	bool finished = false;
	vector<string> created_views;
};

static unique_ptr<FunctionData> RemoteLakeAttachBind(ClientContext &context, TableFunctionBindInput &input,
                                                     vector<LogicalType> &return_types, vector<string> &names) {
	if (input.inputs.empty() || input.inputs[0].IsNull()) {
		throw InvalidInputException("attach_ducklake requires quack_uri");
	}

	auto bind = make_uniq<RemoteLakeAttachBindData>();
	bind->quack_uri = input.inputs[0].GetValue<string>();

	auto catalog_it = input.named_parameters.find("remote_catalog");
	if (catalog_it != input.named_parameters.end()) {
		bind->remote_catalog = catalog_it->second.GetValue<string>();
	} else {
		bind->remote_catalog = "lake";
	}
	auto alias_it = input.named_parameters.find("alias");
	if (alias_it != input.named_parameters.end()) {
		bind->alias = alias_it->second.GetValue<string>();
	} else {
		bind->alias = bind->remote_catalog;
	}
	auto token_it = input.named_parameters.find("token");
	if (token_it != input.named_parameters.end() && !token_it->second.IsNull()) {
		bind->token = token_it->second.GetValue<string>();
	}
	auto ssl_it = input.named_parameters.find("disable_ssl");
	if (ssl_it != input.named_parameters.end()) {
		bind->disable_ssl = ssl_it->second.GetValue<bool>();
	}

	ValidateIdentifier(bind->remote_catalog, "remote_catalog");
	ValidateIdentifier(bind->alias, "alias");

	return_types = {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR};
	names = {"local_view", "remote_table", "status"};
	return std::move(bind);
}

static void RemoteLakeAttachFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &bind = data_p.bind_data->CastNoConst<RemoteLakeAttachBindData>();
	if (bind.finished) {
		return;
	}

	Connection conn(*context.db);
	EnsureQuackLoaded(conn);

	RunStatement(conn, "CREATE SCHEMA IF NOT EXISTS " + bind.alias);

	const string list_sql =
	    StringUtil::Format("SELECT table_name FROM duckdb_tables() WHERE database_name = '%s' ORDER BY table_name",
	                       EscapeSqlString(bind.remote_catalog));
	const auto list_from = BuildQuackQueryFromClause(bind.quack_uri, list_sql, bind.token, bind.disable_ssl);

	auto tables = conn.Query(list_from);
	if (tables->HasError()) {
		throw InvalidInputException("attach_ducklake: could not list remote tables: %s", tables->GetError());
	}

	idx_t row_count = 0;
	for (idx_t row = 0; row < tables->RowCount(); row++) {
		auto table_name = tables->GetValue(0, row).ToString();
		if (table_name.empty()) {
			continue;
		}
		ValidateIdentifier(table_name, "remote table name");

		const string remote_select = StringUtil::Format("SELECT * FROM %s.%s", bind.remote_catalog, table_name);
		const string view_sql =
		    StringUtil::Format("CREATE OR REPLACE VIEW %s.%s AS %s", bind.alias, table_name,
		                       BuildQuackQueryFromClause(bind.quack_uri, remote_select, bind.token, bind.disable_ssl));

		RunStatement(conn, view_sql);
		bind.created_views.push_back(bind.alias + "." + table_name);
		row_count++;
	}

	if (row_count == 0) {
		throw InvalidInputException(
		    "attach_ducklake: no tables found in remote catalog '%s' (is DuckLake attached on the server?)",
		    bind.remote_catalog);
	}

	output.SetCardinality(row_count);
	for (idx_t row = 0; row < row_count; row++) {
		const auto &view_name = bind.created_views[row];
		const auto dot = view_name.find('.');
		const string table_only = dot == string::npos ? view_name : view_name.substr(dot + 1);
		output.SetValue(0, row, Value(view_name));
		output.SetValue(1, row, Value(StringUtil::Format("%s.%s", bind.remote_catalog, table_only)));
		output.SetValue(2, row, Value("created"));
	}

	bind.finished = true;
}

} // namespace

void RegisterAttachDucklakeFunctions(ExtensionLoader &loader) {
	TableFunction attach("attach_ducklake", {LogicalType::VARCHAR}, RemoteLakeAttachFunction, RemoteLakeAttachBind);
	attach.named_parameters["remote_catalog"] = LogicalType::VARCHAR;
	attach.named_parameters["alias"] = LogicalType::VARCHAR;
	attach.named_parameters["token"] = LogicalType::VARCHAR;
	attach.named_parameters["disable_ssl"] = LogicalType::BOOLEAN;
	loader.RegisterFunction(attach);
}

} // namespace duckdb
