// MapLibre's network file source for the Android build: plain HTTP/1.0 to this device.
//
// The app never lets MapLibre talk to the outside world: packs are read from files, and
// everything that comes from the network (traffic, the online raster map) is fetched by
// the Dart tile server on 127.0.0.1 and handed over from there. So instead of building
// curl and a TLS library for Android, this is the whole client: one non-blocking socket
// per request on the file-source thread's run loop, "Connection: close", the body is
// what arrives until the server closes. Any other host is refused.
#include <mln/storage/http_file_source.hpp>
#include <mln/storage/resource.hpp>
#include <mln/storage/resource_options.hpp>
#include <mln/storage/response.hpp>
#include <mln/util/async_request.hpp>
#include <mln/util/chrono.hpp>
#include <mln/util/client_options.hpp>
#include <mln/util/compression.hpp>
#include <mln/util/http_header.hpp>
#include <mln/util/run_loop.hpp>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

namespace mln {

class HTTPFileSource::Impl {
public:
    Impl(const ResourceOptions& resourceOptions_, const ClientOptions& clientOptions_)
        : resourceOptions(resourceOptions_.clone()),
          clientOptions(clientOptions_.clone()) {}

    std::mutex mutex;
    ResourceOptions resourceOptions;
    ClientOptions clientOptions;
};

namespace {

using Error = Response::Error;

// "http://127.0.0.1:<port>/<path>" -> port and path; false for anything else.
bool parseLoopbackUrl(const std::string& url, uint16_t& port, std::string& path) {
    static const char prefix[] = "http://127.0.0.1:";
    const std::size_t n = sizeof(prefix) - 1;
    if (url.compare(0, n, prefix) != 0) return false;
    const std::size_t slash = url.find('/', n);
    const std::string digits = url.substr(n, slash == std::string::npos ? std::string::npos : slash - n);
    if (digits.empty() || digits.size() > 5 || digits.find_first_not_of("0123456789") != std::string::npos) return false;
    const long value = std::strtol(digits.c_str(), nullptr, 10);
    if (value < 1 || value > 65535) return false;
    port = static_cast<uint16_t>(value);
    path = slash == std::string::npos ? "/" : url.substr(slash);
    return true;
}

// Value of a header (name in lower case) in the header block, or empty.
std::string headerValue(const std::string& headers, const char* name) {
    std::size_t line = headers.find("\r\n"); // skip the status line
    const std::size_t nameLength = std::strlen(name);
    while (line != std::string::npos && line + 2 < headers.size()) {
        const std::size_t start = line + 2;
        const std::size_t end = headers.find("\r\n", start);
        const std::size_t colon = headers.find(':', start);
        if (colon != std::string::npos && (end == std::string::npos || colon < end) && colon - start == nameLength) {
            bool same = true;
            for (std::size_t i = 0; i < nameLength && same; ++i) {
                same = std::tolower(static_cast<unsigned char>(headers[start + i])) == name[i];
            }
            if (same) {
                std::size_t from = colon + 1;
                while (from < headers.size() && headers[from] == ' ') ++from;
                return headers.substr(from, end == std::string::npos ? std::string::npos : end - from);
            }
        }
        line = end;
    }
    return {};
}

class LoopbackRequest final : public AsyncRequest {
public:
    LoopbackRequest(Resource resource_, FileSource::Callback callback_)
        : resource(std::move(resource_)),
          callback(std::move(callback_)),
          loop(util::RunLoop::Get()) {
        uint16_t port = 0;
        std::string path;
        if (!parseLoopbackUrl(resource.url, port, path)) {
            failLater(Error::Reason::Other, "only http://127.0.0.1 is reachable in this build: " + resource.url);
            return;
        }
        out = "GET " + path + " HTTP/1.0\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\nConnection: close\r\n";
        if (resource.priorEtag) out += "If-None-Match: " + *resource.priorEtag + "\r\n";
        out += "\r\n";

        fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) < 0) {
            failLater(Error::Reason::Connection, std::string("socket: ") + std::strerror(errno));
            return;
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 && errno != EINPROGRESS) {
            failLater(Error::Reason::Connection, std::string("connect: ") + std::strerror(errno));
            return;
        }
        watch(util::RunLoop::Event::Write);
    }

    ~LoopbackRequest() override {
        *alive = false;
        closeSocket();
    }

private:
    void watch(util::RunLoop::Event event) {
        watching = true;
        loop->addWatch(fd, event, [this](int, util::RunLoop::Event) { onReady(); });
    }

    void closeSocket() {
        if (watching) loop->removeWatch(fd);
        watching = false;
        if (fd >= 0) close(fd);
        fd = -1;
    }

