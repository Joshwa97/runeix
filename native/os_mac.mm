#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <map>
#include <algorithm>
#include "os.h"

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

// On macOS we use CGWindowID as the window handle stored in OSRawWindow.winid.
// The NSView* union member is only used for Electron's own windows via getNativeWindowHandle().

#pragma mark - Window Helpers

static CGWindowID WindowID(const OSWindow& wnd) {
	return (CGWindowID)wnd.handle.winid;
}

static NSDictionary* GetWindowInfo(CGWindowID windowId) {
	CFArrayRef windowList = CGWindowListCopyWindowInfo(
		kCGWindowListOptionIncludingWindow,
		windowId
	);
	if (!windowList) return nil;

	NSDictionary* info = nil;
	if (CFArrayGetCount(windowList) > 0) {
		info = [(__bridge NSArray*)windowList objectAtIndex:0];
		[info retain];
	}
	CFRelease(windowList);
	return [info autorelease];
}

static CGRect GetCGWindowBounds(CGWindowID windowId) {
	NSDictionary* info = GetWindowInfo(windowId);
	if (!info) return CGRectZero;

	CGRect bounds;
	NSDictionary* boundsDict = info[(NSString*)kCGWindowBounds];
	if (!boundsDict || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds)) {
		return CGRectZero;
	}
	return bounds;
}

#pragma mark - OSWindow Implementation

JSRectangle OSWindow::GetBounds() {
	CGRect bounds = GetCGWindowBounds(WindowID(*this));
	return JSRectangle(
		(int)bounds.origin.x,
		(int)bounds.origin.y,
		(int)bounds.size.width,
		(int)bounds.size.height
	);
}

JSRectangle OSWindow::GetClientBounds() {
	// RS client is borderless, so client bounds == window bounds
	return GetBounds();
}

bool OSWindow::IsValid() {
	if (this->handle.winid == 0) return false;
	return GetWindowInfo(WindowID(*this)) != nil;
}

std::string OSWindow::GetTitle() {
	NSDictionary* info = GetWindowInfo(WindowID(*this));
	if (!info) return "";

	NSString* title = info[(NSString*)kCGWindowName];
	return title ? std::string([title UTF8String]) : "";
}

Napi::Value OSWindow::ToJS(Napi::Env env) {
	return Napi::BigInt::New(env, (uint64_t)this->handle.winid);
}

bool OSWindow::operator==(const OSWindow& other) const {
	return this->handle.winid == other.handle.winid;
}

bool OSWindow::operator<(const OSWindow& other) const {
	return this->handle.winid < other.handle.winid;
}

OSWindow OSWindow::FromJsValue(const Napi::Value jsval) {
	auto handle = jsval.As<Napi::BigInt>();
	bool lossless;
	uint64_t handleint = handle.Uint64Value(&lossless);
	if (!lossless) {
		Napi::RangeError::New(jsval.Env(), "Invalid handle").ThrowAsJavaScriptException();
	}
	OSRawWindow raw;
	raw.winid = (uintptr_t)handleint;
	return OSWindow(raw);
}

#pragma mark - Process/Window Discovery

std::string OSGetProcessName(int pid) {
	NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
	if (!app) return "";
	NSString* name = [app localizedName];
	if (!name) name = [[app executableURL] lastPathComponent];
	return name ? std::string([name UTF8String]) : "";
}

std::vector<uint32_t> OSGetProcessesByName(std::string name, uint32_t parentpid) {
	std::vector<uint32_t> out;
	NSArray<NSRunningApplication*>* apps = [[NSWorkspace sharedWorkspace] runningApplications];
	NSString* targetName = [NSString stringWithUTF8String:name.c_str()];

	for (NSRunningApplication* app in apps) {
		NSString* appName = [app localizedName];
		NSString* execName = [[app executableURL] lastPathComponent];

		if ((appName && [appName isEqualToString:targetName]) ||
			(execName && [execName isEqualToString:targetName])) {
			out.push_back((uint32_t)[app processIdentifier]);
		}
	}
	return out;
}

