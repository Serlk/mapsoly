// mapsoly_valhalla: a minimal stand-in for `valhalla_service`.
//
// Alpine packages libvalhalla without its tools and services (the package is
// built with ENABLE_TOOLS=OFF / ENABLE_SERVICES=OFF), so there is no
// `valhalla_service` binary on the phone. This program links against the
// packaged libvalhalla.so and serves the same HTTP JSON API through
// valhalla::tyr::actor_t, which is what valhalla_service does internally.
//
// The same source is built for Android against a static libvalhalla made by
// tool/build_valhalla_android.sh, for the same reason: no service binary
// without prime_server.
//
// Command line is the same as upstream:
//   mapsoly_valhalla <config.json> [threads]
// The listen address is taken from httpd.service.listen ("tcp://host:port").
//
// Supported: POST /<action> with a JSON body, GET /<action>?json=<urlencoded>.
// Every response closes the connection. This is meant for a single local
// client on 127.0.0.1, not for exposure to a network.
//
// If MAPSOLY_EXIT_ON_STDIN_EOF=1 is set the process exits when its stdin is
// closed, so it never outlives the app that spawned it.

#include <valhalla/config.h>
#include <valhalla/exceptions.h>
#include <valhalla/tyr/actor.h>

#include <boost/property_tree/ptree.hpp>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

constexpr size_t kMaxHeader = 64 * 1024;
constexpr size_t kMaxBody = 32 * 1024 * 1024;
constexpr size_t kWorkerStack = 8 * 1024 * 1024;

using Action = std::string (valhalla::tyr::actor_t::*)(const std::string&,
                                                       const std::function<void()>*,
                                                       valhalla::Api*);

const std::unordered_map<std::string, Action>& actions() {
  using valhalla::tyr::actor_t;
  static const std::unordered_map<std::string, Action> map = {
      {"route", &actor_t::route},
      {"locate", &actor_t::locate},
      {"sources_to_targets", &actor_t::matrix},
      {"optimized_route", &actor_t::optimized_route},
      {"isochrone", &actor_t::isochrone},
      {"trace_route", &actor_t::trace_route},
      {"trace_attributes", &actor_t::trace_attributes},
      {"height", &actor_t::height},
      {"expansion", &actor_t::expansion},
      {"centroid", &actor_t::centroid},
      {"status", &actor_t::status},
  };
  return map;
}

std::string json_escape(const std::string& in) {
  std::string out;
  for (unsigned char c : in) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

std::string error_json(unsigned code, const std::string& message, unsigned http_code,
                       const std::string& http_message) {
  return "{\"error_code\":" + std::to_string(code) + ",\"error\":\"" + json_escape(message) +
         "\",\"status_code\":" + std::to_string(http_code) + ",\"status\":\"" +
         json_escape(http_message) + "\"}";
}

std::string url_decode(const std::string& in) {
  std::string out;
  for (size_t i = 0; i < in.size(); ++i) {
    if (in[i] == '%' && i + 2 < in.size() && std::isxdigit(in[i + 1]) &&
        std::isxdigit(in[i + 2])) {
      out += static_cast<char>(std::stoi(in.substr(i + 1, 2), nullptr, 16));
      i += 2;
    } else if (in[i] == '+') {
      out += ' ';
    } else {
      out += in[i];
    }
  }
  return out;
}

bool write_all(int fd, const char* data, size_t size) {
  while (size > 0) {
    ssize_t n = ::send(fd, data, size, MSG_NOSIGNAL);
    if (n <= 0) {
      return false;
    }
    data += n;
    size -= static_cast<size_t>(n);
  }
  return true;
}

void respond(int fd, unsigned code, const std::string& status, const std::string& body) {
  std::string head = "HTTP/1.1 " + std::to_string(code) + " " + status +
                     "\r\nContent-Type: application/json;charset=utf-8"
                     "\r\nAccess-Control-Allow-Origin: *"
                     "\r\nConnection: close"
                     "\r\nContent-Length: " +
                     std::to_string(body.size()) + "\r\n\r\n";
  if (write_all(fd, head.data(), head.size())) {
    write_all(fd, body.data(), body.size());
  }
}

// Reads one HTTP request. Returns false if the client sent garbage or left.
bool read_request(int fd, std::string& method, std::string& target, std::string& body) {
  std::string buf;
  char chunk[16 * 1024];
  size_t header_end = std::string::npos;
  while (header_end == std::string::npos) {
    ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
    if (n <= 0 || buf.size() + static_cast<size_t>(n) > kMaxHeader + kMaxBody) {
      return false;
    }
    buf.append(chunk, static_cast<size_t>(n));
    header_end = buf.find("\r\n\r\n");
    if (header_end == std::string::npos && buf.size() > kMaxHeader) {
      return false;
    }
  }
  std::string head = buf.substr(0, header_end);
  body = buf.substr(header_end + 4);

  size_t sp1 = head.find(' ');
  size_t sp2 = head.find(' ', sp1 + 1);
  if (sp1 == std::string::npos || sp2 == std::string::npos) {
    return false;
  }
  method = head.substr(0, sp1);
  target = head.substr(sp1 + 1, sp2 - sp1 - 1);

  size_t content_length = 0;
  size_t pos = head.find("\r\n");
  while (pos != std::string::npos) {
    size_t next = head.find("\r\n", pos + 2);
    std::string line = head.substr(pos + 2, next == std::string::npos ? next : next - pos - 2);
    size_t colon = line.find(':');
    if (colon != std::string::npos) {
      std::string name = line.substr(0, colon);
      for (auto& c : name) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
      }
      if (name == "content-length") {
        content_length = std::strtoul(line.c_str() + colon + 1, nullptr, 10);
      }
    }
    pos = next;
  }
  if (content_length > kMaxBody) {
    return false;
  }
  while (body.size() < content_length) {
    ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
    if (n <= 0) {
      return false;
    }
    body.append(chunk, static_cast<size_t>(n));
  }
  body.resize(content_length);
  return true;
}

