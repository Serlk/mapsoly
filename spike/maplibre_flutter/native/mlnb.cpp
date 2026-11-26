// mlnb: MapLibre Native rendering into EGLImage-backed textures for a foreign GL context.
//
// Threads:
//   map thread ("mln-map")  owns the mln::Map, the RunLoop, the Renderer and a private
//                           EGL context (surfaceless, GLES 3). Renders into one of three
//                           FBO textures, waits for the GPU (fence), then publishes it.
//   consumer thread         (Flutter raster thread) calls mlnb_populate() with its own
//                           context current; gets a texture name bound to the EGLImage
//                           of the newest published frame.
//   any thread              camera calls; they are posted to the map thread.
//
// Pacing: three buffers - "front" (the consumer samples it), "ready" (finished, waiting
// to be picked up) and one more that the map renders the following frame into. A finished
// frame is held back until "ready" was picked up, so no frame is ever dropped and the map
// never renders faster than the consumer displays; it runs at most one frame ahead.
// MLNB_SERIAL=1 selects the simpler scheme the prototype started with (render only after
// the previous frame was picked up): about half the frame rate, see the doc.
// MLNB_BIG=1 pins the map thread to the CPUs with the highest capacity (big cores).
//
// Second mode (MLNB_MODE_SUBSURFACE, "route B"): no textures at all. The map renders to
// its own wl_surface, a desynchronised wl_subsurface placed BELOW the parent (GTK/Flutter)
// surface, which then has to be transparent where the map should show. Pacing is the
// compositor's frame callbacks (eglSwapBuffers, swap interval 1), exactly as in the
// standalone GLFW spike; Flutter is not involved in map frames.
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
#include <mln/storage/file_source.hpp>
#include <mln/storage/file_source_manager.hpp>
#include <mln/storage/resource_options.hpp>
#include <mln/style/style.hpp>
#include <mln/util/async_task.hpp>
#include <mln/util/client_options.hpp>
#include <mln/util/logging.hpp>
#include <mln/util/platform.hpp>
#include <mln/util/run_loop.hpp>
#include <mln/util/timer.hpp>

#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 1
#endif
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include <sched.h>

#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

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

struct Slot {
    // map context
    GLuint tex = 0, fbo = 0;
    // shared
    EGLImage img = EGL_NO_IMAGE;
    uint32_t w = 0, h = 0;
    uint64_t seq = 0;
    int64_t finishedUs = 0;
    // consumer context
    GLuint consumerTex = 0;
};
using SlotPtr = std::shared_ptr<Slot>;

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

