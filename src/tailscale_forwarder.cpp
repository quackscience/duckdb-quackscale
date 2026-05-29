#include "tailscale_forwarder.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/string_util.hpp"

#ifndef _WIN32
#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace duckdb {

namespace {

#ifndef _WIN32
void CloseFD(int fd) {
	if (fd >= 0) {
		close(fd);
	}
}

void RelayFDs(int a, int b) {
	char buf[65536];
	while (true) {
		pollfd fds[2];
		fds[0] = {a, POLLIN, 0};
		fds[1] = {b, POLLIN, 0};
		if (poll(fds, 2, 30000) < 0) {
			break;
		}
		if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
			break;
		}
		if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
			break;
		}
		bool progress = false;
		if (fds[0].revents & POLLIN) {
			auto n = read(a, buf, sizeof(buf));
			if (n <= 0) {
				break;
			}
			auto off = idx_t(0);
			while (off < idx_t(n)) {
				auto w = write(b, buf + off, size_t(n) - off);
				if (w <= 0) {
					goto done;
				}
				off += idx_t(w);
			}
			progress = true;
		}
		if (fds[1].revents & POLLIN) {
			auto n = read(b, buf, sizeof(buf));
			if (n <= 0) {
				break;
			}
			auto off = idx_t(0);
			while (off < idx_t(n)) {
				auto w = write(a, buf + off, size_t(n) - off);
				if (w <= 0) {
					goto done;
				}
				off += idx_t(w);
			}
			progress = true;
		}
		if (!progress && (fds[0].revents | fds[1].revents) == 0) {
			continue;
		}
	}
done:
	shutdown(a, SHUT_RDWR);
	shutdown(b, SHUT_RDWR);
	CloseFD(a);
	CloseFD(b);
}
#endif

} // namespace

TailscaleForwarder::~TailscaleForwarder() {
	Stop();
}

void TailscaleForwarder::Stop() {
	stop_requested = true;
#ifdef _WIN32
#else
	CloseFD(listen_fd);
	listen_fd = -1;
#endif
	if (accept_thread.joinable()) {
		accept_thread.join();
	}
	stop_requested = false;
	dial_fn = nullptr;
	dial_addr.clear();
	std::lock_guard<std::mutex> guard(status_mutex);
	status = QuackForwardStatus {};
}

QuackForwardStatus TailscaleForwarder::Status() const {
	std::lock_guard<std::mutex> guard(status_mutex);
	return status;
}

void TailscaleForwarder::Start(DialFn dial_fn_in, const string &remote_host, idx_t remote_port, idx_t local_port) {
#ifndef _WIN32
	if (remote_host.empty()) {
		throw InvalidInputException("tailscale_quack_forward: host must not be empty");
	}
	if (remote_port == 0 || remote_port > 65535) {
		throw InvalidInputException("tailscale_quack_forward: port must be between 1 and 65535");
	}
	if (local_port > 65535) {
		throw InvalidInputException("tailscale_quack_forward: local_port must be between 0 and 65535");
	}

	Stop();

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		throw IOException("tailscale_quack_forward: socket failed: %s", strerror(errno));
	}
	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	sockaddr_in addr {};
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (local_port != 0) {
		addr.sin_port = htons(static_cast<uint16_t>(local_port));
	}
	if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
		CloseFD(fd);
		throw IOException("tailscale_quack_forward: bind 127.0.0.1 failed: %s", strerror(errno));
	}

	socklen_t len = sizeof(addr);
	if (getsockname(fd, reinterpret_cast<sockaddr *>(&addr), &len) != 0) {
		CloseFD(fd);
		throw IOException("tailscale_quack_forward: getsockname failed: %s", strerror(errno));
	}
	auto bound_port = ntohs(addr.sin_port);
	if (bound_port == 0) {
		CloseFD(fd);
		throw IOException("tailscale_quack_forward: could not determine local listen port");
	}

	if (listen(fd, 128) != 0) {
		CloseFD(fd);
		throw IOException("tailscale_quack_forward: listen failed: %s", strerror(errno));
	}

	dial_fn = std::move(dial_fn_in);
	dial_addr = StringUtil::Format("%s:%d", remote_host, remote_port);
	listen_fd = fd;
	stop_requested = false;

	{
		std::lock_guard<std::mutex> guard(status_mutex);
		status.active = true;
		status.remote_host = remote_host;
		status.remote_port = remote_port;
		status.local_host = "127.0.0.1";
		status.local_port = bound_port;
		status.quack_uri = StringUtil::Format("quack:127.0.0.1:%d", bound_port);
	}

	accept_thread = std::thread([this]() { AcceptLoop(); });
#else
	(void)dial_fn_in;
	(void)remote_host;
	(void)remote_port;
	(void)local_port;
	throw NotImplementedException("tailscale_quack_forward is not supported on Windows");
#endif
}

void TailscaleForwarder::AcceptLoop() {
#ifdef _WIN32
#else
	const int fd = listen_fd;
	auto dial = dial_fn;
	auto dial_addr_copy = dial_addr;

	while (!stop_requested.load()) {
		sockaddr_in client_addr {};
		socklen_t client_len = sizeof(client_addr);
		int client_fd = accept(fd, reinterpret_cast<sockaddr *>(&client_addr), &client_len);
		if (client_fd < 0) {
			if (stop_requested.load()) {
				break;
			}
			if (errno == EINTR) {
				continue;
			}
			break;
		}

		std::thread([dial, dial_addr_copy, client_fd]() {
			int ts_fd = -1;
			if (!dial || dial("tcp", dial_addr_copy, &ts_fd) != 0 || ts_fd < 0) {
				CloseFD(client_fd);
				return;
			}
			RelayFDs(client_fd, ts_fd);
		}).detach();
	}
#endif
}

} // namespace duckdb