static bool IsRsWindow(NSDictionary* info) {
	if (!info) return false;

	NSString* ownerName = info[(NSString*)kCGWindowOwnerName];
	if (!ownerName) return false;

	NSArray* rsNames = @[
		@"RuneScape",
		@"rs2client",
		@"RS2Client",
		@"steam_app_1343400"
	];

	for (NSString* rsName in rsNames) {
		if ([ownerName containsString:rsName]) return true;
	}

	NSString* windowName = info[(NSString*)kCGWindowName];
	if (windowName && [windowName containsString:@"RuneScape"]) return true;

	return false;
}

std::vector<OSWindow> OSGetRsHandles() {
	std::vector<OSWindow> out;

	CFArrayRef windowList = CGWindowListCopyWindowInfo(
		kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
		kCGNullWindowID
	);
	if (!windowList) return out;

	NSArray* windows = (__bridge NSArray*)windowList;
	for (NSDictionary* info in windows) {
		if (IsRsWindow(info)) {
			NSNumber* windowId = info[(NSString*)kCGWindowNumber];
			if (windowId) {
				CGRect bounds;
				NSDictionary* boundsDict = info[(NSString*)kCGWindowBounds];
				if (boundsDict && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds)) {
					if (bounds.size.width > 100 && bounds.size.height > 100) {
						OSRawWindow raw;
						raw.winid = [windowId unsignedIntValue];
						out.push_back(OSWindow(raw));
					}
				}
			}
		}
	}

	CFRelease(windowList);
	return out;
}

OSWindow OSFindMainWindow(unsigned long process_id) {
	CFArrayRef windowList = CGWindowListCopyWindowInfo(
		kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
		kCGNullWindowID
	);
	if (!windowList) return OSWindow(DEFAULT_OSRAWWINDOW);

	NSArray* windows = (__bridge NSArray*)windowList;
	OSWindow result(DEFAULT_OSRAWWINDOW);
	CGFloat maxArea = 0;

	for (NSDictionary* info in windows) {
		NSNumber* pid = info[(NSString*)kCGWindowOwnerPID];
		if (pid && [pid unsignedLongValue] == process_id) {
			CGRect bounds;
			NSDictionary* boundsDict = info[(NSString*)kCGWindowBounds];
			if (boundsDict && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds)) {
				CGFloat area = bounds.size.width * bounds.size.height;
				if (area > maxArea) {
					maxArea = area;
					NSNumber* windowId = info[(NSString*)kCGWindowNumber];
					OSRawWindow raw;
					raw.winid = [windowId unsignedIntValue];
					result = OSWindow(raw);
				}
			}
		}
	}

	CFRelease(windowList);
	return result;
}

#pragma mark - Window Parenting

void OSSetWindowParent(OSWindow wnd, OSWindow parent) {
	// On macOS, cross-process window parenting is not directly supported.
	// Window ordering is handled at the Electron level via alwaysOnTop + window pinning.
}

#pragma mark - Backing Scale Factor

static CGFloat GetBackingScaleFactorForWindow(CGWindowID windowId) {
	CGRect bounds = GetCGWindowBounds(windowId);
	if (CGRectIsEmpty(bounds)) return 1.0;

	CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

	// Find which display contains the window center
	CGDirectDisplayID displayID;
	uint32_t matchingDisplayCount;
	CGGetDisplaysWithPoint(center, 1, &displayID, &matchingDisplayCount);

	if (matchingDisplayCount > 0) {
		for (NSScreen* screen in [NSScreen screens]) {
			NSDictionary* desc = [screen deviceDescription];
			CGDirectDisplayID screenDisplayID = [[desc objectForKey:@"NSScreenNumber"] unsignedIntValue];
			if (screenDisplayID == displayID) {
				return [screen backingScaleFactor];
			}
		}
	}

	return [[NSScreen mainScreen] backingScaleFactor];
}