class Backend final : public mln::gl::RendererBackend, public mln::gfx::Renderable {
public:
    Backend(void* wlDisplay, void* parentSurface, int mode, int scale_, mln::Size fbSize, mlnb_frame_cb cb_, void* user_)
        : mln::gl::RendererBackend(mln::gfx::ContextMode::Unique),
          mln::gfx::Renderable(fbSize, std::make_unique<Resource>(*this)),
          subsurfaceMode(mode == MLNB_MODE_SUBSURFACE),
          scale(scale_),
          wl(static_cast<wl_display*>(wlDisplay)),
          cb(cb_),
          user(user_) {
        dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wlDisplay, nullptr);
        if (dpy == EGL_NO_DISPLAY) throw std::runtime_error("mlnb: eglGetPlatformDisplay failed");
        EGLint major = 0, minor = 0;
        if (!eglInitialize(dpy, &major, &minor)) throw std::runtime_error("mlnb: eglInitialize failed");
        eglBindAPI(EGL_OPENGL_ES_API);
        const char* ext = eglQueryString(dpy, EGL_EXTENSIONS);
        std::fprintf(stderr, "MLNB egl %d.%d display=%p surfaceless=%d no_config=%d fence=%d gl_image=%d mode=%s\n", major,
                     minor, dpy, has(ext, "EGL_KHR_surfaceless_context"), has(ext, "EGL_KHR_no_config_context"),
                     has(ext, "EGL_KHR_fence_sync"), has(ext, "EGL_KHR_gl_texture_2D_image"),
                     subsurfaceMode ? "subsurface" : "texture");
        EGLConfig config = EGL_NO_CONFIG_KHR;
        if (subsurfaceMode) {
            // Opaque window config with the depth/stencil MapLibre needs in the default framebuffer.
            const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                    EGL_RED_SIZE,     8,              EGL_GREEN_SIZE,      8,
                                    EGL_BLUE_SIZE,    8,              EGL_ALPHA_SIZE,      0,
                                    EGL_DEPTH_SIZE,   24,             EGL_STENCIL_SIZE,    8,
                                    EGL_NONE};
            EGLint n = 0;
            if (!eglChooseConfig(dpy, attrs, &config, 1, &n) || n < 1)
                throw std::runtime_error("mlnb: no EGL window config");
        } else if (!has(ext, "EGL_KHR_no_config_context")) {
            const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                    EGL_BLUE_SIZE,       8,                  EGL_NONE};
            EGLint n = 0;
            eglChooseConfig(dpy, attrs, &config, 1, &n);
        }
        const EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE};
        ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttrs);
        if (ctx == EGL_NO_CONTEXT) throw std::runtime_error("mlnb: eglCreateContext failed");
        if (subsurfaceMode) createSubsurface(static_cast<wl_surface*>(parentSurface), config, fbSize);
        makeCurrent();
        if (subsurfaceMode) eglSwapInterval(dpy, std::getenv("MLNB_NOVSYNC") ? 0 : 1);
        std::fprintf(stderr, "MLNB map context: %s | %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    }

    ~Backend() override {
        makeCurrent();
        // Renderer and gl::Context are gone by now (owner resets them first).
        context.reset();
        destroySwapchain(true);
        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurface != EGL_NO_SURFACE) eglDestroySurface(dpy, eglSurface);
        if (eglWindow) wl_egl_window_destroy(eglWindow);
        if (subsurface) wl_subsurface_destroy(subsurface);
        if (surface) wl_surface_destroy(surface);
        if (subcompositor) wl_subcompositor_destroy(subcompositor);
        if (compositor) wl_compositor_destroy(compositor);
        if (wl) wl_display_flush(wl);
        if (queue) wl_event_queue_destroy(queue);
        eglDestroyContext(dpy, ctx);
        // No eglTerminate: the display belongs to the process (GDK, Flutter).
    }

    mln::gfx::Renderable& getDefaultRenderable() override { return *this; }

    void makeCurrent() { eglMakeCurrent(dpy, eglSurface, eglSurface, ctx); } // EGL_NO_SURFACE in texture mode

    // Route B: own wl_surface as a subsurface below the parent. All proxies live on a
    // private event queue so this thread never touches GDK's queue.
    void createSubsurface(wl_surface* parent, EGLConfig config, mln::Size fb) {
        if (!parent) throw std::runtime_error("mlnb: subsurface mode needs the parent wl_surface");
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
        if (!compositor || !subcompositor) throw std::runtime_error("mlnb: no wl_compositor/wl_subcompositor");

        surface = wl_compositor_create_surface(compositor);
        subsurface = wl_subcompositor_get_subsurface(subcompositor, surface, parent);
        wl_subsurface_set_position(subsurface, 0, 0);
        wl_subsurface_place_below(subsurface, parent); // takes effect on the parent's next commit
        wl_subsurface_set_desync(subsurface);          // map commits do not wait for GTK
        wl_region* empty = wl_compositor_create_region(compositor);
        wl_surface_set_input_region(surface, empty); // all input stays with the parent (Flutter)
        wl_region_destroy(empty);
        wl_region* all = wl_compositor_create_region(compositor);
        wl_region_add(all, 0, 0, INT32_MAX, INT32_MAX);
        wl_surface_set_opaque_region(surface, all);
        wl_region_destroy(all);
        wl_surface_set_buffer_scale(surface, scale);
        eglWindow = wl_egl_window_create(surface, static_cast<int>(fb.width), static_cast<int>(fb.height));
        eglSurface = eglCreatePlatformWindowSurface(dpy, config, eglWindow, nullptr);
        if (eglSurface == EGL_NO_SURFACE) throw std::runtime_error("mlnb: eglCreatePlatformWindowSurface failed");
        wl_display_flush(wl);
        std::fprintf(stderr, "MLNB subsurface %ux%u buffer scale %d\n", fb.width, fb.height, scale);
    }

    void setFbSize(mln::Size s) { setRenderableSize(s); }

    // Map thread, context current, outside of Renderer::render().
    void ensureSwapchain() {
        const mln::Size s = getSize();
        if (subsurfaceMode) {
            if (s.width != windowSize.width || s.height != windowSize.height) {
                wl_egl_window_resize(eglWindow, static_cast<int>(s.width), static_cast<int>(s.height), 0, 0);
                windowSize = s;
            }
            return;
        }
        if (slots[0] && slots[0]->w == s.width && slots[0]->h == s.height) return;
        GLint prevTex = 0, prevFbo = 0, prevRb = 0, prevUnit = 0;
        glGetIntegerv(GL_ACTIVE_TEXTURE, &prevUnit);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex);
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &prevRb);

        destroySwapchain(false);
        glGenRenderbuffers(1, &depthStencil);
        glBindRenderbuffer(GL_RENDERBUFFER, depthStencil);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, s.width, s.height);
        for (auto& sp : slots) {
            sp = std::make_shared<Slot>();
            sp->w = s.width;
            sp->h = s.height;
            glGenTextures(1, &sp->tex);
            glBindTexture(GL_TEXTURE_2D, sp->tex);
            glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, s.width, s.height);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glGenFramebuffers(1, &sp->fbo);
            glBindFramebuffer(GL_FRAMEBUFFER, sp->fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sp->tex, 0);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthStencil);
            const GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (st != GL_FRAMEBUFFER_COMPLETE) std::fprintf(stderr, "MLNB framebuffer incomplete: 0x%x\n", st);
            const EGLAttrib attrs[] = {EGL_GL_TEXTURE_LEVEL, 0, EGL_NONE};
            sp->img = eglCreateImage(dpy, ctx, EGL_GL_TEXTURE_2D,
                                     reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(sp->tex)), attrs);
            if (sp->img == EGL_NO_IMAGE) std::fprintf(stderr, "MLNB eglCreateImage failed: 0x%x\n", eglGetError());
        }
        back = 0;
        std::fprintf(stderr, "MLNB swapchain %ux%u\n", s.width, s.height);

        glBindTexture(GL_TEXTURE_2D, prevTex);
        glActiveTexture(prevUnit);
        glBindRenderbuffer(GL_RENDERBUFFER, prevRb);
        glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
        if (context) static_cast<mln::gl::Context&>(*context).setDirtyState();
    }

    void bindBack() {
        if (subsurfaceMode) {
            setFramebufferBinding(0);
            setViewport(0, 0, getSize());
            return;
        }
        if (back < 0) return; // not reached: render() is gated by canRender()
        setFramebufferBinding(slots[back]->fbo);
        setViewport(0, 0, getSize());
    }

    // End of a frame (called through gl::RenderableResource::swap()): wait until the GPU
    // has finished it, then park it as "held".
    void finishFrame() {
        const int64_t t0 = monoUs();
        if (subsurfaceMode) {
            eglSwapBuffers(dpy, eglSurface); // blocks for the compositor's frame callback
            lastGpuWaitMs = (monoUs() - t0) / 1000.0;
            ++seq;
            ++framesRendered;
            return;
        }
        EGLSync sync = eglCreateSync(dpy, EGL_SYNC_FENCE, nullptr);
        glFlush();
        if (sync != EGL_NO_SYNC) {
            eglClientWaitSync(dpy, sync, 0, 500000000 /* ns */);
            eglDestroySync(dpy, sync);
        } else {
            glFinish();
        }
        const int64_t t1 = monoUs();
        lastGpuWaitMs = (t1 - t0) / 1000.0;
        std::scoped_lock lock(mutex);
        held = slots[back];
        held->seq = ++seq;
        held->finishedUs = t1;
        back = -1;
        ++framesRendered;
    }

    // Map thread: hand the held frame to the consumer if the previous one was taken.
    void tryPublish() {
        if (subsurfaceMode) return;
        {
            std::scoped_lock lock(mutex);
            if (!held || ready) return;
            ready = std::move(held);
            held.reset();
            for (int i = 0; i < 3; ++i) {
                if (slots[i] != ready && slots[i] != front) {
                    back = i;
                    break;
                }
            }
            pending.store(true);
        }
        if (cb) cb(user);
    }

    // Map thread: is there a buffer to render the next frame into?
    bool canRender() const { return subsurfaceMode || (back >= 0 && !(serial && pending.load())); }

    const bool subsurfaceMode;

    // Consumer thread, consumer context current.
    int populate(uint32_t* target, uint32_t* name, uint32_t* w, uint32_t* h, bool& newFrame, uint64_t& seqOut,
                 int64_t& publishedUs) {
        SlotPtr cur;
        std::vector<SlotPtr> dead;
        newFrame = false;
        {
            std::scoped_lock lock(mutex);
            if (ready) {
                front = ready;
                ready.reset();
                newFrame = true;
                pending.store(false);
            }
            cur = front;
            for (auto it = garbage.begin(); it != garbage.end();) {
                if (*it != cur) {
                    dead.push_back(*it);
                    it = garbage.erase(it);
                } else {
                    ++it;
                }
            }
        }
        if (!consumerChecked) {
            consumerChecked = true;
            std::fprintf(stderr, "MLNB consumer context: display=%p (same as map: %s) ctx=%p | %s | %s\n",
                         eglGetCurrentDisplay(), eglGetCurrentDisplay() == dpy ? "yes" : "NO", eglGetCurrentContext(),
                         glGetString(GL_RENDERER), glGetString(GL_VERSION));
        }
        for (auto& d : dead) {
            if (d->consumerTex) glDeleteTextures(1, &d->consumerTex);
            if (d->img != EGL_NO_IMAGE) eglDestroyImage(dpy, d->img);
        }
        if (!cur) return 0;
        if (!cur->consumerTex) {
            GLint prev = 0;
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
            glGenTextures(1, &cur->consumerTex);
            glBindTexture(GL_TEXTURE_2D, cur->consumerTex);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            // Not exported by Mesa's libGLESv2; resolve through EGL.
            using TargetFn = void (*)(GLenum, GLeglImageOES);
            static const auto imageTargetTexture = reinterpret_cast<TargetFn>(
                eglGetProcAddress("glEGLImageTargetTexture2DOES"));
            if (imageTargetTexture) imageTargetTexture(GL_TEXTURE_2D, static_cast<GLeglImageOES>(cur->img));
            else std::fprintf(stderr, "MLNB no glEGLImageTargetTexture2DOES\n");
            const GLenum err = glGetError();
            if (err != GL_NO_ERROR) std::fprintf(stderr, "MLNB glEGLImageTargetTexture2DOES error 0x%x\n", err);
            glBindTexture(GL_TEXTURE_2D, prev);
        }
        *target = GL_TEXTURE_2D;
        *name = cur->consumerTex;
        *w = cur->w;
        *h = cur->h;
        seqOut = cur->seq;
        publishedUs = cur->finishedUs;
        return 1;
    }

    std::atomic<bool> pending{false}; // a published frame has not been picked up yet
    std::atomic<int64_t> framesRendered{0};
    double lastGpuWaitMs = 0;
    uint64_t seq = 0;

