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

@interface AppDelegate () <NSWindowDelegate, MTKViewDelegate> {
    NSTimeInterval _displayRefreshHistory[10];
}

@property (strong) IBOutlet NSWindow *window;
@property (strong) MTKView *view;
@property (strong) id<MTLCommandQueue> cmdQ;
@property (strong) NSTimer *timer;
@property NSTimeInterval lastImGuiTime;
@property int requestedDisplayRate;

@end

@implementation AppDelegate

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // just turn on the Metal HUD all the time to illustrate the problem.
    setenv("MTL_HUD_ENABLED", "1", 1);
    
    // initialize GUI state
    self.requestedDisplayRate = 60;

    // create metal view
    [self setupView];

    // go fullscreen
    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = [screen frame];
    NSLog(@"Frame is %@", NSStringFromRect(frame));
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.backgroundColor = [NSColor redColor];
    [self.window setFrame:frame display:YES];
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

    NSLog(@"Display %@ min refresh %.3fms max refresh %.3fms granularity %.3fms",
          self.window.screen.localizedName,
          self.window.screen.minimumRefreshInterval * 1000.0,
          self.window.screen.maximumRefreshInterval * 1000.0,
          self.window.screen.displayUpdateGranularity * 1000.0);

//    CAMetalLayer *mtlLayer = (id)self.view.layer;
//    mtlLayer.displaySyncEnabled = NO;

    self.cmdQ = [self.view.device newCommandQueue];

    [self setupImGui];

    [self renderLoop];
}

#pragma mark - RenderLoop

- (void)renderLoop {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0 target:self.view selector:@selector(draw) userInfo:nil repeats:YES];
}

#pragma mark - Display Refresh History Calculation

- (void)updateDisplayRefreshHistory {
    NSScreen *screen = self.view.window.screen;
    NSTimeInterval lastUpdate = screen.lastDisplayUpdateTimestamp;
    // scoot old values down
    size_t len = sizeof(_displayRefreshHistory) / sizeof(_displayRefreshHistory[0]);
    for (size_t i = len; i > 1; --i)
        _displayRefreshHistory[i-1] = _displayRefreshHistory[i-2];
    // store latest value
    _displayRefreshHistory[0] = lastUpdate;
}

- (NSTimeInterval)displayRefreshHistory {
    NSTimeInterval sum = 0.0;
    size_t len = sizeof(_displayRefreshHistory) / sizeof(_displayRefreshHistory[0]);
    for (size_t i = 0; i < len-1; ++i) {
        sum += _displayRefreshHistory[i] - _displayRefreshHistory[i+1];
    }
    return sum / (len-1);
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
    ImGui::Text("Min Refresh: %.0fHz", 1.0 / screen.maximumRefreshInterval);
    ImGui::Text("Max Refresh: %.0fHz", 1.0 / screen.minimumRefreshInterval);
    ImGui::Text("Update Granularity: %.0fms", screen.displayUpdateGranularity);
    ImGui::Separator();
    ImGui::Text("Current Refresh: %.0fHz", 1.0 / [self displayRefreshHistory]);
    
    ImGui::Separator();
    int rateMin = 1.0 / screen.maximumRefreshInterval;
    int rateMax = 1.0 / screen.minimumRefreshInterval;
    ImGui::SliderInt("Desired Refresh", &_requestedDisplayRate, rateMin, rateMax+1);
    
    ImGui::End();
    
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view {
    id<MTLCommandBuffer> buf = [self.cmdQ commandBuffer];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    [drawable addPresentedHandler:^(id<MTLDrawable> drawable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateDisplayRefreshHistory];
        });
    }];

    MTLRenderPassDescriptor *desc = view.currentRenderPassDescriptor;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, sin(CACurrentMediaTime()) * 0.5 + 0.5, 1);
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;

    id<MTLRenderCommandEncoder> cmdEnc = [buf renderCommandEncoderWithDescriptor:desc];
    
    [self runImGuiPerFrameWithDescriptor:desc
                                  buffer:buf
                                 encoder:cmdEnc];

    [cmdEnc endEncoding];

    // set FPS
    NSTimeInterval frameTime = 1.0 / _requestedDisplayRate;
    [buf presentDrawable:drawable afterMinimumDuration:frameTime];
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

@end