    void onReady() {
        if (sent < out.size()) {
            const ssize_t n = send(fd, out.data() + sent, out.size() - sent, MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR) return;
                return finish(Error::Reason::Connection, std::string("send: ") + std::strerror(errno));
            }
            sent += static_cast<std::size_t>(n);
            if (sent == out.size()) watch(util::RunLoop::Event::Read);
            return;
        }
        char buffer[16384];
        for (;;) {
            const ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
            if (n > 0) {
                in.append(buffer, static_cast<std::size_t>(n));
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
            if (n < 0) return finish(Error::Reason::Connection, std::string("recv: ") + std::strerror(errno));
            return finish(Error::Reason::Success, {}); // closed by the server: complete
        }
    }

    // The callback must not run inside the constructor: the caller has no handle yet.
    void failLater(Error::Reason reason, std::string message) {
        loop->invoke([this, alive_ = alive, reason, message = std::move(message)] {
            if (*alive_) finish(reason, message);
        });
    }

    void finish(Error::Reason reason, const std::string& message) {
        closeSocket();
        Response response;
        if (reason != Error::Reason::Success) {
            response.error = std::make_unique<Error>(reason, message);
        } else {
            parse(response);
        }
        // The callback may delete this request.
        auto callback_ = callback;
        callback_(response);
    }

    void parse(Response& response) {
        const std::size_t headerEnd = in.find("\r\n\r\n");
        int status = 0;
        if (headerEnd == std::string::npos || in.compare(0, 5, "HTTP/") != 0) {
            response.error = std::make_unique<Error>(Error::Reason::Connection, "malformed HTTP response");
            return;
        }
        const std::size_t space = in.find(' ');
        if (space != std::string::npos && space < headerEnd) status = std::atoi(in.c_str() + space + 1);
        const std::string headers = in.substr(0, headerEnd + 2);
        std::string body = in.substr(headerEnd + 4);

        const std::string length = headerValue(headers, "content-length");
        if (!length.empty() && std::strtoull(length.c_str(), nullptr, 10) != body.size()) {
            response.error = std::make_unique<Error>(Error::Reason::Connection, "truncated HTTP response");
            return;
        }
        const std::string etag = headerValue(headers, "etag");
        if (!etag.empty()) response.etag = etag;
        const std::string cacheControl = headerValue(headers, "cache-control");
        if (!cacheControl.empty()) {
            const auto cc = http::CacheControl::parse(cacheControl);
            response.expires = cc.toTimePoint();
            response.mustRevalidate = cc.mustRevalidate;
        }

        if (status == 200 || status == 206) {
            if (headerValue(headers, "content-encoding") == "gzip" && !body.empty()) {
                try {
                    body = util::decompress(body);
                } catch (const std::exception& e) {
                    response.error = std::make_unique<Error>(Error::Reason::Other, std::string("gzip: ") + e.what());
                    return;
                }
            }
            response.data = std::make_shared<std::string>(std::move(body));
        } else if (status == 204 || (status == 404 && resource.kind == Resource::Kind::Tile)) {
            response.noContent = true;
        } else if (status == 304) {
            response.notModified = true;
        } else if (status == 404) {
            response.error = std::make_unique<Error>(Error::Reason::NotFound, "HTTP status code 404");
        } else if (status >= 500 && status < 600) {
            response.error = std::make_unique<Error>(Error::Reason::Server,
                                                     "HTTP status code " + std::to_string(status));
        } else {
            response.error = std::make_unique<Error>(Error::Reason::Other,
                                                     "HTTP status code " + std::to_string(status));
        }
    }

    Resource resource;
    FileSource::Callback callback;
    util::RunLoop* loop;
    std::shared_ptr<bool> alive = std::make_shared<bool>(true);
    int fd = -1;
    bool watching = false;
    std::string out, in;
    std::size_t sent = 0;
};

} // namespace

HTTPFileSource::HTTPFileSource(const ResourceOptions& resourceOptions, const ClientOptions& clientOptions)
    : impl(std::make_unique<Impl>(resourceOptions, clientOptions)) {}

HTTPFileSource::~HTTPFileSource() = default;

std::unique_ptr<AsyncRequest> HTTPFileSource::request(const Resource& resource, Callback callback) {
    return std::make_unique<LoopbackRequest>(resource, std::move(callback));
}

void HTTPFileSource::setResourceOptions(ResourceOptions options) {
    std::scoped_lock lock(impl->mutex);
    impl->resourceOptions = options.clone();
}

ResourceOptions HTTPFileSource::getResourceOptions() {
    std::scoped_lock lock(impl->mutex);
    return impl->resourceOptions.clone();
}

void HTTPFileSource::setClientOptions(ClientOptions options) {
    std::scoped_lock lock(impl->mutex);
    impl->clientOptions = options.clone();
}

ClientOptions HTTPFileSource::getClientOptions() {
    std::scoped_lock lock(impl->mutex);
    return impl->clientOptions.clone();
}

} // namespace mln