CGFloat OSGetBackingScaleFactor(OSWindow wnd) {
	return GetBackingScaleFactorForWindow(WindowID(wnd));
}

#pragma mark - Screen Capture

void OSCaptureWindowMulti(OSWindow wnd, vector<CaptureRect> rects) {
	CGWindowID windowId = WindowID(wnd);
	CGRect windowBounds = GetCGWindowBounds(windowId);

	// Capture at native resolution (no kCGWindowImageNominalResolution)
	// to avoid lossy downscaling on Retina displays
	CGImageRef windowImage = CGWindowListCreateImage(
		CGRectNull,
		kCGWindowListOptionIncludingWindow,
		windowId,
		kCGWindowImageBoundsIgnoreFraming
	);

	if (!windowImage) {
		std::cerr << "Failed to capture window " << windowId << std::endl;
		for (auto& rect : rects) {
			memset(rect.data, 0, rect.size);
		}
		return;
	}

	size_t imgWidth = CGImageGetWidth(windowImage);
	size_t imgHeight = CGImageGetHeight(windowImage);

	// Log dimensions once for diagnostics
	static bool logged = false;
	if (!logged) {
		std::cout << "[capture] window bounds: " << windowBounds.size.width << "x" << windowBounds.size.height
		          << " image: " << imgWidth << "x" << imgHeight
		          << " scale: " << (windowBounds.size.width > 0 ? (float)imgWidth / windowBounds.size.width : 0)
		          << std::endl;
		logged = true;
	}

	// Calculate actual scale between captured image and logical window bounds
	float scaleX = (windowBounds.size.width > 0) ? (float)imgWidth / windowBounds.size.width : 1.0f;
	float scaleY = (windowBounds.size.height > 0) ? (float)imgHeight / windowBounds.size.height : 1.0f;
	size_t bytesPerRow = imgWidth * 4;

	CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	std::vector<uint8_t> pixelData(imgWidth * imgHeight * 4);

	CGContextRef ctx = CGBitmapContextCreate(
		pixelData.data(),
		imgWidth,
		imgHeight,
		8,
		bytesPerRow,
		colorSpace,
		(CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)  // RGBA
	);

	if (ctx) {
		CGContextDrawImage(ctx, CGRectMake(0, 0, imgWidth, imgHeight), windowImage);
		CGContextRelease(ctx);
	}
	CGColorSpaceRelease(colorSpace);
	CGImageRelease(windowImage);

	if (!ctx) {
		for (auto& rect : rects) {
			memset(rect.data, 0, rect.size);
		}
		return;
	}

	for (auto& rect : rects) {
		uint8_t* dest = (uint8_t*)rect.data;
		int rx = rect.rect.x;
		int ry = rect.rect.y;
		int rw = rect.rect.width;
		int rh = rect.rect.height;

		if (scaleX == 1.0f && scaleY == 1.0f) {
			// No scaling needed - direct copy (1x display or matching resolution)
			for (int row = 0; row < rh; row++) {
				int srcY = ry + row;
				if (srcY < 0 || srcY >= (int)imgHeight) {
					memset(dest + row * rw * 4, 0, rw * 4);
					continue;
				}

				int srcStartX = std::max(0, rx);
				int srcEndX = std::min((int)imgWidth, rx + rw);
				int destStartCol = srcStartX - rx;
				int destEndCol = srcEndX - rx;

				if (destStartCol > 0) {
					memset(dest + row * rw * 4, 0, destStartCol * 4);
				}
				if (srcEndX > srcStartX) {
					int srcIdx = (srcY * (int)imgWidth + srcStartX) * 4;
					int destIdx = (row * rw + destStartCol) * 4;
					memcpy(dest + destIdx, pixelData.data() + srcIdx, (srcEndX - srcStartX) * 4);
				}
				if (destEndCol < rw) {
					memset(dest + (row * rw + destEndCol) * 4, 0, (rw - destEndCol) * 4);
				}
			}
		} else {
			// Retina display: point-sample from the high-res image to avoid
			// CoreGraphics' lossy bilinear downscaling
			for (int row = 0; row < rh; row++) {
				int srcY = (int)((ry + row) * scaleY);
				if (srcY < 0 || srcY >= (int)imgHeight) {
					memset(dest + row * rw * 4, 0, rw * 4);
					continue;
				}
				for (int col = 0; col < rw; col++) {
					int srcX = (int)((rx + col) * scaleX);
					int destIdx = (row * rw + col) * 4;
					if (srcX < 0 || srcX >= (int)imgWidth) {
						memset(dest + destIdx, 0, 4);
					} else {
						int srcIdx = (srcY * (int)imgWidth + srcX) * 4;
						memcpy(dest + destIdx, pixelData.data() + srcIdx, 4);
					}
				}
			}
		}

		fillImageOpaque(rect.data, rect.size);
	}
}