void handle(int fd, valhalla::tyr::actor_t& actor) {
  std::string method, target, body;
  if (!read_request(fd, method, target, body)) {
    respond(fd, 400, "Bad Request", error_json(100, "Failed to parse request", 400, "Bad Request"));
    return;
  }
  std::string path = target, query;
  size_t q = target.find('?');
  if (q != std::string::npos) {
    path = target.substr(0, q);
    query = target.substr(q + 1);
  }
  while (!path.empty() && path.front() == '/') {
    path.erase(path.begin());
  }
  while (!path.empty() && path.back() == '/') {
    path.pop_back();
  }

  if (method != "POST" && method != "GET") {
    respond(fd, 405, "Method Not Allowed",
            error_json(101, "Try a POST or GET request instead", 405, "Method Not Allowed"));
    return;
  }
  auto action = actions().find(path);
  if (action == actions().end()) {
    respond(fd, 404, "Not Found",
            error_json(106, "Try any of: '/route' '/locate' '/trace_attributes' '/status'", 404,
                       "Not Found"));
    return;
  }
  if (body.empty()) {
    size_t start = 0;
    while (start < query.size()) {
      size_t amp = query.find('&', start);
      std::string pair = query.substr(start, amp == std::string::npos ? amp : amp - start);
      if (pair.rfind("json=", 0) == 0) {
        body = url_decode(pair.substr(5));
      }
      if (amp == std::string::npos) {
        break;
      }
      start = amp + 1;
    }
  }
  if (body.empty()) {
    body = "{}";
  }

  try {
    std::string result = (actor.*(action->second))(body, nullptr, nullptr);
    actor.cleanup();
    respond(fd, 200, "OK", result);
  } catch (const valhalla::valhalla_exception_t& e) {
    actor.cleanup();
    respond(fd, e.http_code, e.http_message,
            error_json(e.code, e.message, e.http_code, e.http_message));
  } catch (const std::exception& e) {
    actor.cleanup();
    respond(fd, 400, "Bad Request", error_json(199, e.what(), 400, "Bad Request"));
  }
}

class Queue {
public:
  void push(int fd) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      fds_.push_back(fd);
    }
    ready_.notify_one();
  }
  int pop() {
    std::unique_lock<std::mutex> lock(mutex_);
    ready_.wait(lock, [this] { return !fds_.empty(); });
    int fd = fds_.front();
    fds_.pop_front();
    return fd;
  }

private:
  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<int> fds_;
};

struct Worker {
  Queue* queue;
  valhalla::tyr::actor_t* actor;
};