protected:
    void activate() override { makeCurrent(); }
    void deactivate() override {} // the context stays current on the map thread
    mln::gl::ProcAddress getExtensionFunctionPointer(const char* name) override { return eglGetProcAddress(name); }
    void updateAssumedState() override {}

private:
    static bool has(const char* exts, const char* e) { return exts && std::strstr(exts, e); }

    void destroySwapchain(bool final) {
        std::scoped_lock lock(mutex);
        for (auto& sp : slots) {
            if (!sp) continue;
            glDeleteFramebuffers(1, &sp->fbo);
            glDeleteTextures(1, &sp->tex); // storage lives on while the EGLImage does
            sp->fbo = sp->tex = 0;
            garbage.push_back(sp); // image + consumer texture are released by the consumer
            sp.reset();
        }
        if (depthStencil) glDeleteRenderbuffers(1, &depthStencil);
        depthStencil = 0;
        ready.reset();
        held.reset();
        pending.store(false);
        if (final) {
            // Consumer textures leak here (no consumer context); images can go.
            for (auto& g : garbage)
                if (g->img != EGL_NO_IMAGE) eglDestroyImage(dpy, g->img);
            garbage.clear();
            front.reset();
        }
    }

    const int scale;
    wl_display* wl = nullptr;
    wl_event_queue* queue = nullptr;
    wl_compositor* compositor = nullptr;
    wl_subcompositor* subcompositor = nullptr;
    wl_surface* surface = nullptr;
    wl_subsurface* subsurface = nullptr;
    wl_egl_window* eglWindow = nullptr;
    EGLSurface eglSurface = EGL_NO_SURFACE;
    mln::Size windowSize{0, 0};

    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    mlnb_frame_cb cb;
    void* user;
    GLuint depthStencil = 0;

    std::mutex mutex;
    std::array<SlotPtr, 3> slots;
    int back = 0; // -1 while a finished frame is held and no buffer is free
    SlotPtr ready, held, front;
    const bool serial = std::getenv("MLNB_SERIAL") != nullptr;
    std::vector<SlotPtr> garbage;
    bool consumerChecked = false;
};

