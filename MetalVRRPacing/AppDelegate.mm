//
//  AppDelegate.m
//  MetalVRRPacing
//
//  Created by James Howard on 7/19/23.
//

#import "AppDelegate.h"

#import <MetalKit/MetalKit.h>
#import <imgui.h>
#import <imgui_impl_osx.h>
#import <imgui_impl_metal.h>

#import <mutex>
#import <chrono>
#import <thread>

static void SleepUntil(double hostTime) {
    thread_local double overslept;
    hostTime -= overslept;
    auto start = CACurrentMediaTime();
    const auto accuracy = 0.008; // 8 millis
    if (hostTime - start > accuracy)
        usleep(USEC_PER_SEC * (hostTime - start - (accuracy / 2.0)));
    while (CACurrentMediaTime() < hostTime)
        std::this_thread::yield();
    overslept = CACurrentMediaTime() - hostTime;
}

enum PacingType : int {
    PacingTypePresentAtTime = 0,
    PacingTypePresentAfterDuration,
    PacingTypeSleep,
    PacingTypeNone,
    PacingTypeMax
};

static const char *PacingTypeToString(PacingType type) {
    switch (type) {
        case PacingTypePresentAtTime:
            return "presentDrawable:atTime:";
        case PacingTypePresentAfterDuration:
            return "presentDrawable:afterMinimumDuration:";
        case PacingTypeSleep:
            return "Accurate Sleep";
        case PacingTypeNone:
            return "None";
        case PacingTypeMax:
            assert(0);
            return "";
    }
}

@interface AppDelegate () <NSWindowDelegate, MTKViewDelegate> {
    double _lastPresentActual; // time when display last updated
    double _lastPresentExpected;
    NSUInteger _lastPresentFrameCount;
    double _presentHistory;
    double _lastPresentDrawable; // time when presentDrawable: message sent
    double _cpuToPresentLatency;
    NSUInteger _frameCount;
    PacingType _pacingType;
    bool _vsync;
    bool _hdr;
    bool _layerHDR;
    bool _wcg;
    bool _layerWCG;
    int _resyncs;
    int _drawableCount;
    std::mutex _historyMutex;
}

@property (strong) IBOutlet NSWindow *window;
@property (strong) MTKView *view;
@property (strong) id<MTLCommandQueue> cmdQ;
@property (strong) NSTimer *timer;
@property NSTimeInterval lastImGuiTime;
@property int requestedDisplayRate;

@property NSTimeInterval screenMinRefresh;
@property NSTimeInterval screenMaxRefresh;
@property NSTimeInterval screenGranularity;
@property BOOL screenHDR;
@property BOOL screenWCG;

@end

@implementation AppDelegate

+ (void)initialize {
    // just turn on the Metal HUD all the time to illustrate the problem.
    setenv("MTL_HUD_ENABLED", "1", 1);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MetalForceHudEnabled"];
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // initialize GUI state
    self.requestedDisplayRate = 60;
    _vsync = YES;
    _drawableCount = 2;

    // find the best display (fastest and has VRR)
    NSScreen *screen = [[[NSScreen screens] sortedArrayUsingComparator:^NSComparisonResult(NSScreen *a, NSScreen *b) {
        BOOL aVRR = a.minimumRefreshInterval != a.maximumRefreshInterval;
        BOOL bVRR = b.minimumRefreshInterval != b.maximumRefreshInterval;
        if (aVRR && !bVRR) {
            return NSOrderedAscending;
        } else if (!aVRR && bVRR) {
            return NSOrderedDescending;
        } else if (a.maximumRefreshInterval < b.maximumRefreshInterval) {
            return NSOrderedAscending;
        } else if (a.maximumRefreshInterval > b.maximumRefreshInterval) {
            return NSOrderedDescending;
        } else {
            return NSOrderedSame;
        }
    }] firstObject];

    NSRect frame = [screen frame];
    NSLog(@"Display is %@ Frame is %@", [screen localizedName], NSStringFromRect(frame));
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.backgroundColor = [NSColor redColor];
    [self.window setFrame:frame display:YES];

    // create metal view
    [self setupView];

    // go fullscreen
    [self.window toggleFullScreen:nil];
}

#pragma mark - Setup

