//
//  INDockableWindowController.m
//  INDockableWindow
//
// Copyright (c) 2013, Indragie Karunaratne. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this
// software and associated documentation files (the "Software"), to deal in the Software
// without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
// to whom the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
// OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


#import "INDockableWindowController.h"
#import "INWindowFrameAnimation.h"
#import "NSView+INImagingAdditions.h"

NSString * const INDockableWindowFrameDidChangeNotification = @"INDockableWindowFrameDidChangeNotification";
NSString * const INDockableWindowFrameWillChangeNotification = @"INDockableWindowFrameWillChangeNotification";

@interface INDockableViewController (Private)
@property (nonatomic, assign, readwrite) INDockableWindowController *dockableWindowController;
@property (nonatomic, assign, readwrite) NSUInteger index;
@end

@interface INDockableWindow (Private)
@property (nonatomic, assign, readwrite) INDockableWindowController *dockableWindowController;
@end

@interface INDockableAuxiliaryWindow (Private)
- (id)initWithViewController:(INDockableViewController *)viewController styleMask:(NSUInteger)styleMask;
- (void)showViewControllerImage;
- (void)showViewController;
@end

@interface INDockableWindowController ()
@property (nonatomic, strong) NSDictionary *autosaveData;
@end

@implementation INDockableWindowController {
	NSMutableSet *_auxiliaryWindows;
	NSMutableSet *_viewControllers;
	NSMutableArray *_attachedViewControllers;
	NSMutableDictionary *_minimumWidths;
	NSMutableDictionary *_maximumWidths;
	NSMutableDictionary *_shouldAdjust;
	struct {
		unsigned int viewControllerWasDetached : 1;
		unsigned int viewControllerWasAttached : 1;
		unsigned int auxiliaryWindowDidClose : 1;
		unsigned int willRemoveViewController : 1;
		unsigned int didRemoveViewController : 1;
		unsigned int willAddViewController : 1;
		unsigned int didAddViewController : 1;
	} _delegateFlags;
	CGFloat _lastAuxiliaryWindowMinX;
	INDockableAuxiliaryWindow *_lastMovedAuxiliaryWindow;
	BOOL _shouldAttachAuxiliaryWindowOnMouseUp;
	BOOL _tempDisableFrameAnimation;
	BOOL _isAnimating;
	BOOL _isRestoringFrameFromAutosave;
	NSMutableDictionary *_loadedAutosaveData;
	NSView *_titleBarContainerView;
}
@synthesize auxiliaryWindows = _auxiliaryWindows;
@synthesize viewControllers = _viewControllers;
@synthesize attachedViewControllers = _attachedViewControllers;
@synthesize titleBarHeight = _titleBarHeight;

- (id)init
{
	// Using a XIB instead of programatically loading the window because OS X is terrible
	// at loading restorable state from programmatically created windows.
	if ((self = [super initWithWindow:[self.class defaultWindow]])) {
		[self commonInitForINDockableWindowController];
	}
	return self;
}

- (id)initWithWindowNibName:(NSString *)windowNibName owner:(id)owner
{
	if ((self = [super initWithWindowNibName:windowNibName owner:owner])) {
		[self commonInitForINDockableWindowController];
	}
	return self;
}

- (id)initWithWindowNibPath:(NSString *)windowNibPath owner:(id)owner
{
	if ((self = [super initWithWindowNibPath:windowNibPath owner:owner])) {
		[self commonInitForINDockableWindowController];
	}
	return self;
}

- (id)initWithWindow:(NSWindow *)window
{
	NSAssert(!window || [window isKindOfClass:[INDockablePrimaryWindow class]], @"Window is of incorrect class.");
	if ((self = [super initWithWindow:window])) {
		[self commonInitForINDockableWindowController];
	}
	return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
	if ((self = [super initWithCoder:aDecoder])) {
		[self commonInitForINDockableWindowController];
	}
	return self;
}

