// mlnb: one MapLibre Native map in a Wayland subsurface below a parent surface.
//
// Threads:
//   map thread ("mln-map")  owns the mln::Map, its RunLoop, the Renderer, the EGL context
//                           and every Wayland proxy created here (private event queue).
//   any other thread        API calls; they are posted to the map thread.
//
// Pacing: one frame per compositor frame callback, in the order Mesa uses for swap
// interval 1: a frame is drawn first and only then, right before it is committed, the
// thread sleeps on the Wayland socket until the callback of the previous frame arrived.
// (Drawing only after the callback costs one render time of latency per frame and gave
// 30 FPS on niri.) Unlike Mesa's own wait this one is bounded (kFrameWaitMs): when the
// window is hidden the compositor slows or stops the callbacks; the map is then
// "stalled" and draws one frame per callback that does arrive, nothing more. Waiting on
// the socket, not in the run loop, matters: another thread (GTK) reads the same socket
// and only a thread that is polling it wakes up on time.
#include "mlnb.h"
#include "bench_script.hpp"

#include <mln/gfx/backend_scope.hpp>
#include <mln/gfx/renderable.hpp>
#include <mln/gl/renderable_resource.hpp>
#include <mln/gl/renderer_backend.hpp>
#include <mln/gl/context.hpp>
#include <mln/map/map.hpp>
#include <mln/map/map_observer.hpp>
#include <mln/map/map_options.hpp>
#include <mln/renderer/renderer.hpp>
#include <mln/renderer/renderer_frontend.hpp>
#include <mln/storage/resource_options.hpp>
#include <mln/style/conversion/geojson.hpp>
#include <mln/style/conversion/json.hpp>
#include <mln/style/conversion/layer.hpp>
#include <mln/style/conversion/source.hpp>
#include <mln/style/image.hpp>
#include <mln/style/layer.hpp>
#include <mln/style/source.hpp>
#include <mln/style/sources/geojson_source.hpp>
#include <mln/style/style.hpp>
#include <mln/util/async_task.hpp>
#include <mln/util/client_options.hpp>
#include <mln/util/image.hpp>
#include <mln/util/platform.hpp>
#include <mln/util/premultiply.hpp>
#include <mln/util/run_loop.hpp>
#include <mln/util/timer.hpp>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include <dlfcn.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <ucontext.h>
#include <unistd.h>
#include <unwind.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace {

int64_t monoUs() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}
int64_t bootMs() {
    timespec ts{};
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

class Backend;

class Resource final : public mln::gl::RenderableResource {
public:
    explicit Resource(Backend& b)
        : backend(b) {}
    void bind() override;
    void swap() override;

private:
    Backend& backend;
};

// EGL window surface on a wl_subsurface placed below the parent surface.
class Backend final : public mln::gl::RendererBackend, public mln::gfx::Renderable {
public:
    Backend(wl_display* display, wl_surface* parent, int x, int y, mln::Size fb, int scale_)
        : mln::gl::RendererBackend(mln::gfx::ContextMode::Unique),
          mln::gfx::Renderable(fb, std::make_unique<Resource>(*this)),
          wl(display),
          scale(scale_) {
        if (!wl || !parent) throw std::runtime_error("no wl_display / parent wl_surface");
        // The EGLDisplay of the process (GDK and Flutter use the same wl_display).
        dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl, nullptr);
        if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr))
            throw std::runtime_error("EGL display not available");
        eglBindAPI(EGL_OPENGL_ES_API);
        // Opaque window config with the depth/stencil MapLibre needs in the default framebuffer.
        const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                EGL_RED_SIZE,     8,              EGL_GREEN_SIZE,      8,
                                EGL_BLUE_SIZE,    8,              EGL_ALPHA_SIZE,      0,
                                EGL_DEPTH_SIZE,   24,             EGL_STENCIL_SIZE,    8,
                                EGL_NONE};
        EGLConfig config = nullptr;
        EGLint n = 0;
        if (!eglChooseConfig(dpy, attrs, &config, 1, &n) || n < 1) throw std::runtime_error("no EGL window config");
        const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
        ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttrs);
        if (ctx == EGL_NO_CONTEXT) throw std::runtime_error("eglCreateContext failed");

        // All proxies live on a private queue, so this thread never dispatches GDK's events.
        queue = wl_display_create_queue(wl);
        auto* wrapper = static_cast<wl_display*>(wl_proxy_create_wrapper(wl));
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(wrapper), queue);
        wl_registry* registry = wl_display_get_registry(wrapper);
        wl_proxy_wrapper_destroy(wrapper);
        static const wl_registry_listener listener = {
            [](void* data, wl_registry* reg, uint32_t name, const char* iface, uint32_t) {
                auto* self = static_cast<Backend*>(data);
                if (!std::strcmp(iface, wl_compositor_interface.name)) {
                    self->compositor = static_cast<wl_compositor*>(wl_registry_bind(reg, name, &wl_compositor_interface, 3));
                } else if (!std::strcmp(iface, wl_subcompositor_interface.name)) {
                    self->subcompositor = static_cast<wl_subcompositor*>(
                        wl_registry_bind(reg, name, &wl_subcompositor_interface, 1));
                }
            },
            [](void*, wl_registry*, uint32_t) {}};
        wl_registry_add_listener(registry, &listener, this);
        wl_display_roundtrip_queue(wl, queue);
        wl_registry_destroy(registry);
        if (!compositor || !subcompositor) throw std::runtime_error("no wl_compositor / wl_subcompositor");

        surface = wl_compositor_create_surface(compositor);
        subsurface = wl_subcompositor_get_subsurface(subcompositor, surface, parent);
        wl_subsurface_set_position(subsurface, x, y);
        wl_subsurface_place_below(subsurface, parent); // both apply on the parent's next commit
        wl_subsurface_set_desync(subsurface);          // map commits do not wait for the parent
        wl_region* empty = wl_compositor_create_region(compositor);
        wl_surface_set_input_region(surface, empty); // all input stays with the parent
        wl_region_destroy(empty);
        wl_region* all = wl_compositor_create_region(compositor);
        wl_region_add(all, 0, 0, INT32_MAX, INT32_MAX);
        wl_surface_set_opaque_region(surface, all);
        wl_region_destroy(all);
        wl_surface_set_buffer_scale(surface, scale);
        window = wl_egl_window_create(surface, static_cast<int>(fb.width), static_cast<int>(fb.height));
        windowSize = fb;
        eglSurface = eglCreatePlatformWindowSurface(dpy, config, window, nullptr);
        if (eglSurface == EGL_NO_SURFACE) throw std::runtime_error("eglCreatePlatformWindowSurface failed");
        makeCurrent();
        eglSwapInterval(dpy, 0); // pacing is done with frame callbacks, see swapBuffers()
        wl_display_flush(wl);
        std::fprintf(stderr, "mlnb: %s | %s | subsurface %ux%u scale %d\n", glGetString(GL_RENDERER),
                     glGetString(GL_VERSION), fb.width, fb.height, scale);
    }

    ~Backend() override {
        makeCurrent();
        context.reset(); // gl::Context of MapLibre (the Renderer is gone already)
        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurface != EGL_NO_SURFACE) eglDestroySurface(dpy, eglSurface);
        if (window) wl_egl_window_destroy(window);
        if (frameCallback) wl_callback_destroy(frameCallback);
        if (subsurface) wl_subsurface_destroy(subsurface);
        if (surface) wl_surface_destroy(surface);
        if (subcompositor) wl_subcompositor_destroy(subcompositor);
        if (compositor) wl_compositor_destroy(compositor);
        wl_display_flush(wl);
        if (queue) wl_event_queue_destroy(queue);
        if (ctx != EGL_NO_CONTEXT) eglDestroyContext(dpy, ctx);
        eglReleaseThread();
        // No eglTerminate: the display belongs to the process.
    }

    mln::gfx::Renderable& getDefaultRenderable() override { return *this; }

    void makeCurrent() { eglMakeCurrent(dpy, eglSurface, eglSurface, ctx); }

    void setGeometry(int x, int y, mln::Size fb) {
        wl_subsurface_set_position(subsurface, x, y); // applied with the parent's next commit
        setRenderableSize(fb);
        if (fb.width != windowSize.width || fb.height != windowSize.height) {
            wl_egl_window_resize(window, static_cast<int>(fb.width), static_cast<int>(fb.height), 0, 0);
            windowSize = fb;
        }
        wl_display_flush(wl);
    }

    // Unmaps the subsurface; the next swap maps it again.
    void hide() {
        wl_surface_attach(surface, nullptr, 0, 0);
        wl_surface_commit(surface);
        wl_display_flush(wl);
        if (frameCallback) {
            wl_callback_destroy(frameCallback);
            frameCallback = nullptr;
        }
        stalled = false;
    }

    // Reads the socket if nobody else is doing so, then runs this thread's handlers.
    void dispatch(bool readable) {
        if (readable) {
            if (wl_display_prepare_read_queue(wl, queue) == 0) {
                wl_display_read_events(wl);
            }
        }
        wl_display_dispatch_queue_pending(wl, queue);
    }

    int fd() const { return wl_display_get_fd(wl); }

    // Sleeps until the outstanding frame callback arrived or timeoutMs passed.
    void waitFrame(int timeoutMs) {
        const int64_t deadline = monoUs() + timeoutMs * 1000LL;
        while (frameCallback) {
            while (wl_display_prepare_read_queue(wl, queue) != 0) wl_display_dispatch_queue_pending(wl, queue);
            if (!frameCallback) {
                wl_display_cancel_read(wl);
                break;
            }
            wl_display_flush(wl);
            const int64_t left = (deadline - monoUs()) / 1000;
            pollfd pfd{wl_display_get_fd(wl), POLLIN, 0};
            if (left > 0 && poll(&pfd, 1, static_cast<int>(left)) > 0) {
                wl_display_read_events(wl);
            } else {
                wl_display_cancel_read(wl);
                wl_display_dispatch_queue_pending(wl, queue);
                break;
            }
            wl_display_dispatch_queue_pending(wl, queue);
        }
    }

    void bindDefault() {
        setFramebufferBinding(0);
        setViewport(0, 0, getSize());
    }

    // Presents the frame just drawn: waits (bounded) for the compositor to have taken the
    // previous one, then commits with a new frame callback request.
    void swapBuffers() {
        const int64_t t0 = monoUs();
        glFlush(); // let the GPU work while we wait
        waitFrame(kFrameWaitMs);
        stalled = frameCallback != nullptr;
        if (frameCallback) {
            wl_callback_destroy(frameCallback);
            frameCallback = nullptr;
        }
        frameCallback = wl_surface_frame(surface);
        static const wl_callback_listener listener = {[](void* data, wl_callback* cb, uint32_t) {
            auto* self = static_cast<Backend*>(data);
            wl_callback_destroy(cb);
            if (self->frameCallback == cb) self->frameCallback = nullptr;
            if (self->onFrame) self->onFrame();
        }};
        wl_callback_add_listener(frameCallback, &listener, this);
        eglSwapBuffers(dpy, eglSurface);
        lastSwapMs = (monoUs() - t0) / 1000.0;
    }

    // May a frame be drawn now? Not while the compositor is not taking frames.
    bool canRender() const { return !stalled || frameCallback == nullptr; }

    static constexpr int kFrameWaitMs = 50;
    bool stalled = false;
    std::function<void()> onFrame;
    double lastSwapMs = 0;