- (void)setupView {
    if (self.view)
        return;

    NSRect contentRect = [self.window contentRectForFrameRect:self.window.frame];
    self.view = [[MTKView alloc] initWithFrame:contentRect device:MTLCreateSystemDefaultDevice()];
    self.view.delegate = self;
    self.window.contentView = self.view;
    [self.view setPaused:YES]; // we don't want a display link, we're trying to draw on our own time

    NSScreen *screen = self.window.screen;
    self.screenMinRefresh = screen.minimumRefreshInterval;
    self.screenMaxRefresh = screen.maximumRefreshInterval;
    self.screenGranularity = screen.displayUpdateGranularity;
    self.screenHDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
    self.screenWCG = [screen canRepresentDisplayGamut:NSDisplayGamutP3];

    NSLog(@"Display %@ min refresh %.3fms max refresh %.3fms granularity %.3fms",
          self.window.screen.localizedName,
          self.window.screen.minimumRefreshInterval * 1000.0,
          self.window.screen.maximumRefreshInterval * 1000.0,
          self.window.screen.displayUpdateGranularity * 1000.0);

    self.cmdQ = [self.view.device newCommandQueue];

    [self setupImGui];
}

#pragma mark - RenderLoop

- (void)renderLoop {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0 target:self.view selector:@selector(draw) userInfo:nil repeats:YES];
}

#pragma mark - Present History Calculation

- (void)addActualPresentTime:(double)actualTime expectedPresentTime:(double)expectedTime renderTime:(double)renderTime forFrame:(NSUInteger)frameNumber {
    std::lock_guard lock(_historyMutex);

    double dt = _lastPresentActual > 0.0 ? actualTime - _lastPresentActual : 0.0;
    _lastPresentActual = actualTime;
    _lastPresentExpected = expectedTime;
    _lastPresentFrameCount = frameNumber;

    double historySize = 30.0;
    double alpha = 2.0 / (historySize + 1.0);

    _presentHistory = (alpha * dt) + ((1.0 - alpha) * _presentHistory);

    double cpuDT = actualTime - renderTime;
    _cpuToPresentLatency = (alpha * cpuDT) + ((1.0 - alpha) * _cpuToPresentLatency);
}

- (double)averagePresentInterval {
    return _presentHistory;
}

#pragma mark - ImGui

- (void)setupImGui {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui_ImplMetal_Init(self.view.device);
    ImGui_ImplOSX_Init(self.view);
}

- (void)runImGuiPerFrameWithDescriptor:(MTLRenderPassDescriptor *)renderPassDescriptor
                                buffer:(id<MTLCommandBuffer>)cmdBuf
                               encoder:(id<MTLRenderCommandEncoder>)cmdEnc {
    ImGuiIO &io = ImGui::GetIO();

    // Give ImGui the time of day
    auto now = CACurrentMediaTime();
    if (self.lastImGuiTime == 0.0)
        io.DeltaTime = 0.f;
    else
        io.DeltaTime = now - self.lastImGuiTime;
    self.lastImGuiTime = now;

    // Configure viewport
    io.DisplaySize.x = self.view.bounds.size.width;
    io.DisplaySize.y = self.view.bounds.size.height;
    double scaleFactor = self.view.window.screen.backingScaleFactor;
    io.DisplayFramebufferScale = ImVec2(scaleFactor, scaleFactor);

    // Configure fonts
    auto fontSizePixels = 13.f * scaleFactor;
    auto fontGlobalScale = 1.f / scaleFactor;
    if (!io.Fonts->IsBuilt()
        || io.Fonts->Fonts.size() == 0
        || io.Fonts->Fonts[0]->FontSize != fontSizePixels) {
        bool needsRebuild = io.Fonts->IsBuilt();
        if (needsRebuild) {
            ImGui_ImplMetal_DestroyDeviceObjects();
        }

        io.Fonts->Clear();
        ImFontConfig fontConfig;
        fontConfig.SizePixels = fontSizePixels;
        io.Fonts->AddFontDefault(&fontConfig);
        io.FontGlobalScale = fontGlobalScale;
    }

    ImGui_ImplMetal_NewFrame(renderPassDescriptor);

    ImGui::NewFrame();

    [self drawImGui];

    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();

    ImGui_ImplMetal_RenderDrawData(drawData, cmdBuf, cmdEnc);
}