+ (INDockablePrimaryWindow *)defaultWindow
{
	return [[INDockablePrimaryWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 800.0, 600.0) styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
}

- (void)commonInitForINDockableWindowController
{
	if (!self.window) return;
	_primaryWindow = (INDockablePrimaryWindow *)self.window;
	_primaryWindow.delegate = self;
	_primaryWindow.releasedWhenClosed = NO;
	_auxiliaryWindows = [NSMutableSet set];
	_viewControllers = [NSMutableSet set];
	_attachedViewControllers = [NSMutableArray array];
	_minimumWidths = [NSMutableDictionary dictionary];
	_maximumWidths = [NSMutableDictionary dictionary];
	_shouldAdjust = [NSMutableDictionary dictionary];
	_attachmentProximity = 8.0;
	_titleBarHeight = 22.0;
	_animatesFrameChange = NO;
	_maximumWindowHeight = CGFLOAT_MAX;
	_minimumWindowHeight = 0.0;
	_windowAnimationCurve = NSAnimationEaseInOut;
	_windowAnimationDuration = 0.20;
	NSView *titleBarView = _primaryWindow.titleBarView;
	_titleBarContainerView = [[NSView alloc] initWithFrame:titleBarView.bounds];
	_titleBarContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[titleBarView addSubview:_titleBarContainerView];
	
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(detachControlTriggeredDetach:) name:INDockableDetachControlTriggerNotification object:nil];
	[nc addObserver:self selector:@selector(primaryWindowDidMove:) name:NSWindowDidMoveNotification object:_primaryWindow];
	[nc addObserver:self selector:@selector(layoutPrimaryWindow) name:NSWindowDidExitFullScreenNotification object:_primaryWindow];
	[nc addObserver:self selector:@selector(layoutPrimaryWindow) name:NSWindowDidEnterFullScreenNotification object:_primaryWindow];
	[nc addObserver:self selector:@selector(saveViewControllerAutosaveData) name:NSWindowDidResignKeyNotification object:_primaryWindow];
	[nc addObserver:self selector:@selector(saveViewControllerAutosaveData) name:NSApplicationWillTerminateNotification object:NSApp];
	[self configureSplitView];
	[self resetTitlebarHeights];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Accessors

- (NSUInteger)windowStyleMask
{
	return _windowStyleMask ?: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
}

- (void)setPrimaryViewController:(INDockableViewController *)primaryViewController
{
	if (_primaryViewController != primaryViewController) {
		_primaryViewController = primaryViewController;
		[self configurePrimaryViewController];
	}
}

- (void)setTitleBarHeight:(CGFloat)titleBarHeight
{
	if (_titleBarHeight != titleBarHeight) {
		_titleBarHeight = titleBarHeight;
		[self resetTitlebarHeights];
	}
}

- (void)setMinimumWindowHeight:(CGFloat)minimumWindowHeight
{
	if (_minimumWindowHeight != minimumWindowHeight) {
		_minimumWindowHeight = minimumWindowHeight;
		[self configureConstraintsForWindow:self.primaryWindow];
		[_auxiliaryWindows enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
			[self configureConstraintsForWindow:obj];
		}];
	}
}

- (void)setMaximumWindowHeight:(CGFloat)maximumWindowHeight
{
	if (_maximumWindowHeight != maximumWindowHeight) {
		_maximumWindowHeight = maximumWindowHeight;
		[self configureConstraintsForWindow:self.primaryWindow];
		[_auxiliaryWindows enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
			[self configureConstraintsForWindow:obj];
		}];
	}
}

- (void)setAutosaveName:(NSString *)autosaveName
{
	if (_autosaveName != autosaveName) {
		_autosaveName = autosaveName;
		if (_autosaveName) {
			_loadedAutosaveData = [[NSUserDefaults.standardUserDefaults objectForKey:self.autosaveUserDefaultsKey] mutableCopy];
			_isRestoringFrameFromAutosave = YES;
			self.primaryWindow.identifier = autosaveName;
			[self.primaryWindow setFrameAutosaveName:autosaveName];
			[self.primaryWindow setFrameUsingName:autosaveName];
			_isRestoringFrameFromAutosave = NO;
		}
	}
}

- (void)setDelegate:(id<INDockableWindowControllerDelegate>)delegate
{
	if (_delegate != delegate) {
		_delegate = delegate;
		_delegateFlags.viewControllerWasAttached = [delegate respondsToSelector:@selector(dockableWindowController:viewControllerWasAttached:)];
		_delegateFlags.viewControllerWasDetached = [delegate respondsToSelector:@selector(dockableWindowController:viewControllerWasDetached:)];
		_delegateFlags.auxiliaryWindowDidClose = [delegate respondsToSelector:@selector(dockableWindowController:auxiliaryWindowDidClose:)];
		_delegateFlags.willRemoveViewController = [delegate respondsToSelector:@selector(dockableWindowController:willRemoveViewController:)];
		_delegateFlags.didRemoveViewController = [delegate respondsToSelector:@selector(dockableWindowController:didRemoveViewController:)];
		_delegateFlags.willAddViewController = [delegate respondsToSelector:@selector(dockableWindowController:willAddViewController:)];
		_delegateFlags.didAddViewController = [delegate respondsToSelector:@selector(dockableWindowController:didAddViewController:)];
	}
}

#pragma mark - NSWindowRestoration

