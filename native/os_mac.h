#pragma once
#include "stdint.h"

// On macOS, we use CGWindowID (uint32_t) as the window identifier.
// This is stored in the winid field of OSRawWindow.
// The wnd pointer field exists for compatibility with Electron's getNativeWindowHandle()
// which returns an NSView*, but we convert it to a CGWindowID for all our operations.

#define DEFAULT_OSRAWWINDOW {.winid=0}

#ifdef __OBJC__
#include <Cocoa/Cocoa.h>
typedef NSView view_t;
#else
typedef void view_t;
#endif

typedef union NativeView {
	uintptr_t winid;
	view_t* wnd;
} NativeView;

typedef NativeView OSRawWindow;
