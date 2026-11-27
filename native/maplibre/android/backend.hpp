// The Android rendering backend of mlnb: an EGL window surface on an ANativeWindow.
// Included by mlnb.cpp, inside its anonymous namespace, in place of the Wayland backend.
//
// The window is the producer side of a Flutter external texture (a `Surface` from
// `TextureRegistry.createSurfaceProducer()`, see MapSurface.kt), so the map becomes part
// of Flutter's own scene: Flutter composites it, clips it and blurs it under glass
// surfaces like any other layer. What that changes compared with the Wayland backend:
//
//  - The window comes and goes. Android takes the surface away while the app is in the
//    background and hands out a new one afterwards, and a resize gives a new one too.
//    The EGL context, and with it everything MapLibre uploaded, stays; without a window
//    the context is current on a 1x1 pbuffer and nothing is drawn.
//  - Pacing. Nothing blocks in eglSwapBuffers here (the consumer is Flutter's raster
//    thread, not the display; swap interval 0 never waits for it), so frames are paced by
//    the display's vsync from AChoreographer: one frame per vsync, drawn right after it.
//  - No blur pass: Flutter's BackdropFilter reaches the texture.
class Vsync {
public:
    explicit Vsync(std::function<void()> onVsync_)
        : onVsync(std::move(onVsync_)) {
        std::promise<void> ready;
        thread = std::thread([this, &ready] {
            pthread_setname_np(pthread_self(), "mln-vsync");
            looper = ALooper_prepare(0);
            ALooper_acquire(looper);
            choreographer = AChoreographer_getInstance();
            ready.set_value();
            while (!quit.load()) {
                // Returns after a wake() and after it ran choreographer callbacks.
                ALooper_pollOnce(-1, nullptr, nullptr, nullptr);
                if (wanted.exchange(false) && choreographer && !quit.load()) {
                    // (The 64-bit-timestamp variant needs API 29; the app supports 24.)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    AChoreographer_postFrameCallback(choreographer, &Vsync::frame, this);
#pragma clang diagnostic pop
                }
            }
            ALooper_release(looper);
        });
        ready.get_future().wait();
    }

    ~Vsync() {
        quit.store(true);
        ALooper_wake(looper);
        thread.join();
    }

    // Asks for one call of onVsync (on the vsync thread) at the next vsync.
    void request() {
        wanted.store(true);
        ALooper_wake(looper);
    }

private:
    static void frame(long, void* data) {
        auto* self = static_cast<Vsync*>(data);
        if (!self->quit.load()) self->onVsync();
    }

    std::function<void()> onVsync;
    std::thread thread;
    ALooper* looper = nullptr;
    AChoreographer* choreographer = nullptr;
    std::atomic<bool> wanted{false}, quit{false};
};