static NSString * const INDockableWindowControllerAutosavePrefix = @"INDockableWindowController_";

- (void)setAutosaveData:(NSDictionary *)autosaveData
{
	if (_autosaveData != autosaveData) {
		_autosaveData = autosaveData;
		[NSUserDefaults.standardUserDefaults setObject:autosaveData forKey:self.autosaveUserDefaultsKey];
	}
}

- (void)saveViewControllerAutosaveData
{
	if (!self.autosaveName) return;
	NSMutableDictionary *data = [NSMutableDictionary dictionaryWithCapacity:[_viewControllers count]];
	[_viewControllers enumerateObjectsUsingBlock:^(INDockableViewController *viewController, BOOL *stop) {
		CGFloat viewWidth = NSWidth(viewController.view.frame);
		if (viewWidth > 0.0) {
			data[viewController.uniqueIdentifier] = @(viewWidth);
		}
	}];
	self.autosaveData = data;
}

- (NSString *)autosaveUserDefaultsKey
{
	if (self.autosaveName) {
		return [INDockableWindowControllerAutosavePrefix stringByAppendingString:self.autosaveName];
	}
	return nil;
}

#pragma mark - NSWindowDelegate

static NSString * const INDockableWindowControllerFullscreenAutosaveKey = @"INDockableWindowControllerFullscreen";

- (void)window:(NSWindow *)window willEncodeRestorableState:(NSCoder *)state
{
	[state encodeBool:(window.styleMask & NSFullScreenWindowMask) == NSFullScreenWindowMask forKey:INDockableWindowControllerFullscreenAutosaveKey];
}

- (void)window:(NSWindow *)window didDecodeRestorableState:(NSCoder *)state
{
	if ([state decodeBoolForKey:INDockableWindowControllerFullscreenAutosaveKey]) {
		[window toggleFullScreen:nil];
	}
}

// Only restore the frame origin + frame height and not the width when restoring from autosave
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
	if (_isRestoringFrameFromAutosave) {
		return NSMakeSize(0.0, frameSize.height);
	}
	return frameSize;
}

#pragma mark - Public API

- (INDockableViewController *)attachedViewControllerAtIndex:(NSUInteger)index
{
	return [self.attachedViewControllers objectAtIndex:index];
}

- (INDockableViewController *)viewControllerWithIdentifier:(NSString *)identifier
{
	__block INDockableViewController *controller = nil;
	[self.viewControllers enumerateObjectsUsingBlock:^(INDockableViewController *viewController, BOOL *stop) {
		if ([viewController.uniqueIdentifier isEqualToString:identifier]) {
			controller = viewController;
			*stop = YES;
		}
	}];
	return controller;
}

- (void)setIndex:(NSUInteger)index forAttachedViewController:(INDockableViewController *)viewController
{
	NSUInteger oldIndex = [self.attachedViewControllers indexOfObject:viewController];
	if (oldIndex != NSNotFound) {
		[_attachedViewControllers removeObjectAtIndex:oldIndex];
		[_attachedViewControllers insertObject:viewController atIndex:index];
		[self reorderPrimaryWindow];
	}
}

- (NSUInteger)indexOAttachedfViewController:(INDockableViewController *)viewController
{
	return [self.attachedViewControllers indexOfObjectIdenticalTo:viewController];
}

- (void)addViewController:(INDockableViewController *)viewController attached:(BOOL)attached
{
	if (attached) {
		[self insertViewController:viewController atIndex:[self.attachedViewControllers count]];
	} else {
		[self performAdditionWithViewController:viewController block:^{
			[self addReferencesForViewController:viewController];
			[viewController viewControllerWillDetach];
			
			INDockableAuxiliaryWindow *window = [self auxiliaryWindowForViewController:viewController];
			[window showViewController];
			[window center];
			[window makeKeyAndOrderFront:nil];
			
			[viewController viewControllerDidDetach];
		}];
	}
}

- (void)insertViewController:(INDockableViewController *)viewController atIndex:(NSUInteger)index
{
	NSParameterAssert(viewController);
	[self performAdditionWithViewController:viewController block:^{
		BOOL isAttached = [self.attachedViewControllers containsObject:viewController];
		if ([self.viewControllers containsObject:viewController] && !isAttached) {
			[self attachViewController:viewController];
		} else {
			[self addReferencesForViewController:viewController];
			if (![self.attachedViewControllers containsObject:viewController]) {
				[_attachedViewControllers insertObject:viewController atIndex:index];
			}
			[self reorderPrimaryWindow];
		}
		[viewController viewControllerDidAttach];
	}];
}

- (void)addReferencesForViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	[_viewControllers addObject:viewController];
	viewController.dockableWindowController = self;
}