void OSCaptureDesktopMulti(OSWindow wnd, vector<CaptureRect> rects) {
	CGRect windowBounds = GetCGWindowBounds(WindowID(wnd));

	// Capture at native resolution to avoid lossy downscaling
	CGImageRef screenImage = CGWindowListCreateImage(
		windowBounds,
		kCGWindowListOptionOnScreenBelowWindow,
		WindowID(wnd),
		kCGWindowImageDefault
	);

	if (!screenImage) {
		for (auto& rect : rects) {
			memset(rect.data, 0, rect.size);
		}
		return;
	}

	size_t imgWidth = CGImageGetWidth(screenImage);
	size_t imgHeight = CGImageGetHeight(screenImage);
	size_t bytesPerRow = imgWidth * 4;

	float scaleX = (windowBounds.size.width > 0) ? (float)imgWidth / windowBounds.size.width : 1.0f;
	float scaleY = (windowBounds.size.height > 0) ? (float)imgHeight / windowBounds.size.height : 1.0f;

	CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	std::vector<uint8_t> pixelData(imgWidth * imgHeight * 4);

	CGContextRef ctx = CGBitmapContextCreate(
		pixelData.data(),
		imgWidth,
		imgHeight,
		8,
		bytesPerRow,
		colorSpace,
		(CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)
	);

	if (ctx) {
		CGContextDrawImage(ctx, CGRectMake(0, 0, imgWidth, imgHeight), screenImage);
		CGContextRelease(ctx);
	}
	CGColorSpaceRelease(colorSpace);
	CGImageRelease(screenImage);

	if (!ctx) {
		for (auto& rect : rects) {
			memset(rect.data, 0, rect.size);
		}
		return;
	}

	for (auto& rect : rects) {
		uint8_t* dest = (uint8_t*)rect.data;
		int rx = rect.rect.x;
		int ry = rect.rect.y;
		int rw = rect.rect.width;
		int rh = rect.rect.height;

		if (scaleX == 1.0f && scaleY == 1.0f) {
			for (int row = 0; row < rh; row++) {
				int srcY = ry + row;
				if (srcY < 0 || srcY >= (int)imgHeight) {
					memset(dest + row * rw * 4, 0, rw * 4);
					continue;
				}
				int srcStartX = std::max(0, rx);
				int srcEndX = std::min((int)imgWidth, rx + rw);
				int destStartCol = srcStartX - rx;
				int destEndCol = srcEndX - rx;

				if (destStartCol > 0) memset(dest + row * rw * 4, 0, destStartCol * 4);
				if (srcEndX > srcStartX) {
					int srcIdx = (srcY * (int)imgWidth + srcStartX) * 4;
					int destIdx = (row * rw + destStartCol) * 4;
					memcpy(dest + destIdx, pixelData.data() + srcIdx, (srcEndX - srcStartX) * 4);
				}
				if (destEndCol < rw) memset(dest + (row * rw + destEndCol) * 4, 0, (rw - destEndCol) * 4);
			}
		} else {
			for (int row = 0; row < rh; row++) {
				int srcY = (int)((ry + row) * scaleY);
				if (srcY < 0 || srcY >= (int)imgHeight) {
					memset(dest + row * rw * 4, 0, rw * 4);
					continue;
				}
				for (int col = 0; col < rw; col++) {
					int srcX = (int)((rx + col) * scaleX);
					int destIdx = (row * rw + col) * 4;
					if (srcX < 0 || srcX >= (int)imgWidth) {
						memset(dest + destIdx, 0, 4);
					} else {
						int srcIdx = (srcY * (int)imgWidth + srcX) * 4;
						memcpy(dest + destIdx, pixelData.data() + srcIdx, 4);
					}
				}
			}
		}
		fillImageOpaque(rect.data, rect.size);
	}
}

