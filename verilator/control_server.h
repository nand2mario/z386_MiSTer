#pragma once

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class ControlServer {
public:
	ControlServer() = default;
	~ControlServer();

	ControlServer(const ControlServer&) = delete;
	ControlServer& operator=(const ControlServer&) = delete;

	bool start(const std::string& bind_address, uint16_t port, std::string& error);
	void stop();
	std::vector<std::string> drain_commands();
	void update_status(uint64_t sim_time, int width, int height, uint8_t mouse_buttons);

private:
	void run();
	void handle_client(int client_fd);
	std::string status_line() const;

	std::atomic<bool> stopping_{false};
	std::atomic<int> listen_fd_{-1};
	std::atomic<int> client_fd_{-1};
	std::thread thread_;
	std::mutex commands_mutex_;
	std::deque<std::string> commands_;
	std::atomic<uint64_t> sim_time_{0};
	std::atomic<int> width_{0};
	std::atomic<int> height_{0};
	std::atomic<unsigned> mouse_buttons_{0};
};