- (void)replaceAttachedViewController:(INDockableViewController *)oldViewController withViewController:(INDockableViewController *)newViewController
{
	NSUInteger index = [_attachedViewControllers indexOfObject:oldViewController];
	if (index != NSNotFound) {
		[self replaceAttachedViewControllerAtIndex:index withViewController:newViewController];
	}
}

- (void)replaceAttachedViewControllerAtIndex:(NSUInteger)index withViewController:(INDockableViewController *)viewController
{	
	INDockableViewController *oldController = [_attachedViewControllers objectAtIndex:index];
	viewController.view.frame = oldController.view.frame;
	[self removeViewController:oldController layout:NO];
	[self insertViewController:viewController atIndex:index];
}

- (void)insertViewController:(INDockableViewController *)viewController positioned:(INDockableViewRelativePosition)position relativeTo:(INDockableViewController *)anotherViewController
{
	NSUInteger index = [self.attachedViewControllers indexOfObject:anotherViewController];
	if (index == NSNotFound) return;
	NSUInteger insertionIndex = NSNotFound;
	switch (position) {
		case INDockableViewLeft:
			insertionIndex = MAX(0, index - 1);
			break;
		case INDockableViewRight:
			insertionIndex = MIN([self.attachedViewControllers count], index + 1);
			break;
	}
	if (insertionIndex == NSNotFound) return;
	[self insertViewController:viewController atIndex:insertionIndex];
}

- (void)removeViewController:(INDockableViewController *)viewController
{
	[self removeViewController:viewController layout:YES];
}

- (void)removeViewController:(INDockableViewController *)viewController layout:(BOOL)layout
{
	NSParameterAssert(viewController);
	if (viewController == self.primaryViewController || [self.primaryWindow styleMask] & NSFullScreenWindowMask) return;
	[self performRemovalWithViewController:viewController block:^{
		NSWindow *window = viewController.window;
		[viewController.view removeFromSuperview];
		[viewController.titleBarView removeFromSuperview];
		viewController.dockableWindowController = nil;
		[_viewControllers removeObject:viewController];
		[_attachedViewControllers removeObject:viewController];
		if ([window isKindOfClass:[INDockableAuxiliaryWindow class]]) {
			[self removeAuxiliaryWindow:(INDockableAuxiliaryWindow *)window];
		}
		if (layout) [self reorderPrimaryWindow];
	}];
}

- (void)detachViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	if (viewController == self.primaryViewController || viewController.window != self.primaryWindow || [self.primaryWindow styleMask] & NSFullScreenWindowMask) return;;
	NSRect windowFrame = [viewController.view convertRect:viewController.view.bounds toView:nil];
	NSRect screenFrame = [self.primaryWindow convertRectToScreen:windowFrame];
	
	viewController.index = NSNotFound;
	[viewController viewControllerWillDetach];
	INDockableAuxiliaryWindow *window = [self auxiliaryWindowForViewController:viewController];
	screenFrame.size.height += window.titleBarHeight;
	[window setFrame:screenFrame display:YES];
	[window showViewControllerImage];
	[window orderFront:nil];
	
	[_attachedViewControllers removeObject:viewController];
	[self performBlockWithoutAnimation:^{
		[self reorderPrimaryWindow];
	}];
	[window showViewController];
	[viewController viewControllerDidDetach];
	
	if (_delegateFlags.viewControllerWasDetached) {
		[self.delegate dockableWindowController:self viewControllerWasDetached:viewController];
	}
}

- (void)attachViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	if (viewController == self.primaryViewController || viewController.window == self.primaryWindow) return;
	[viewController viewControllerWillAttach];
	INDockableAuxiliaryWindow *window = (INDockableAuxiliaryWindow *)viewController.window;
	[window showViewControllerImage];
	
	[_attachedViewControllers addObject:viewController];
	[self performBlockWithoutAnimation:^{
		[self reorderPrimaryWindow];
	}];
	
	[self removeAuxiliaryWindow:window];
	[viewController viewControllerDidAttach];
	
	if (_delegateFlags.viewControllerWasAttached) {
		[self.delegate dockableWindowController:self viewControllerWasAttached:viewController];
	}
}

- (void)setMinimumWidth:(CGFloat)width forViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	_minimumWidths[viewController.uniqueIdentifier] = @(width);
	[self updateLayoutForConstraintsChangeOnViewController:viewController];
}

- (void)setMaximumWidth:(CGFloat)width forViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	_maximumWidths[viewController.uniqueIdentifier] = @(width);
	[self updateLayoutForConstraintsChangeOnViewController:viewController];
}