void OSCaptureMulti(OSWindow wnd, CaptureMode mode, vector<CaptureRect> rects, Napi::Env env) {
	switch (mode) {
		case CaptureMode::Desktop:
			OSCaptureDesktopMulti(wnd, rects);
			break;
		case CaptureMode::Window:
		case CaptureMode::OpenGL:
			// OpenGL capture is not available on macOS, fall back to window capture
			OSCaptureWindowMulti(wnd, rects);
			break;
	}
}

#pragma mark - Active Window & Mouse State

OSWindow OSGetActiveWindow() {
	NSRunningApplication* frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
	if (!frontApp) return OSWindow(DEFAULT_OSRAWWINDOW);

	pid_t pid = [frontApp processIdentifier];

	CFArrayRef windowList = CGWindowListCopyWindowInfo(
		kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
		kCGNullWindowID
	);
	if (!windowList) return OSWindow(DEFAULT_OSRAWWINDOW);

	OSWindow result(DEFAULT_OSRAWWINDOW);
	NSArray* windows = (__bridge NSArray*)windowList;

	for (NSDictionary* info in windows) {
		NSNumber* windowPid = info[(NSString*)kCGWindowOwnerPID];
		NSNumber* windowLayer = info[(NSString*)kCGWindowLayer];

		if (windowPid && [windowPid intValue] == pid && windowLayer && [windowLayer intValue] == 0) {
			NSNumber* windowId = info[(NSString*)kCGWindowNumber];
			if (windowId) {
				OSRawWindow raw;
				raw.winid = [windowId unsignedIntValue];
				result = OSWindow(raw);
				break;
			}
		}
	}

	CFRelease(windowList);
	return result;
}

bool OSGetMouseState() {
	return ([NSEvent pressedMouseButtons] & 1) != 0;
}

#pragma mark - Window Event Listeners

struct MacTrackedEvent {
	CGWindowID windowId;
	WindowEventType type;
	Napi::ThreadSafeFunction callback;
	Napi::FunctionReference callbackRef;

	MacTrackedEvent(CGWindowID wid, WindowEventType type, Napi::Function cb)
		: windowId(wid), type(type),
		  callback(Napi::ThreadSafeFunction::New(cb.Env(), cb, "mac-event", 0, 1, [](Napi::Env) {})),
		  callbackRef(Napi::Persistent(cb)) {}

	MacTrackedEvent(const MacTrackedEvent&) = delete;
	MacTrackedEvent& operator=(const MacTrackedEvent&) = delete;
	MacTrackedEvent(MacTrackedEvent&&) = default;
	MacTrackedEvent& operator=(MacTrackedEvent&&) = default;
};

static std::vector<MacTrackedEvent> macTrackedEvents;
static std::mutex macEventMutex;
static std::thread macPollingThread;
static std::atomic<bool> macPollingRunning(false);