void Resource::bind() {
    backend.bindBack();
}
void Resource::swap() {
    backend.finishFrame();
}

} // namespace

struct mlnb_map final : public mln::RendererFrontend, public mln::MapObserver {
    // --- configuration
    void* wlDisplay = nullptr;
    void* parentSurface = nullptr;
    int mode = MLNB_MODE_TEXTURE;
    std::string style, cachePath;
    int width = 0, height = 0;
    double ratio = 1;
    mlnb_frame_cb cb = nullptr;
    void* user = nullptr;

    // --- map thread state
    std::thread thread;
    mln::util::RunLoop* loop = nullptr;
    std::unique_ptr<Backend> backend;
    std::unique_ptr<mln::Renderer> renderer;
    std::unique_ptr<mln::Map> map;
    std::unique_ptr<mln::util::AsyncTask> asyncTick;
    std::shared_ptr<mln::UpdateParameters> updateParameters;
    bool dirty = false, inTick = false;
    BenchScript bench;
    std::string benchPrefix;

    // --- shared
    std::atomic<int> benchState{0};
    std::atomic<bool> recording{false};
    std::atomic<int64_t> framesConsumed{0};
    std::mutex logMutex;
    struct Consume {
        int64_t bootMs, monoUs;
        uint64_t seq;
        double latencyMs;
    };
    std::vector<Consume> consumeLog;
    std::vector<int64_t> paintLog;
    std::mutex camMutex;
    double cam[5] = {0, 0, 0, 0, 0};

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
    void onDidFinishRenderingFrame(const RenderFrameStatus& st) override { bench.onFrameStatus(st); }
    void onDidFailLoadingMap(mln::MapLoadError, const std::string& msg) override {
        std::fprintf(stderr, "MLNB map load failed: %s\n", msg.c_str());
    }
    void onDidFinishLoadingStyle() override { std::fprintf(stderr, "MLNB style loaded\n"); }