- (void)setShouldAdjustSize:(BOOL)shouldAdjust ofViewController:(INDockableViewController *)viewController
{
	NSParameterAssert(viewController);
	_shouldAdjust[viewController.uniqueIdentifier] = @(shouldAdjust);
	[self updateLayoutForConstraintsChangeOnViewController:viewController];
}

- (void)updateLayoutForConstraintsChangeOnViewController:(INDockableViewController *)viewController
{
	if (viewController.attached) {
		if (viewController.window) {
			[self layoutPrimaryWindow];
		} else {
			[self configureConstraintsForWindow:self.primaryWindow];
		}
	} else {
		[self configureConstraintsForWindow:viewController.window];
	}
}

+ (Class)primaryWindowClass
{
	return [INDockablePrimaryWindow class];
}

+ (Class)auxiliaryWindowClass
{
	return [INDockableAuxiliaryWindow class];
}

#pragma mark - NSSplitViewDelegate

- (BOOL)splitView:(NSSplitView *)splitView shouldAdjustSizeOfSubview:(NSView *)subview
{
	NSNumber *shouldAdjust = _shouldAdjust[subview.identifier];
	if (shouldAdjust)
		return [shouldAdjust boolValue];
	return YES;
}

// Constraints code is based on BWSplitView <https://bitbucket.org/bwalkin/bwtoolkit/src/f164b18c9667/BWSplitView.m>

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)dividerIndex
{
	CGFloat newMinFromThisSubview = proposedMin;
	CGFloat newMaxFromNextSubview = proposedMin;
	
	NSView *thisSubview = splitView.subviews[dividerIndex];
	NSNumber *min = _minimumWidths[thisSubview.identifier];
	if (min) {
		newMinFromThisSubview = NSMinX(thisSubview.frame) + min.doubleValue;
	}
	NSUInteger nextIndex = dividerIndex + 1;
	if ([splitView.subviews count] > nextIndex) {
		NSView *nextSubview = splitView.subviews[nextIndex];
		NSNumber *max = _maximumWidths[nextSubview.identifier];
		if (max) {
			newMaxFromNextSubview = NSMaxX(nextSubview.frame) - max.doubleValue - splitView.dividerThickness;
		}
	}
	CGFloat newMin = fmax(newMinFromThisSubview, newMaxFromNextSubview);
	if (newMin > proposedMin)
		return newMin;
	return proposedMin;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)dividerIndex
{
	CGFloat newMaxFromThisSubview = proposedMax;
	CGFloat newMaxFromNextSubview = proposedMax;
	NSView *thisSubview = splitView.subviews[dividerIndex];
	NSNumber *max = _maximumWidths[thisSubview.identifier];
	if (max) {
		newMaxFromThisSubview = NSMinX(thisSubview.frame) + max.doubleValue;
	}
	NSUInteger nextIndex = dividerIndex + 1;
	if ([splitView.subviews count] > nextIndex) {
		NSView *nextSubview = splitView.subviews[nextIndex];
		NSNumber *min = _minimumWidths[nextSubview.identifier];
		if (min) {
			newMaxFromNextSubview = NSMaxX(nextSubview.frame) - min.doubleValue - splitView.dividerThickness;
		}
	}
	CGFloat newMax = fmin(newMaxFromThisSubview, newMaxFromNextSubview);
	if (newMax < proposedMax)
		return newMax;
	return proposedMax;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainSplitPosition:(CGFloat)proposedPosition ofSubviewAt:(NSInteger)dividerIndex
{
	return floor(proposedPosition);
}

- (void)splitViewWillResizeSubviews:(NSNotification *)aNotification
{
}

- (void)splitViewDidResizeSubviews:(NSNotification *)aNotification
{
	[self layoutTitleBarViews];
	[self configureConstraintsForWindow:self.primaryWindow];
}

- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
	[splitView adjustSubviews];
}