protected:
    void activate() override { makeCurrent(); }
    void deactivate() override {} // the context stays current on the map thread
    mln::gl::ProcAddress getExtensionFunctionPointer(const char* name) override { return eglGetProcAddress(name); }
    void updateAssumedState() override {}

private:
    wl_display* wl;
    const int scale;
    wl_event_queue* queue = nullptr;
    wl_compositor* compositor = nullptr;
    wl_subcompositor* subcompositor = nullptr;
    wl_surface* surface = nullptr;
    wl_subsurface* subsurface = nullptr;
    wl_egl_window* window = nullptr;
    wl_callback* frameCallback = nullptr;
    mln::Size windowSize{0, 0};
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    EGLSurface eglSurface = EGL_NO_SURFACE;
};

void Resource::bind() {
    backend.bindDefault();
}
void Resource::swap() {
    backend.swapBuffers();
}

// ---- crash diagnostics -------------------------------------------------------------
// A fault in native code takes the whole app down. So that it leaves a trace, a signal
// handler writes the signal, the last bridge call and a raw backtrace to stderr (the
// app's log), then lets the default action happen. Addresses are printed relative to
// their module: `addr2line -e <unstripped module> <offset>` resolves them.
std::atomic<const char*> g_lastCall{"(none)"};
struct sigaction g_oldActions[NSIG];

void writeStr(const char* s) {
    if (s) (void)!write(STDERR_FILENO, s, std::strlen(s));
}
void writeHex(uintptr_t v) {
    char buf[2 + sizeof(v) * 2 + 1];
    int n = 0;
    buf[n++] = '0';
    buf[n++] = 'x';
    bool started = false;
    for (int shift = static_cast<int>(sizeof(v) * 8) - 4; shift >= 0; shift -= 4) {
        const unsigned d = (v >> shift) & 0xf;
        if (d || started || shift == 0) {
            buf[n++] = static_cast<char>(d < 10 ? '0' + d : 'a' + d - 10);
            started = true;
        }
    }
    buf[n] = 0;
    writeStr(buf);
}