    void tick() {
        if (!map) return;
        inTick = true;
        backend->tryPublish();
        bool moved = false;
        if (bench.active() && backend->canRender()) {
            moved = bench.drive(*map);
            if (bench.done()) finishBench();
        }
        if (dirty && updateParameters && backend->canRender()) {
            render();
            backend->tryPublish();
        }
        inTick = false;
        // Keep going while there is something to draw and a buffer to draw into: in texture
        // mode this renders one frame ahead of the consumer, then waits for its pick-up;
        // in subsurface mode render() itself blocked for a vblank in eglSwapBuffers.
        if ((dirty || moved) && backend->canRender() && asyncTick) asyncTick->send();
    }

    void render() {
        const int64_t t0 = monoUs();
        mln::gfx::BackendScope guard{*backend, mln::gfx::BackendScope::ScopeType::Implicit};
        backend->ensureSwapchain();
        dirty = false;
        auto params = updateParameters;
        renderer->render(params);
        bench.frameDone((monoUs() - t0) / 1000.0, backend->lastGpuWaitMs, backend->seq);
        const auto c = map->getCameraOptions();
        std::scoped_lock lock(camMutex);
        if (c.center) {
            cam[0] = c.center->latitude();
            cam[1] = c.center->longitude();
        }
        cam[2] = c.zoom.value_or(0);
        cam[3] = c.bearing.value_or(0);
        cam[4] = c.pitch.value_or(0);
    }

