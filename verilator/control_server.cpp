#include "control_server.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <netinet/in.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

namespace {

constexpr size_t MAX_QUEUED_COMMANDS = 4096;
constexpr size_t MAX_PENDING_INPUT = 64 * 1024;

bool send_all(int fd, const std::string& text) {
	size_t offset = 0;
	while (offset < text.size()) {
		int flags = 0;
#ifdef MSG_NOSIGNAL
		flags = MSG_NOSIGNAL;
#endif
		ssize_t sent = send(fd, text.data() + offset, text.size() - offset, flags);
		if (sent < 0 && errno == EINTR) continue;
		if (sent <= 0) return false;
		offset += static_cast<size_t>(sent);
	}
	return true;
}

} // namespace

ControlServer::~ControlServer() {
	stop();
}

bool ControlServer::start(const std::string& bind_address, uint16_t port,
	                      std::string& error) {
	if (thread_.joinable()) {
		error = "control server is already running";
		return false;
	}

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		error = std::string("socket: ") + std::strerror(errno);
		return false;
	}

	int reuse = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

	sockaddr_in address{};
	address.sin_family = AF_INET;
	address.sin_port = htons(port);
	if (inet_pton(AF_INET, bind_address.c_str(), &address.sin_addr) != 1) {
		error = "invalid IPv4 control bind address: " + bind_address;
		close(fd);
		return false;
	}
	if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
		error = std::string("bind: ") + std::strerror(errno);
		close(fd);
		return false;
	}
	if (listen(fd, 4) < 0) {
		error = std::string("listen: ") + std::strerror(errno);
		close(fd);
		return false;
	}

	stopping_ = false;
	listen_fd_ = fd;
	thread_ = std::thread(&ControlServer::run, this);
	return true;
}

void ControlServer::stop() {
	stopping_ = true;
	int client = client_fd_.exchange(-1);
	if (client >= 0) {
		shutdown(client, SHUT_RDWR);
		close(client);
	}
	int listener = listen_fd_.exchange(-1);
	if (listener >= 0) {
		shutdown(listener, SHUT_RDWR);
		close(listener);
	}
	if (thread_.joinable()) thread_.join();
}

std::vector<std::string> ControlServer::drain_commands() {
	std::lock_guard<std::mutex> lock(commands_mutex_);
	std::vector<std::string> result(commands_.begin(), commands_.end());
	commands_.clear();
	return result;
}

void ControlServer::update_status(uint64_t sim_time, int width, int height,
	                              uint8_t mouse_buttons) {
	sim_time_ = sim_time;
	width_ = width;
	height_ = height;
	mouse_buttons_ = mouse_buttons;
}

std::string ControlServer::status_line() const {
	std::ostringstream out;
	out << "OK sim_time=" << sim_time_.load()
	    << " resolution=" << width_.load() << "x" << height_.load()
	    << " mouse_buttons=" << mouse_buttons_.load() << "\n";
	return out.str();
}

void ControlServer::run() {
	while (!stopping_) {
		int listener = listen_fd_.load();
		if (listener < 0) break;
		int client = accept(listener, nullptr, nullptr);
		if (client < 0) {
			if (errno == EINTR) continue;
			if (stopping_) break;
			continue;
		}
#ifdef SO_NOSIGPIPE
		int no_sigpipe = 1;
		setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
#endif
		client_fd_ = client;
		handle_client(client);
		if (client_fd_.exchange(-1) == client) close(client);
	}

	int listener = listen_fd_.exchange(-1);
	if (listener >= 0) close(listener);
}

void ControlServer::handle_client(int client_fd) {
	static const std::string help =
		"OK commands: mouse <dx> <dy> [buttons]; key <name> [press|down|up]; "
		"checkpoint; screenshot [path]; status; quit\n";
	std::string pending;
	char buffer[4096];

	while (!stopping_) {
		ssize_t received = recv(client_fd, buffer, sizeof(buffer), 0);
		if (received < 0 && errno == EINTR) continue;
		if (received <= 0) break;
		pending.append(buffer, static_cast<size_t>(received));
		if (pending.size() > MAX_PENDING_INPUT) {
			send_all(client_fd, "ERR input buffer too large\n");
			break;
		}

		size_t newline = 0;
		while ((newline = pending.find('\n')) != std::string::npos) {
			std::string line = pending.substr(0, newline);
			pending.erase(0, newline + 1);
			if (!line.empty() && line.back() == '\r') line.pop_back();
			if (line.empty()) continue;

			if (line == "status") {
				if (!send_all(client_fd, status_line())) return;
				continue;
			}
			if (line == "help") {
				if (!send_all(client_fd, help)) return;
				continue;
			}

			bool queued = false;
			{
				std::lock_guard<std::mutex> lock(commands_mutex_);
				if (commands_.size() < MAX_QUEUED_COMMANDS) {
					commands_.push_back(std::move(line));
					queued = true;
				}
			}
			if (!send_all(client_fd, queued ? "OK queued\n" : "ERR command queue full\n"))
				return;
		}
	}
}