static void MacPollingThread() {
	std::map<CGWindowID, CGRect> lastPositions;
	std::vector<CGWindowID> knownRsWindows;

	while (macPollingRunning.load()) {
		std::this_thread::sleep_for(std::chrono::milliseconds(50));

		std::lock_guard<std::mutex> lock(macEventMutex);

		if (macTrackedEvents.empty()) continue;

		// Check for new RS windows (Show events for windowId==0)
		bool watchingForShow = std::any_of(macTrackedEvents.begin(), macTrackedEvents.end(),
			[](const MacTrackedEvent& e) { return e.type == WindowEventType::Show && e.windowId == 0; });

		if (watchingForShow) {
			auto handles = OSGetRsHandles();
			for (auto& h : handles) {
				CGWindowID wid = WindowID(h);
				if (std::find(knownRsWindows.begin(), knownRsWindows.end(), wid) == knownRsWindows.end()) {
					knownRsWindows.push_back(wid);
					lastPositions[wid] = GetCGWindowBounds(wid);

					for (auto& evt : macTrackedEvents) {
						if (evt.type == WindowEventType::Show && evt.windowId == 0) {
							evt.callback.NonBlockingCall([wid](Napi::Env env, Napi::Function callback) {
								callback.Call({
									Napi::BigInt::New(env, (uint64_t)wid),
									Napi::Number::New(env, 0)
								});
							});
						}
					}
				}
			}
		}

		// Check tracked windows for move/close
		for (auto& evt : macTrackedEvents) {
			if (evt.windowId == 0) continue;

			CGWindowID wid = evt.windowId;
			NSDictionary* info = GetWindowInfo(wid);

			if (!info) {
				if (evt.type == WindowEventType::Close) {
					evt.callback.NonBlockingCall([](Napi::Env env, Napi::Function callback) {
						callback.Call({});
					});
				}
				lastPositions.erase(wid);
				knownRsWindows.erase(std::remove(knownRsWindows.begin(), knownRsWindows.end(), wid), knownRsWindows.end());
				continue;
			}

			if (evt.type == WindowEventType::Move) {
				CGRect bounds = GetCGWindowBounds(wid);
				auto it = lastPositions.find(wid);
				if (it != lastPositions.end() && !CGRectEqualToRect(bounds, it->second)) {
					it->second = bounds;
					JSRectangle jsBounds((int)bounds.origin.x, (int)bounds.origin.y,
										  (int)bounds.size.width, (int)bounds.size.height);
					evt.callback.NonBlockingCall([jsBounds](Napi::Env env, Napi::Function callback) {
						callback.Call({jsBounds.ToJs(env), Napi::String::New(env, "end")});
					});
				} else if (it == lastPositions.end()) {
					lastPositions[wid] = bounds;
				}
			}
		}
	}
}

void OSNewWindowListener(OSWindow wnd, WindowEventType type, Napi::Function cb) {
	CGWindowID wid = WindowID(wnd);

	{
		std::lock_guard<std::mutex> lock(macEventMutex);
		macTrackedEvents.emplace_back(wid, type, cb);
	}

	if (!macPollingRunning.load()) {
		macPollingRunning.store(true);
		macPollingThread = std::thread(MacPollingThread);
	}
}

void OSRemoveWindowListener(OSWindow wnd, WindowEventType type, Napi::Function cb) {
	CGWindowID wid = WindowID(wnd);
	bool shouldStop = false;

	{
		std::lock_guard<std::mutex> lock(macEventMutex);
		macTrackedEvents.erase(
			std::remove_if(
				macTrackedEvents.begin(),
				macTrackedEvents.end(),
				[wid, type](MacTrackedEvent& e) {
					if (e.windowId == wid && e.type == type) {
						e.callback.Release();
						return true;
					}
					return false;
				}
			),
			macTrackedEvents.end()
		);
		shouldStop = macTrackedEvents.empty();
	}

	if (shouldStop && macPollingRunning.load()) {
		macPollingRunning.store(false);
		if (macPollingThread.joinable()) {
			macPollingThread.join();
		}
	}
}

void OSSetWindowShape(OSWindow wnd, vector<JSRectangle> rects) {
	// Not needed on macOS - Electron's setIgnoreMouseEvents handles click-through
}