    void finishBench() {
        recording.store(false);
        std::scoped_lock lock(logMutex);
        if (std::FILE* f = std::fopen((benchPrefix + ".consume.csv").c_str(), "w")) {
            std::fprintf(f, "boot_ms,mono_us,seq,latency_ms\n");
            for (auto& c : consumeLog)
                std::fprintf(f, "%lld,%lld,%llu,%.3f\n", static_cast<long long>(c.bootMs), static_cast<long long>(c.monoUs),
                             static_cast<unsigned long long>(c.seq), c.latencyMs);
            std::fclose(f);
        }
        if (std::FILE* f = std::fopen((benchPrefix + ".paint.csv").c_str(), "w")) {
            std::fprintf(f, "mono_us\n");
            for (auto t : paintLog) std::fprintf(f, "%lld\n", static_cast<long long>(t));
            std::fclose(f);
        }
        consumeLog.clear();
        paintLog.clear();
        benchState.store(2);
    }

    void run(std::promise<bool>& started) {
        mln::platform::setCurrentThreadName("mln-map");
        if (std::getenv("MLNB_BIG")) pinToBigCores();
        try {
            mln::util::RunLoop runLoop(mln::util::RunLoop::Type::New);
            loop = &runLoop;
            const mln::Size fb{static_cast<uint32_t>(std::lround(width * ratio)),
                               static_cast<uint32_t>(std::lround(height * ratio))};
            backend = std::make_unique<Backend>(wlDisplay, parentSurface, mode,
                                                static_cast<int>(std::lround(ratio)), fb, cb, user);
            renderer = std::make_unique<mln::Renderer>(*backend, static_cast<float>(ratio));

            mln::ResourceOptions resourceOptions;
            resourceOptions.withCachePath(cachePath);
            mln::ClientOptions clientOptions;
            if (auto net = mln::FileSourceManager::get()->getFileSource(mln::FileSourceType::Network, resourceOptions,
                                                                        clientOptions)) {
                net->setProperty("online-status", false); // everything is local
            }
            map = std::make_unique<mln::Map>(
                *this, *this,
                mln::MapOptions()
                    .withSize({static_cast<uint32_t>(width), static_cast<uint32_t>(height)})
                    .withPixelRatio(static_cast<float>(ratio)),
                resourceOptions, clientOptions);
            map->setBounds(mln::BoundOptions().withMaxPitch(60.0));
            map->jumpTo(mln::CameraOptions().withCenter(mln::LatLng{55.752, 37.616}).withZoom(14.0));
            map->getStyle().loadURL(style);

            asyncTick = std::make_unique<mln::util::AsyncTask>([this] { tick(); });
            mln::util::Timer timer; // polls the script while nothing invalidates the map
            timer.start(mln::Milliseconds(16), mln::Milliseconds(16), [this] {
                if (bench.active()) tick();
            });
            started.set_value(true);
            runLoop.run();

            timer.stop();
            asyncTick.reset();
            map.reset();
            renderer.reset();
            backend.reset();
            loop = nullptr;
        } catch (const std::exception& e) {
            std::fprintf(stderr, "MLNB map thread failed: %s\n", e.what());
            if (!loop || !map) {
                try {
                    started.set_value(false);
                } catch (...) {
                }
            }
        }
    }

    // Restrict the calling thread to the CPUs with the highest cpu_capacity.
    static void pinToBigCores() {
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
        if (count > 0 && count < n) {
            const int rc = sched_setaffinity(0, sizeof(set), &set);
            std::fprintf(stderr, "MLNB map thread pinned to %d big cores (capacity %ld): %s\n", count, best,
                         rc == 0 ? "ok" : "failed");
        }
    }

    template <class Fn>
    void post(Fn&& fn) {
        if (loop) loop->invoke(std::forward<Fn>(fn));
    }
};