- (NSRect)splitView:(NSSplitView *)splitView additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
	return NSZeroRect;
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview
{
	return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex
{
	return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
	return NO;
}

#pragma mark - Private

- (void)configureSplitView
{
	INDockableSplitView *splitView = [[INDockableSplitView alloc] initWithFrame:[self.window.contentView bounds]];
	splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	splitView.delegate = self;
	[self.window.contentView addSubview:splitView];
	_splitView = splitView;
}

- (void)configurePrimaryViewController
{
	[self insertViewController:self.primaryViewController atIndex:0];
}

- (void)resetTitlebarHeights
{
	self.primaryWindow.titleBarHeight = self.titleBarHeight;
	[self.auxiliaryWindows enumerateObjectsUsingBlock:^(INDockableAuxiliaryWindow *window, BOOL *stop) {
		window.titleBarHeight = self.titleBarHeight;
	}];
}

- (void)layoutPrimaryWindow
{
	[self layoutViewControllers];
	[self layoutTitleBarViews];
}

- (CGFloat)minimumWidthForViewController:(INDockableViewController *)viewController
{
	NSString *identifier = viewController.uniqueIdentifier;
	NSNumber *min = _minimumWidths[identifier];
	NSNumber *shouldAdjust = nil;
	if (viewController.attached && _attachedViewControllers.count > 1) {
		shouldAdjust = _shouldAdjust[identifier];
	}
	NSRect frame = viewController.view.frame;
	if (shouldAdjust && !shouldAdjust.boolValue) {
		return NSWidth(frame);
	} else if (min) {
		return min.doubleValue;
	}
	return 0.0;
}

- (CGFloat)maximumWidthForViewController:(INDockableViewController *)viewController
{
	NSNumber *max = _maximumWidths[viewController.uniqueIdentifier];
	if (max) {
		return max.doubleValue;
	}
	return CGFLOAT_MAX;
}

- (void)layoutViewControllers
{
	__block CGFloat totalWidth = 0.0;
	__block CGFloat minWidth = 0.0;
	__block CGFloat maxWidth = 0.0;
	CGFloat dividerThickness = self.splitView.dividerThickness;
	[self.attachedViewControllers enumerateObjectsUsingBlock:^(INDockableViewController *viewController, NSUInteger idx, BOOL *stop) {
		viewController.index = idx;
		NSView *view = viewController.view;
		NSRect newFrame = view.frame;
		newFrame.size.height = NSHeight(self.splitView.frame);
		NSString *identifier = viewController.uniqueIdentifier;
		
		// Check for previously saved autosave data for the width of the view
		NSNumber *autosaveWidth = _loadedAutosaveData[identifier];
		if (autosaveWidth) {
			newFrame.size.width = autosaveWidth.doubleValue;
			[_loadedAutosaveData removeObjectForKey:identifier];
		}
		CGFloat min = [self minimumWidthForViewController:viewController];
		minWidth += min;
		newFrame.size.width = fmax(min, NSWidth(newFrame));
		
		CGFloat max = [self maximumWidthForViewController:viewController];
		if (max != CGFLOAT_MAX && maxWidth != CGFLOAT_MAX) {
			maxWidth += max;
			newFrame.size.width = fmin(max, NSWidth(newFrame));
		} else {
			// If any one of the views doesn't have a maximum width, don't restrict
			// the maximum width of the window itself
			maxWidth = CGFLOAT_MAX;
		}
		view.frame = newFrame;
		if (view.superview != self.splitView) {
			[self.splitView addSubview:view];
		}
		totalWidth += NSWidth(view.frame) + dividerThickness;
	}];
	totalWidth -= dividerThickness;
	NSRect windowFrame = self.primaryWindow.frame;
	windowFrame.size.width = totalWidth;
	
	NSRect splitViewFrame = self.splitView.frame;
	splitViewFrame.size.width = totalWidth;
	splitViewFrame.origin.x = 0.0;
	
	// Temporarily disable autoresizing of the split view and the title bar container
	// because otherwise they'd be redrawn at every step of the frame change.
	self.splitView.autoresizingMask = NSViewHeightSizable;
	_titleBarContainerView.autoresizingMask = NSViewHeightSizable;
	
	self.splitView.frame = splitViewFrame;
	
	// Window constraints (max/min window sizes calculated based on the max/min sizes
	// of the individual views)
	NSSize minSize = self.primaryWindow.minSize;
	minSize.width = minWidth;
	self.primaryWindow.minSize = minSize;
	
	if (maxWidth > 0.0) {
		NSSize maxSize = self.primaryWindow.maxSize;
		maxSize.width = maxWidth;
		self.primaryWindow.maxSize = maxSize;
	}
	
	// Reset the split view and title bar container autoresizing masks
	// back to their original values after the frame change.
	void (^cleanup)() = ^{
		self.splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		_titleBarContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	};
	void(^completion)() = ^{
		cleanup();
		[[NSNotificationCenter defaultCenter] postNotificationName:INDockableWindowFrameDidChangeNotification object:_primaryWindow];
	};
	
	// Return if the window frame doesn't need to be changed
	if (NSEqualRects(windowFrame, self.primaryWindow.frame)) {
		cleanup();
		return;
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:INDockableWindowFrameWillChangeNotification object:_primaryWindow];
	
	if ([self shouldAnimate]) {
		// Create a fake split view that displays an image of the original split view
		// because animating a window with a single image view is much more performant
		// than animating with the entire split view subview tree
		NSImageView *fakeSplitView = [[NSImageView alloc] initWithFrame:self.splitView.frame];
		fakeSplitView.image = self.splitView.in_image;
		fakeSplitView.autoresizingMask = NSViewHeightSizable;
		
		// Remove the split view and stick the fake split view in its place
		[self.splitView.superview addSubview:fakeSplitView positioned:NSWindowAbove relativeTo:self.splitView];
		[self.splitView removeFromSuperview];
		
		// Temporarily disable title bar layout because we don't want the title bar view
		// frames changing during the animation
		_isAnimating = YES;
		
		// Use a nonblocking NSAnimation subclass to animate the frame of the window
		INWindowFrameAnimation *animation = [[INWindowFrameAnimation alloc] initWithDuration:self.windowAnimationDuration animationCurve:self.windowAnimationCurve window:self.primaryWindow];
		[animation setCompletionBlock:^(BOOL finished) {
			// After completion, set the frame of the split view to the correct final value
			self.splitView.frame = fakeSplitView.frame;
			// Layout all the title bar views
			_isAnimating = NO;
			[self layoutTitleBarViews];
			// Add the split view back into the layer hierarchy and remove the fake
			[self.window.contentView addSubview:self.splitView positioned:NSWindowBelow relativeTo:nil];
			[fakeSplitView removeFromSuperview];
			completion();
		}];
		[animation startAnimationToFrame:windowFrame];
	} else {
		[self.primaryWindow setFrame:windowFrame display:YES];
		completion();
	}
}

- (void)layoutTitleBarViews
{
	if (_isAnimating) return;
	__block CGFloat currentOrigin = 0.0;
	CGFloat dividerThickness = self.splitView.dividerThickness;
	_titleBarContainerView.frame = self.primaryWindow.titleBarView.bounds;
	[self.attachedViewControllers enumerateObjectsUsingBlock:^(INDockableViewController *viewController, NSUInteger idx, BOOL *stop) {
		NSView *titleView = viewController.titleBarView;
		NSRect newFrame = titleView.frame;
		newFrame.size.width = NSWidth(viewController.view.frame) + dividerThickness + 1.0;
		newFrame.origin.x = currentOrigin;
		currentOrigin = NSMaxX(newFrame);
		titleView.frame = newFrame;
		titleView.autoresizingMask = NSViewNotSizable;
		if (titleView.superview != _titleBarContainerView) {
			[_titleBarContainerView addSubview:titleView];
		}
	}];
}

- (BOOL)shouldAnimate
{
	return (_tempDisableFrameAnimation || _isAnimating) ? NO : self.animatesFrameChange;
}

- (void)reorderPrimaryWindow
{
	[self reorderTitleBarViews];
	[self reorderViewControllers];
}

- (void)reorderViewControllers
{
	self.splitView.subviews = [NSArray array];
	[self layoutViewControllers];
}

- (void)reorderTitleBarViews
{
	_titleBarContainerView.subviews = [NSArray array];
	[self layoutTitleBarViews];
}

- (INDockableAuxiliaryWindow *)auxiliaryWindowForViewController:(INDockableViewController *)viewController
{
	INDockableAuxiliaryWindow *window = [[[self.class auxiliaryWindowClass] alloc] initWithViewController:viewController styleMask:self.windowStyleMask];
	window.titleBarHeight = self.titleBarHeight;
	[self configureConstraintsForWindow:window];
	[window setReleasedWhenClosed:NO];
	if (self.configureAuxiliaryWindowBlock)
		self.configureAuxiliaryWindowBlock(window);
	[self addAuxiliaryWindow:window];
	return window;
}

- (void)configureConstraintsForWindow:(NSWindow *)window
{
	NSSize minSize = NSZeroSize, maxSize = NSZeroSize;
	NSArray *viewControllers = nil;
	if (window == self.primaryWindow) {
		viewControllers = _attachedViewControllers;
	} else if ([window isKindOfClass:INDockableAuxiliaryWindow.class]) {
		viewControllers = @[[(INDockableAuxiliaryWindow *)window viewController]];
	}
	for (INDockableViewController *viewController in viewControllers) {
		minSize.width += [self minimumWidthForViewController:viewController];
		CGFloat max = [self maximumWidthForViewController:viewController];
		if (max != CGFLOAT_MAX && maxSize.width != CGFLOAT_MAX) {
			maxSize.width += max;
		} else {
			maxSize.width = CGFLOAT_MAX;
		}
	}
	minSize.height = self.minimumWindowHeight;
	window.minSize = minSize;
	maxSize.height = self.maximumWindowHeight;
	window.maxSize = maxSize;
}

- (void)addAuxiliaryWindow:(INDockableAuxiliaryWindow *)window
{
	if (!window) return;
	[_auxiliaryWindows addObject:window];
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(auxiliaryWindowWillClose:) name:NSWindowWillCloseNotification object:window];
	[nc addObserver:self selector:@selector(auxiliaryWindowDidMove:) name:NSWindowDidMoveNotification object:window];
	[nc addObserver:self selector:@selector(auxiliaryWindowFinishedMoving:) name:INDockableWindowFinishedMovingNotification object:window];
}