// Serves queued connections forever; the signature is pthread's.
void* work(void* arg) {
  auto* worker = static_cast<Worker*>(arg);
  for (;;) {
    int fd = worker->queue->pop();
    handle(fd, *worker->actor);
    ::shutdown(fd, SHUT_WR);
    ::close(fd);
  }
  return nullptr;
}

} // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <config.json> [threads]\n", argv[0]);
    return 2;
  }
  if (std::strcmp(argv[1], "--version") == 0) {
    std::printf("mapsoly_valhalla (libvalhalla %s)\n", VALHALLA_PRINT_VERSION);
    return 0;
  }
  setvbuf(stdout, nullptr, _IOLBF, 0);

#ifndef __ANDROID__
  // musl gives new threads a 128 KiB stack by default; Valhalla needs far
  // more (trace_attributes overflowed it on aarch64). Match glibc's 8 MiB.
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, kWorkerStack);
  pthread_setattr_default_np(&attr);
  pthread_attr_destroy(&attr);
#endif
  std::signal(SIGPIPE, SIG_IGN);

  unsigned threads = argc > 2 ? static_cast<unsigned>(std::atoi(argv[2])) : 1;
  if (threads == 0) {
    threads = 1;
  }

  boost::property_tree::ptree config;
  std::string listen;
  try {
    config = valhalla::config(argv[1]);
    listen = config.get<std::string>("httpd.service.listen");
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot read config %s: %s\n", argv[1], e.what());
    return 1;
  }
  // "tcp://host:port"
  size_t scheme = listen.find("://");
  size_t colon = listen.rfind(':');
  if (scheme == std::string::npos || colon == std::string::npos || colon <= scheme + 2) {
    std::fprintf(stderr, "bad httpd.service.listen: %s\n", listen.c_str());
    return 1;
  }
  std::string host = listen.substr(scheme + 3, colon - scheme - 3);
  int port = std::atoi(listen.c_str() + colon + 1);
  if (host == "*") {
    host = "0.0.0.0";
  }

  int server = ::socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  ::setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
    std::fprintf(stderr, "bad listen host: %s\n", host.c_str());
    return 1;
  }
  if (::bind(server, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      ::listen(server, 64) != 0) {
    std::fprintf(stderr, "cannot listen on %s: %s\n", listen.c_str(), std::strerror(errno));
    return 1;
  }

  // Build every worker's actor before accepting, so a broken tile set fails
  // at start-up instead of on the first request.
  std::vector<std::unique_ptr<valhalla::tyr::actor_t>> actors;
  try {
    for (unsigned i = 0; i < threads; ++i) {
      actors.emplace_back(new valhalla::tyr::actor_t(config, false));
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot start valhalla: %s\n", e.what());
    return 1;
  }

  const char* watch_stdin = std::getenv("MAPSOLY_EXIT_ON_STDIN_EOF");
  if (watch_stdin != nullptr && std::strcmp(watch_stdin, "1") == 0) {
    std::thread([] {
      char buf[256];
      while (::read(STDIN_FILENO, buf, sizeof(buf)) > 0) {
      }
      std::_Exit(0);
    }).detach();
  }

  Queue queue;
  std::vector<Worker> workers(threads);
  for (unsigned i = 0; i < threads; ++i) {
    workers[i] = {&queue, actors[i].get()};
#ifdef __ANDROID__
    // bionic has no pthread_setattr_default_np and gives threads 1 MiB, so
    // the stack size has to be passed per thread, which std::thread cannot.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, kWorkerStack);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, &work, &workers[i]);
    pthread_attr_destroy(&attr);
    if (err != 0) {
      std::fprintf(stderr, "cannot start worker: %s\n", std::strerror(err));
      return 1;
    }
#else
    std::thread(&work, &workers[i]).detach();
#endif
  }

  std::printf("mapsoly_valhalla (libvalhalla %s) listening on %s with %u thread(s)\n",
              VALHALLA_PRINT_VERSION, listen.c_str(), threads);
  for (;;) {
    int fd = ::accept(server, nullptr, nullptr);
    if (fd < 0) {
      if (errno == EINTR) {
        continue;
      }
      std::fprintf(stderr, "accept failed: %s\n", std::strerror(errno));
      return 1;
    }
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    timeval timeout{30, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    queue.push(fd);
  }
}