extern "C" {

mlnb_map* mlnb_create(void* wl_display, void* parent_wl_surface, int mode, const char* style_url,
                      const char* cache_path, int width, int height, double pixel_ratio, mlnb_frame_cb cb,
                      void* user) {
    auto* m = new mlnb_map();
    m->wlDisplay = wl_display;
    m->parentSurface = parent_wl_surface;
    m->mode = mode;
    m->style = style_url ? style_url : "";
    if (m->style.find("://") == std::string::npos) m->style = "file://" + m->style;
    m->cachePath = cache_path && *cache_path ? cache_path : ":memory:";
    m->width = width < 1 ? 1 : width;
    m->height = height < 1 ? 1 : height;
    m->ratio = pixel_ratio > 0 ? pixel_ratio : 1.0;
    m->cb = cb;
    m->user = user;
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
    if (!m) return;
    m->post([m] { m->loop->stop(); });
    if (m->thread.joinable()) m->thread.join();
    delete m;
}

int mlnb_populate(mlnb_map* m, uint32_t* target, uint32_t* name, uint32_t* width, uint32_t* height) {
    if (!m || !m->backend) return 0;
    bool newFrame = false;
    uint64_t seq = 0;
    int64_t publishedUs = 0;
    const int ok = m->backend->populate(target, name, width, height, newFrame, seq, publishedUs);
    if (newFrame) {
        ++m->framesConsumed;
        if (m->recording.load()) {
            const int64_t now = monoUs();
            std::scoped_lock lock(m->logMutex);
            m->consumeLog.push_back({bootMs(), now, seq, (now - publishedUs) / 1000.0});
        }
        if (m->asyncTick) m->asyncTick->send(); // the map may render the next frame
    }
    return ok;
}

void mlnb_resize(mlnb_map* m, int width, int height) {
    m->post([m, width, height] {
        if (width < 1 || height < 1 || (width == m->width && height == m->height)) return;
        m->width = width;
        m->height = height;
        m->backend->setFbSize({static_cast<uint32_t>(std::lround(width * m->ratio)),
                               static_cast<uint32_t>(std::lround(height * m->ratio))});
        m->map->setSize({static_cast<uint32_t>(width), static_cast<uint32_t>(height)});
    });
}

void mlnb_set_camera(mlnb_map* m, double lat, double lon, double zoom, double bearing, double pitch, int duration_ms) {
    m->post([=] {
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

void mlnb_move_by(mlnb_map* m, double dx, double dy) {
    m->post([=] { m->map->moveBy(mln::ScreenCoordinate{dx, dy}); });
}

void mlnb_zoom_by(mlnb_map* m, double delta, double fx, double fy, int duration_ms) {
    m->post([=] {
        std::optional<mln::ScreenCoordinate> anchor;
        if (!std::isnan(fx) && !std::isnan(fy)) anchor = mln::ScreenCoordinate{fx, fy};
        m->map->scaleBy(std::pow(2.0, delta), anchor,
                        mln::AnimationOptions(mln::Milliseconds(duration_ms > 0 ? duration_ms : 0)));
    });
}

void mlnb_rotate_by(mlnb_map* m, double degrees, double fx, double fy) {
    m->post([=] {
        const auto cur = m->map->getCameraOptions();
        mln::CameraOptions c;
        c.withBearing(cur.bearing.value_or(0.0) + degrees);
        if (!std::isnan(fx) && !std::isnan(fy)) c.withAnchor(mln::ScreenCoordinate{fx, fy});
        m->map->jumpTo(c);
    });
}

void mlnb_set_gesture(mlnb_map* m, int in_progress) {
    m->post([=] { m->map->setGestureInProgress(in_progress != 0); });
}

void mlnb_get_camera(mlnb_map* m, double* out5) {
    std::scoped_lock lock(m->camMutex);
    std::memcpy(out5, m->cam, sizeof(m->cam));
}

void mlnb_bench_start(mlnb_map* m, const char* out_prefix) {
    std::string prefix = out_prefix ? out_prefix : "/tmp/mlnb";
    m->post([m, prefix] {
        if (m->bench.active()) return;
        m->benchPrefix = prefix;
        {
            std::scoped_lock lock(m->logMutex);
            m->consumeLog.clear();
            m->paintLog.clear();
            m->consumeLog.reserve(8192);
            m->paintLog.reserve(8192);
        }
        m->recording.store(true);
        m->benchState.store(1);
        m->bench.start(prefix + ".frames.csv");
        m->tick();
    });
}

int mlnb_bench_state(mlnb_map* m) {
    return m->benchState.load();
}

void mlnb_note_paint(mlnb_map* m) {
    if (!m || !m->recording.load()) return;
    const int64_t now = monoUs();
    std::scoped_lock lock(m->logMutex);
    m->paintLog.push_back(now);
}

void mlnb_get_stats(mlnb_map* m, int64_t* out2) {
    out2[0] = m->backend ? m->backend->framesRendered.load() : 0;
    out2[1] = m->backend && m->backend->subsurfaceMode ? out2[0] : m->framesConsumed.load();
}

} // extern "C"