- (void)removeAuxiliaryWindow:(INDockableAuxiliaryWindow *)window
{
	if (!window) return;
	[[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:window];
	if (_delegateFlags.auxiliaryWindowDidClose) {
		[_delegate dockableWindowController:self auxiliaryWindowDidClose:window];
	}
	[window close];
	[_auxiliaryWindows removeObject:window];
}

#pragma mark - Notification

- (void)auxiliaryWindowWillClose:(NSNotification *)notification
{
	[self removeViewController:(INDockableViewController *)[notification.object viewController]];
}

- (void)auxiliaryWindowDidMove:(NSNotification *)notification
{
	INDockableAuxiliaryWindow *window = notification.object;
	CGFloat primaryMaxX = NSMaxX(self.primaryWindow.frame);
	CGFloat auxiliaryMinX = NSMinX(window.frame);
	if (fabs(auxiliaryMinX - primaryMaxX) <= self.attachmentProximity) {
		NSRect newWindowFrame = window.frame;
		newWindowFrame.origin.x = primaryMaxX;
		[window setFrame:newWindowFrame display:YES];
		_shouldAttachAuxiliaryWindowOnMouseUp = YES;
	} else {
		_shouldAttachAuxiliaryWindowOnMouseUp = NO;
	}
	_lastMovedAuxiliaryWindow = window;
}

- (void)auxiliaryWindowFinishedMoving:(NSNotification *)notification
{
	if (_shouldAttachAuxiliaryWindowOnMouseUp) {
		[self attachViewController:_lastMovedAuxiliaryWindow.viewController];
		_shouldAttachAuxiliaryWindowOnMouseUp = NO;
		_lastMovedAuxiliaryWindow = nil;
	}
}

- (void)primaryWindowDidMove:(NSNotification *)notification
{
	CGFloat primaryMaxX = NSMaxX(self.primaryWindow.frame);
	__block INDockableAuxiliaryWindow *closestWindow = nil;
	__block CGFloat closestProximity = CGFLOAT_MAX;
	[self.auxiliaryWindows enumerateObjectsUsingBlock:^(INDockableAuxiliaryWindow *window, BOOL *stop) {
		CGFloat auxiliaryMinX = NSMinX(window.frame);
		CGFloat dx = fabs(auxiliaryMinX - primaryMaxX);
		if (dx < closestProximity) {
			closestProximity = dx;
			closestWindow = window;
			if (dx <= self.attachmentProximity) {
				NSRect newWindowFrame = self.primaryWindow.frame;
				newWindowFrame.origin.x = auxiliaryMinX - NSWidth(newWindowFrame);
				[self.primaryWindow setFrame:newWindowFrame display:YES];
				_shouldAttachAuxiliaryWindowOnMouseUp = YES;
			} else {
				_shouldAttachAuxiliaryWindowOnMouseUp = NO;
			}
			_lastMovedAuxiliaryWindow = window;
		}
	}];
}

- (void)performBlockWithoutAnimation:(void(^)())block
{
	_tempDisableFrameAnimation = YES;
	if (block) block();
	_tempDisableFrameAnimation = NO;
}

- (void)performAdditionWithViewController:(INDockableViewController *)viewController block:(void(^)())block
{
	if (_delegateFlags.willAddViewController) {
		[self.delegate dockableWindowController:self willAddViewController:viewController];
	}
	if (block) block();
	if (_delegateFlags.didAddViewController) {
		[self.delegate dockableWindowController:self didAddViewController:viewController];
	}
}

- (void)performRemovalWithViewController:(INDockableViewController *)viewController block:(void(^)())block
{
	if (_delegateFlags.willRemoveViewController) {
		[self.delegate dockableWindowController:self willRemoveViewController:viewController];
	}
	if (block) block();
	if (_delegateFlags.didRemoveViewController) {
		[self.delegate dockableWindowController:self didRemoveViewController:viewController];
	}
}

- (void)detachControlTriggeredDetach:(NSNotification *)notification
{
	[self detachViewController:notification.object];
}
@end