_Unwind_Reason_Code traceFrame(_Unwind_Context* ctx, void* arg) {
    int* count = static_cast<int*>(arg);
    const uintptr_t pc = _Unwind_GetIP(ctx);
    if (!pc || ++*count > 48) return _URC_END_OF_STACK;
    Dl_info info{};
    writeStr("mlnb:   ");
    if (dladdr(reinterpret_cast<void*>(pc), &info) && info.dli_fname) {
        writeStr(info.dli_fname);
        writeStr(" +");
        writeHex(pc - reinterpret_cast<uintptr_t>(info.dli_fbase));
        if (info.dli_sname) {
            writeStr(" ");
            writeStr(info.dli_sname);
        }
    } else {
        writeHex(pc);
    }
    writeStr("\n");
    return _URC_NO_REASON;
}

void onFatalSignal(int sig, siginfo_t* info, void* uctx) {
    writeStr("\nmlnb: fatal signal ");
    writeHex(static_cast<uintptr_t>(sig));
    writeStr(" at address ");
    writeHex(reinterpret_cast<uintptr_t>(info ? info->si_addr : nullptr));
    writeStr(", last bridge call: ");
    writeStr(g_lastCall.load());
    writeStr("\nmlnb: backtrace (module +offset):\n");
    int count = 0;
#if defined(__aarch64__)
    // The unwinder often stops at the signal frame: print where the fault happened
    // (program counter) and its caller (link register) from the saved registers first.
    if (uctx) {
        const auto& mc = static_cast<ucontext_t*>(uctx)->uc_mcontext;
        for (const uintptr_t pc : {static_cast<uintptr_t>(mc.pc), static_cast<uintptr_t>(mc.regs[30])}) {
            Dl_info info{};
            writeStr("mlnb:   ");
            if (dladdr(reinterpret_cast<void*>(pc), &info) && info.dli_fname) {
                writeStr(info.dli_fname);
                writeStr(" +");
                writeHex(pc - reinterpret_cast<uintptr_t>(info.dli_fbase));
                if (info.dli_sname) {
                    writeStr(" ");
                    writeStr(info.dli_sname);
                }
            } else {
                writeHex(pc);
            }
            writeStr("  (from the fault context)\n");
        }
    }
#endif
    _Unwind_Backtrace(traceFrame, &count);
    // Hand over to whoever was installed before (or the default action).
    const struct sigaction& old = g_oldActions[sig];
    if ((old.sa_flags & SA_SIGINFO) && old.sa_sigaction) {
        old.sa_sigaction(sig, info, uctx);
    } else if (old.sa_handler != SIG_DFL && old.sa_handler != SIG_IGN && old.sa_handler) {
        old.sa_handler(sig);
    } else {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

void installCrashHandler() {
    static std::once_flag once;
    std::call_once(once, [] {
        if (std::getenv("MLNB_NO_CRASH_HANDLER")) return;
        struct sigaction sa{};
        sa.sa_sigaction = onFatalSignal;
        sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_RESETHAND;
        sigemptyset(&sa.sa_mask);
        for (int sig : {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL}) sigaction(sig, &sa, &g_oldActions[sig]);
    });
}

#define MLNB_CALL() g_lastCall.store(__func__)

void pinToBigCores() {
    long cap[CPU_SETSIZE];
    long best = 0;
    int n = 0;
    for (; n < CPU_SETSIZE; ++n) {
        char path[96];
        std::snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpu_capacity", n);
        std::FILE* f = std::fopen(path, "r");
        if (!f) break;
        cap[n] = 0;
        if (std::fscanf(f, "%ld", &cap[n]) != 1) cap[n] = 0;
        std::fclose(f);
        if (cap[n] > best) best = cap[n];
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    int count = 0;
    for (int i = 0; i < n; ++i) {
        if (cap[i] == best) {
            CPU_SET(i, &set);
            ++count;
        }
    }
    if (count > 0 && count < n) sched_setaffinity(0, sizeof(set), &set);
}

} // namespace

struct mlnb_map final : public mln::RendererFrontend, public mln::MapObserver {
    // --- configuration (set before the thread starts)
    wl_display* wlDisplay = nullptr;
    wl_surface* parent = nullptr;
    int x = 0, y = 0, width = 1, height = 1, scale = 1;
    std::string cachePath;
    mlnb_event_cb cb = nullptr;

    // --- map thread state
    std::thread thread;
    mln::util::RunLoop* loop = nullptr;
    std::unique_ptr<Backend> backend;
    std::unique_ptr<mln::Renderer> renderer;
    std::unique_ptr<mln::Map> map;
    std::unique_ptr<mln::util::AsyncTask> asyncTick;
    std::unique_ptr<mln::util::Timer> pollTimer;
    std::shared_ptr<mln::UpdateParameters> updateParameters;
    bool dirty = false, inTick = false, visible = true, failed = false;
    int renderErrors = 0;
    static constexpr int kMaxRenderErrors = 20;
    int64_t styleGeneration = 0;
    bool styleAnnounced = true;
    BenchScript bench;
    bool benchWasActive = false;
    std::FILE* frameLog = nullptr;
    int64_t t0Us = monoUs(), lastFrameUs = 0;
    RenderFrameStatus lastStatus{};
    double lastEnc = 0, lastRend = 0;
    int lastDraw = 0;
    bool lastFull = false, lastRepaint = false;

    // --- shared
    std::atomic<int64_t> frames{0}, lastIntervalUs{0}, slowFrames{0};

    void emit(int32_t event, int64_t arg) {
        if (cb) cb(event, arg);
    }

    // The map cannot go on: stop drawing and tell the owner, who falls back.
    void fail(const char* why) {
        if (failed) return;
        failed = true;
        std::fprintf(stderr, "mlnb: map failed: %s\n", why);
        emit(MLNB_EVENT_MAP_FAILED, 0);
    }

    // RendererFrontend
    void reset() override { renderer.reset(); }
    void setObserver(mln::RendererObserver& o) override { renderer->setObserver(&o); }
    void update(std::shared_ptr<mln::UpdateParameters> p) override {
        updateParameters = std::move(p);
        dirty = true;
        if (!inTick && asyncTick) asyncTick->send();
    }
    const mln::TaggedScheduler& getThreadPool() const override { return backend->getThreadPool(); }

    // MapObserver
    void onDidFinishRenderingFrame(const RenderFrameStatus& st) override {
        bench.onFrameStatus(st);
        lastFull = st.mode == RenderMode::Full;
        lastRepaint = st.needsRepaint;
        if (st.renderingStats) {
            lastEnc = st.renderingStats->encodingTime * 1000.0;
            lastRend = st.renderingStats->renderingTime * 1000.0;
            lastDraw = st.renderingStats->numDrawCalls;
        }
    }
    void onDidFailLoadingMap(mln::MapLoadError, const std::string& msg) override {
        std::fprintf(stderr, "mlnb: map load failed: %s\n", msg.c_str());
        if (!styleAnnounced) {
            styleAnnounced = true;
            emit(MLNB_EVENT_STYLE_FAILED, styleGeneration);
        }
    }
    void onDidFinishLoadingStyle() override {
        if (!styleAnnounced) {
            styleAnnounced = true;
            emit(MLNB_EVENT_STYLE_LOADED, styleGeneration);
        }
    }

    void tick() {
        if (!map) return;
        inTick = true;
        backend->dispatch(false);
        bool moved = false;
        if (bench.active() && visible && backend->canRender()) moved = bench.drive(*map);
        if (benchWasActive && !bench.active()) {
            benchWasActive = false;
            emit(MLNB_EVENT_BENCH_DONE, 0);
        }
        if (visible && dirty && updateParameters && backend->canRender() && !failed) {
            // MapLibre throws from deep inside a frame now and then (seen: "out of range
            // destination coordinates for image copy" from its pattern atlas). One bad
            // frame must not end the map: log it and draw the next one.
            try {
                render();
                renderErrors = 0;
            } catch (const std::exception& e) {
                std::fprintf(stderr, "mlnb: frame failed: %s\n", e.what());
                dirty = true;
                if (++renderErrors >= kMaxRenderErrors) fail("too many failed frames");
            }
        }
        inTick = false;
        // Keep going while something moves; the pace is set by the wait in the swap.
        if (visible && (dirty || moved) && backend->canRender() && asyncTick) asyncTick->send();
    }

    void render() {
        const int64_t start = monoUs();
        mln::gfx::BackendScope guard{*backend, mln::gfx::BackendScope::ScopeType::Implicit};
        dirty = false;
        auto params = updateParameters;
        renderer->render(params);
        const int64_t now = monoUs();
        const double frameMs = (now - start) / 1000.0;
        const int64_t interval = lastFrameUs ? now - lastFrameUs : 0;
        lastFrameUs = now;
        ++frames;
        lastIntervalUs.store(interval);
        if (interval > 33400 && interval < 200000) ++slowFrames;
        if (bench.active()) {
            bench.frameDone(frameMs, backend->lastSwapMs, static_cast<unsigned long long>(frames.load()));
        } else if (frameLog) {
            const auto c = map->getCameraOptions();
            std::fprintf(frameLog, "%lld,%.2f,app,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%.3f,%.5f,%.5f,%.3f,%lld\n",
                         static_cast<long long>(bootMs()), (now - t0Us) / 1000.0, interval / 1000.0, frameMs, lastEnc,
                         lastRend, lastDraw, lastFull ? 1 : 0, lastRepaint ? 1 : 0, c.zoom.value_or(0),
                         c.center ? c.center->latitude() : 0, c.center ? c.center->longitude() : 0, backend->lastSwapMs,
                         static_cast<long long>(frames.load()));
        }
        backend->dispatch(false);
    }

    void run(std::promise<bool>& started) {
        mln::platform::setCurrentThreadName("mln-map");
        if (!std::getenv("MLNB_NO_PIN")) pinToBigCores();
        bool announced = false;
        try {
            mln::util::RunLoop runLoop(mln::util::RunLoop::Type::New);
            const mln::Size fb{static_cast<uint32_t>(width * scale), static_cast<uint32_t>(height * scale)};
            backend = std::make_unique<Backend>(wlDisplay, parent, x, y, fb, scale);
            renderer = std::make_unique<mln::Renderer>(*backend, static_cast<float>(scale));
            mln::ResourceOptions resourceOptions;
            resourceOptions.withCachePath(cachePath);
            map = std::make_unique<mln::Map>(
                *this, *this,
                mln::MapOptions()
                    .withSize({static_cast<uint32_t>(width), static_cast<uint32_t>(height)})
                    .withPixelRatio(static_cast<float>(scale)),
                resourceOptions, mln::ClientOptions());
            map->setBounds(mln::BoundOptions().withMinZoom(1.0).withMaxZoom(20.0).withMaxPitch(60.0));

            asyncTick = std::make_unique<mln::util::AsyncTask>([this] { tick(); });
            backend->onFrame = [this] {
                if (asyncTick) asyncTick->send();
            };
            // Wayland events for this thread's queue: the socket ...
            runLoop.addWatch(backend->fd(), mln::util::RunLoop::Event::Read, [this](int, mln::util::RunLoop::Event) {
                backend->dispatch(true);
            });
            // ... and a slow poll, because another thread (GTK) may have read our events
            // off the socket while this one was busy; also drives the benchmark script.
            pollTimer = std::make_unique<mln::util::Timer>();
            pollTimer->start(mln::Milliseconds(8), mln::Milliseconds(8), [this] {
                if (backend->stalled || bench.active()) tick();
            });
            {
                std::scoped_lock lock(postMutex);
                loop = &runLoop;
            }
            announced = true;
            started.set_value(true);
            // An exception from a loop callback (not a frame) is survived a few times too.
            for (int errors = 0;;) {
                try {
                    runLoop.run();
                    break;
                } catch (const std::exception& e) {
                    std::fprintf(stderr, "mlnb: map loop: %s\n", e.what());
                    inTick = false;
                    if (++errors == 5) fail("too many errors in the map loop");
                }
            }

            {
                std::scoped_lock lock(postMutex);
                loop = nullptr;
            }
            runLoop.removeWatch(backend->fd());
            pollTimer.reset();
            asyncTick.reset();
            map.reset();
            renderer.reset();
            backend.reset();
        } catch (const std::exception& e) {
            std::fprintf(stderr, "mlnb: map thread failed: %s\n", e.what());
            {
                std::scoped_lock lock(postMutex);
                loop = nullptr;
            }
            if (announced) emit(MLNB_EVENT_MAP_FAILED, 0);
            map.reset();
            renderer.reset();
            backend.reset();
            if (!announced) started.set_value(false);
        }
        if (frameLog) std::fclose(frameLog);
        frameLog = nullptr;
    }

    template <class Fn>
    void post(Fn&& fn) {
        std::scoped_lock lock(postMutex);
        if (loop) {
            loop->invoke([this, fn = std::forward<Fn>(fn)]() mutable {
                if (!map || !backend) return;
                try {
                    fn();
                } catch (const std::exception& e) {
                    std::fprintf(stderr, "mlnb: %s: %s\n", g_lastCall.load(), e.what());
                }
            });
        }
    }
    std::mutex postMutex; // guards `loop` against a post racing with shutdown

    template <class T, class... Args>
    static std::optional<T> parse(const char* what, const std::string& json, Args&&... args) {
        mln::style::conversion::Error error;
        auto v = mln::style::conversion::convertJSON<T>(json, error, std::forward<Args>(args)...);
        if (!v) std::fprintf(stderr, "mlnb: bad %s: %s\n", what, error.message.c_str());
        return v;
    }
};

extern "C" {

int32_t mlnb_abi_version(void) {
    return MLNB_ABI_VERSION;
}

mlnb_map* mlnb_create(void* wl_display_, void* parent_wl_surface, int32_t x, int32_t y, int32_t width, int32_t height,
                      int32_t scale, const char* cache_path, mlnb_event_cb cb) {
    MLNB_CALL();
    installCrashHandler();
    auto* m = new mlnb_map();
    m->wlDisplay = static_cast<wl_display*>(wl_display_);
    m->parent = static_cast<wl_surface*>(parent_wl_surface);
    m->x = x;
    m->y = y;
    m->width = width < 1 ? 1 : width;
    m->height = height < 1 ? 1 : height;
    m->scale = scale < 1 ? 1 : scale;
    m->cachePath = cache_path && *cache_path ? cache_path : ":memory:";
    m->cb = cb;
    std::promise<bool> started;
    auto fut = started.get_future();
    m->thread = std::thread([m, &started] { m->run(started); });
    if (!fut.get()) {
        m->thread.join();
        delete m;
        return nullptr;
    }
    return m;
}

void mlnb_destroy(mlnb_map* m) {
    MLNB_CALL();
    if (!m) return;
    {
        std::scoped_lock lock(m->postMutex);
        if (m->loop) {
            auto* loop = m->loop;
            loop->invoke([loop] { loop->stop(); });
        }
    }
    if (m->thread.joinable()) m->thread.join();
    delete m;
}

void mlnb_set_geometry(mlnb_map* m, int32_t x, int32_t y, int32_t width, int32_t height) {
    MLNB_CALL();
    m->post([=] {
        if (width < 1 || height < 1) return;
        m->x = x;
        m->y = y;
        const bool resized = width != m->width || height != m->height;
        m->width = width;
        m->height = height;
        m->backend->setGeometry(x, y,
                                {static_cast<uint32_t>(width * m->scale), static_cast<uint32_t>(height * m->scale)});
        if (resized) m->map->setSize({static_cast<uint32_t>(width), static_cast<uint32_t>(height)});
    });
}

void mlnb_set_visible(mlnb_map* m, int32_t visible) {
    MLNB_CALL();
    m->post([=] {
        const bool v = visible != 0;
        if (v == m->visible) return;
        m->visible = v;
        if (!v) {
            m->backend->hide();
        } else {
            m->dirty = true;
            m->map->triggerRepaint();
            if (m->asyncTick) m->asyncTick->send();
        }
    });
}

void mlnb_set_style_json(mlnb_map* m, const char* json, int64_t generation) {
    MLNB_CALL();
    std::string s = json ? json : "";
    m->post([m, s = std::move(s), generation] {
        m->styleGeneration = generation;
        m->styleAnnounced = false;
        m->map->getStyle().loadJSON(s);
    });
}

void mlnb_set_camera(mlnb_map* m, double lat, double lon, double zoom, double bearing, double pitch,
                     int32_t duration_ms) {
    MLNB_CALL();
    m->post([=] {
        if (m->bench.active()) return;
        mln::CameraOptions c;
        if (!std::isnan(lat) && !std::isnan(lon)) c.withCenter(mln::LatLng{lat, lon});
        if (!std::isnan(zoom)) c.withZoom(zoom);
        if (!std::isnan(bearing)) c.withBearing(bearing);
        if (!std::isnan(pitch)) c.withPitch(pitch);
        if (duration_ms > 0) {
            m->map->easeTo(c, mln::AnimationOptions(mln::Milliseconds(duration_ms)));
        } else {
            m->map->jumpTo(c);
        }
    });
}

void mlnb_add_source(mlnb_map* m, const char* id, const char* json) {
    MLNB_CALL();
    std::string i = id ? id : "", s = json ? json : "";
    m->post([m, i = std::move(i), s = std::move(s)] {
        auto& style = m->map->getStyle();
        if (style.getSource(i)) return;
        auto src = mlnb_map::parse<std::unique_ptr<mln::style::Source>>("source", s, i);
        if (src) style.addSource(std::move(*src));
    });
}

void mlnb_remove_source(mlnb_map* m, const char* id) {
    MLNB_CALL();
    std::string i = id ? id : "";
    m->post([m, i = std::move(i)] {
        if (m->map->getStyle().getSource(i)) m->map->getStyle().removeSource(i);
    });
}

void mlnb_add_layer(mlnb_map* m, const char* json, const char* before_id) {
    MLNB_CALL();
    std::string s = json ? json : "", b = before_id ? before_id : "";
    m->post([m, s = std::move(s), b = std::move(b)] {
        auto& style = m->map->getStyle();
        auto layer = mlnb_map::parse<std::unique_ptr<mln::style::Layer>>("layer", s);
        if (!layer) return;
        if (style.getLayer((*layer)->getID())) style.removeLayer((*layer)->getID());
        try {
            if (!b.empty() && style.getLayer(b)) {
                style.addLayer(std::move(*layer), b);
            } else {
                style.addLayer(std::move(*layer));
            }
        } catch (const std::exception& e) {
            std::fprintf(stderr, "mlnb: add layer: %s\n", e.what());
        }
    });
}

void mlnb_remove_layer(mlnb_map* m, const char* id) {
    MLNB_CALL();
    std::string i = id ? id : "";
    m->post([m, i = std::move(i)] {
        if (m->map->getStyle().getLayer(i)) m->map->getStyle().removeLayer(i);
    });
}

void mlnb_set_geojson(mlnb_map* m, const char* source_id, const char* geojson) {
    MLNB_CALL();
    std::string i = source_id ? source_id : "", s = geojson ? geojson : "";
    m->post([m, i = std::move(i), s = std::move(s)] {
        auto* src = m->map->getStyle().getSource(i);
        auto* gj = src ? src->as<mln::style::GeoJSONSource>() : nullptr;
        if (!gj) return;
        auto data = mlnb_map::parse<mln::GeoJSON>("geojson", s);
        if (data) gj->setGeoJSON(*data);
    });
}

void mlnb_add_image(mlnb_map* m, const char* id, const uint8_t* rgba, int32_t width, int32_t height,
                    double pixel_ratio) {
    MLNB_CALL();
    if (!rgba || width < 1 || height < 1) return;
    std::string i = id ? id : "";
    auto pixels = std::make_shared<mln::UnassociatedImage>(
        mln::Size{static_cast<uint32_t>(width), static_cast<uint32_t>(height)}, rgba,
        static_cast<std::size_t>(width) * height * 4);
    m->post([m, i = std::move(i), pixels, pixel_ratio] {
        m->map->getStyle().addImage(std::make_unique<mln::style::Image>(
            i, mln::util::premultiply(std::move(*pixels)), static_cast<float>(pixel_ratio)));
    });
}

void mlnb_get_stats(mlnb_map* m, int64_t* out3) {
    out3[0] = m->frames.load();
    out3[1] = m->lastIntervalUs.load();
    out3[2] = m->slowFrames.load();
}

void mlnb_frame_log(mlnb_map* m, const char* csv_path) {
    MLNB_CALL();
    std::string p = csv_path ? csv_path : "";
    m->post([m, p = std::move(p)] {
        if (m->frameLog) std::fclose(m->frameLog);
        m->frameLog = p.empty() ? nullptr : std::fopen(p.c_str(), "w");
        if (m->frameLog) {
            std::setvbuf(m->frameLog, nullptr, _IOLBF, 0);
            std::fprintf(m->frameLog, "boot_ms,t_ms,seg,interval_ms,frame_ms,enc_ms,rend_ms,drawcalls,full,repaint,zoom,lat,lon,gpuwait_ms,seq\n");
        }
    });
}

void mlnb_bench_start(mlnb_map* m, const char* out_prefix) {
    MLNB_CALL();
    std::string prefix = out_prefix ? out_prefix : "/tmp/mlnb";
    m->post([m, prefix = std::move(prefix)] {
        if (m->bench.active()) return;
        m->bench.start(prefix + ".frames.csv");
        m->benchWasActive = true;
        m->tick();
    });
}

} // extern "C"