class Backend final : public mln::gl::RendererBackend, public mln::gfx::Renderable {
public:
    // Takes over the caller's reference to `window` (may be null: no surface yet).
    Backend(ANativeWindow* window, mln::Size fb)
        : mln::gl::RendererBackend(mln::gfx::ContextMode::Unique),
          mln::gfx::Renderable(fb, std::make_unique<Resource>(*this)),
          vsync(std::make_unique<Vsync>([this] {
              waitingVsync.store(false);
              if (onFrame) onFrame();
          })) {
        dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        // Reference counted per process: Flutter's own use of the display is unaffected.
        if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
            if (window) ANativeWindow_release(window);
            throw std::runtime_error("EGL display not available");
        }
        eglBindAPI(EGL_OPENGL_ES_API);
        // RGBA 8888 is what a texture producer's buffers are; depth/stencil for MapLibre.
        const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                                EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
                                EGL_NONE};
        EGLint n = 0;
        if (!eglChooseConfig(dpy, attrs, &config, 1, &n) || n < 1) {
            if (window) ANativeWindow_release(window);
            throw std::runtime_error("no EGL config");
        }
        const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctxAttrs);
        const EGLint pbufferAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        pbuffer = eglCreatePbufferSurface(dpy, config, pbufferAttrs);
        if (ctx == EGL_NO_CONTEXT || pbuffer == EGL_NO_SURFACE) {
            if (window) ANativeWindow_release(window);
            destroyEgl();
            throw std::runtime_error("EGL context could not be created");
        }
        setWindow(window, fb);
        constructed = true;
        MLNB_LOG("mlnb: %s | %s | texture surface %ux%u\n", glGetString(GL_RENDERER), glGetString(GL_VERSION),
                 getSize().width, getSize().height);
    }

    ~Backend() override {
        makeCurrent();
        context.reset(); // gl::Context of MapLibre (the Renderer is gone already)
        destroyEgl();
        eglReleaseThread();
        // No eglTerminate: the display belongs to the process.
    }

    mln::gfx::Renderable& getDefaultRenderable() override { return *this; }

    void makeCurrent() {
        const EGLSurface s = eglSurface != EGL_NO_SURFACE ? eglSurface : pbuffer;
        eglMakeCurrent(dpy, s, s, ctx);
    }

    // Renders into `window` from now on; null leaves the map without a surface. Takes
    // over the caller's reference. fb: the size the caller believes the surface has, used
    // only when EGL cannot tell.
    void setWindow(ANativeWindow* window, mln::Size fb) {
        if (eglSurface != EGL_NO_SURFACE) {
            eglMakeCurrent(dpy, pbuffer, pbuffer, ctx);
            eglDestroySurface(dpy, eglSurface);
            eglSurface = EGL_NO_SURFACE;
        }
        if (nativeWindow) ANativeWindow_release(nativeWindow);
        nativeWindow = window;
        if (window) {
            eglSurface = eglCreateWindowSurface(dpy, config, window, nullptr);
            if (eglSurface == EGL_NO_SURFACE) {
                MLNB_LOG("mlnb: eglCreateWindowSurface failed: 0x%x\n", eglGetError());
                ANativeWindow_release(window);
                nativeWindow = nullptr;
            }
        }
        makeCurrent();
        if (eglSurface != EGL_NO_SURFACE) {
            eglSwapInterval(dpy, 0); // never wait for the consumer; pacing is by vsync
            EGLint w = 0, h = 0;
            if (eglQuerySurface(dpy, eglSurface, EGL_WIDTH, &w) && eglQuerySurface(dpy, eglSurface, EGL_HEIGHT, &h) &&
                w > 0 && h > 0) {
                fb = {static_cast<uint32_t>(w), static_cast<uint32_t>(h)};
            }
            setRenderableSize(fb);
        }
        waitingVsync.store(false);
        if (constructed) {
            MLNB_LOG("mlnb: surface %s, %ux%u\n", eglSurface != EGL_NO_SURFACE ? "attached" : "detached",
                     getSize().width, getSize().height);
        }
    }

    // Ends the vsync thread: onFrame is not called after this returns.
    void stopVsync() { vsync.reset(); }

    bool hasSurface() const { return eglSurface != EGL_NO_SURFACE; }

    void hide() {} // the texture is simply not shown; rendering stops in tick()
    void dispatch(bool) {}

    void bindDefault() {
        setFramebufferBinding(0);
        setViewport(0, 0, getSize());
    }

    void swapBuffers() {
        const int64_t t0 = monoUs();
        if (!snapshotPath.empty()) writeSnapshot();
        if (eglSurface != EGL_NO_SURFACE) {
            if (!eglSwapBuffers(dpy, eglSurface)) {
                // The consumer went away under us (the surface is being replaced): the
                // owner is about to hand over a new window or none.
                const EGLint error = eglGetError();
                if (error != lastSwapError) MLNB_LOG("mlnb: eglSwapBuffers failed: 0x%x\n", error);
                lastSwapError = error;
            } else {
                lastSwapError = EGL_SUCCESS;
            }
        }
        lastSwapMs = (monoUs() - t0) / 1000.0;
        if (vsync) {
            waitingVsync.store(true);
            vsync->request();
        }
    }

    // One frame per vsync, and none without a surface.
    bool canRender() const { return hasSurface() && !waitingVsync.load(); }

    // Debug: the finished frame written to a PPM file.
    std::string snapshotPath;
    void writeSnapshot() {
        const int w = static_cast<int>(getSize().width), h = static_cast<int>(getSize().height);
        std::vector<uint8_t> px(static_cast<std::size_t>(w) * h * 4);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
        if (std::FILE* f = std::fopen(snapshotPath.c_str(), "wb")) {
            std::fprintf(f, "P6\n%d %d\n255\n", w, h);
            std::vector<uint8_t> row(static_cast<std::size_t>(w) * 3);
            for (int y = h - 1; y >= 0; --y) { // GL rows are bottom-up
                const uint8_t* src = px.data() + static_cast<std::size_t>(y) * w * 4;
                for (int x = 0; x < w; ++x) std::memcpy(&row[x * 3], src + x * 4, 3);
                std::fwrite(row.data(), 1, row.size(), f);
            }
            std::fclose(f);
        }
        snapshotPath.clear();
        static_cast<mln::gl::Context&>(*context).pixelStorePack.setDirty();
    }

    // Never "stalled" in the Wayland sense: with the screen off no vsync arrives and
    // nothing is drawn, which is what is wanted.
    const bool stalled = false;
    std::function<void()> onFrame; // called on the vsync thread
    double lastSwapMs = 0;

protected:
    void activate() override { makeCurrent(); }
    void deactivate() override {} // the context stays current on the map thread
    mln::gl::ProcAddress getExtensionFunctionPointer(const char* name) override { return eglGetProcAddress(name); }
    void updateAssumedState() override {}

private:
    void destroyEgl() {
        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurface != EGL_NO_SURFACE) eglDestroySurface(dpy, eglSurface);
        if (pbuffer != EGL_NO_SURFACE) eglDestroySurface(dpy, pbuffer);
        if (ctx != EGL_NO_CONTEXT) eglDestroyContext(dpy, ctx);
        if (nativeWindow) ANativeWindow_release(nativeWindow);
        eglSurface = pbuffer = EGL_NO_SURFACE;
        ctx = EGL_NO_CONTEXT;
        nativeWindow = nullptr;
    }

    ANativeWindow* nativeWindow = nullptr;
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLContext ctx = EGL_NO_CONTEXT;
    EGLSurface eglSurface = EGL_NO_SURFACE;
    EGLSurface pbuffer = EGL_NO_SURFACE;
    EGLint lastSwapError = EGL_SUCCESS;
    bool constructed = false;
    std::atomic<bool> waitingVsync{false};
    std::unique_ptr<Vsync> vsync; // last: its thread calls into this object
};