- (void)drawImGui {
    NSScreen *screen = self.view.window.screen;

    ImGui::Begin("MetalVRRPacing", NULL, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::Text("Display: %s", [screen.localizedName UTF8String]);
    ImGui::Text("Min Refresh: %.0fHz", 1.0 / self.screenMaxRefresh);
    ImGui::Text("Max Refresh: %.0fHz", 1.0 / self.screenMinRefresh);
    ImGui::Text("Update Granularity: %.0fms", self.screenGranularity * 1000.0);
    if (!_screenHDR) ImGui::BeginDisabled();
    ImGui::Checkbox("HDR", &_hdr);
    if (!_screenHDR) ImGui::EndDisabled();
    if (!_screenWCG) ImGui::BeginDisabled();
    ImGui::Checkbox("Wide Color", &_wcg);
    if (!_screenWCG) ImGui::EndDisabled();

    ImGui::Separator();
    ImGui::Text("Current Refresh: %.2fHz", 1.0 / [self averagePresentInterval]);
    ImGui::Text("Present Time Frame Lag: %d", static_cast<int>(_frameCount - _lastPresentFrameCount - 1));
    ImGui::Text("CPU to Display Latency: %.2fms", _cpuToPresentLatency * 1000.0);
    ImGui::Text("Present Time Resyncs: %d", _resyncs);

    // --- ---
    ImGui::Separator();

    if (ImGui::BeginCombo("Pacing Type", PacingTypeToString(_pacingType))) {
        for (int i = 0; i < PacingTypeMax; ++i) {
            PacingType t = static_cast<PacingType>(i);
            bool selected = _pacingType == t;
            if (ImGui::Selectable(PacingTypeToString(t), &selected)) {
                _pacingType = t;
            }
            if (selected) {
                ImGui::SetItemDefaultFocus();
            }
        }
        ImGui::EndCombo();
    }

    ImGui::Checkbox("VSync", &_vsync);
    ImGui::SliderInt("Swapchain Size", &_drawableCount, 2, 3);

    int rateMin = 15;
    int rateMax = 1.0 / self.screenMinRefresh;
    ImGui::SliderInt("Desired Refresh", &_requestedDisplayRate, rateMin, rateMax+1);

    ImGui::End();
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view {
    CAMetalLayer *mtlLayer = (CAMetalLayer *)view.layer;
    mtlLayer.displaySyncEnabled = _vsync;
    mtlLayer.maximumDrawableCount = _drawableCount;

    if (_layerHDR != _hdr || _layerWCG != _wcg) {
        _layerHDR = _hdr;
        _layerWCG = _wcg;

        mtlLayer.pixelFormat = _hdr || _wcg ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
        mtlLayer.wantsExtendedDynamicRangeContent = _hdr;
        CGColorSpaceRef cs = NULL;
        if (_hdr) {
            cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_PQ);
            CFAutorelease(cs);
        }
        mtlLayer.colorspace = cs;
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    id<MTLCommandBuffer> buf = [self.cmdQ commandBuffer];
    NSUInteger frameCount = _frameCount;
    ++_frameCount;

    std::unique_lock historyLock(_historyMutex);

    MTLRenderPassDescriptor *desc = view.currentRenderPassDescriptor;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, sin(CACurrentMediaTime()) * 0.5 + 0.5, 1);
    if ([NSEvent pressedMouseButtons] & 1)
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;

    id<MTLRenderCommandEncoder> cmdEnc = [buf renderCommandEncoderWithDescriptor:desc];

    [self runImGuiPerFrameWithDescriptor:desc
                                  buffer:buf
                                 encoder:cmdEnc];

    [cmdEnc endEncoding];

    // set FPS
    NSTimeInterval frameTime = 1.0 / _requestedDisplayRate;

    double presentTime = 0;

    if (_lastPresentExpected) {
        // _lastPresent will be a time for some frame in the past, probably a few frames behind the current.
        // Therefore the time needs to be projected forward by that number of frames.
        presentTime = _lastPresentExpected + (frameTime * (frameCount - _lastPresentFrameCount));
    }

    historyLock.unlock();

    double renderTime = CACurrentMediaTime();
    [drawable addPresentedHandler:^(id<MTLDrawable> drawn) {
        double actualTime = drawn.presentedTime ?: CACurrentMediaTime();
        double expectedTime = presentTime;
        double time = expectedTime;
        if (fabs(actualTime - expectedTime) > 0.1) {
            self->_resyncs++;
            time = actualTime;
        }
        [self addActualPresentTime:actualTime expectedPresentTime:time renderTime:renderTime forFrame:frameCount];
    }];

    PacingType pacingType = _pacingType;
    if (pacingType == PacingTypePresentAtTime && presentTime == 0)
        pacingType = PacingTypeNone;

    switch (_pacingType) {
        case PacingTypePresentAtTime:
            [buf presentDrawable:drawable atTime:presentTime];
            break;
        case PacingTypePresentAfterDuration:
            [buf presentDrawable:drawable afterMinimumDuration:frameTime];
            break;
        case PacingTypeSleep:
            SleepUntil(_lastPresentDrawable + frameTime);
            // intentional fallthrough
        case PacingTypeNone:
            [buf presentDrawable:drawable];
            break;
        default:
            assert(0);
            break;
    }
    _lastPresentDrawable = CACurrentMediaTime();

    [buf commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { }

#pragma mark - NSWindowDelegate

- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
    return NSApplicationPresentationFullScreen | NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    [NSApp terminate:nil];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [self renderLoop];
}

@end
