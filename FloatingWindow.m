#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()

// Main UI Components
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIImageView *iconView;

// State tracking
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, assign) CGRect expandedFrame;
@property (nonatomic, assign) CGRect minimizedFrame;
@property (nonatomic, assign) BOOL isDragging;

@end

@implementation FloatingWindow

#pragma mark - Initialization

- (instancetype)init {
    // Setup with window scene for iOS 13+
    if (@available(iOS 13.0, *)) {
        UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self = [super initWithWindowScene:(UIWindowScene *)scene];
        } else {
            self = [super init];
        }
    } else {
        self = [super init];
    }
    
    if (self) {
        // Basic window configuration
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
        self.layer.cornerRadius = 25;
        self.clipsToBounds = YES;
        
        // Configure shadow
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        // Initialize frames for both states
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        
        // Frame for expanded state (almost full screen with margins)
        CGFloat margin = 20.0;
        CGFloat expandedWidth = screenBounds.size.width - (2 * margin);
        CGFloat expandedHeight = screenBounds.size.height - (2 * margin) - 20;
        self.expandedFrame = CGRectMake(
                                        margin,
                                        margin + 10,
                                        expandedWidth,
                                        expandedHeight
                                        );
        
        // Frame for minimized state (AssistiveTouch style)
        CGFloat minimizedSize = 50;
        self.minimizedFrame = CGRectMake(
                                         screenBounds.size.width - minimizedSize - 20,
                                         screenBounds.size.height * 0.4,
                                         minimizedSize,
                                         minimizedSize
                                         );
        
        // Initial state
        self.frame = self.minimizedFrame;
        self.windowState = FloatingWindowStateMinimized;
        
        self.isPreviewActive = NO;
        self.isReceivingFrames = NO;
        
        // Setup UI components
        [self setupUI];
        [self setupGestureRecognizers];
        
        // Update appearance for initial state
        [self updateAppearanceForState:self.windowState];
        
        writeLog(@"[FloatingWindow] Initialized in minimized state");
    }
    return self;
}

#pragma mark - UI Setup

- (void)setupUI {
    // Main container
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentView];
    
    // Layout for contentView to fill the window
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    
    // Setup UI components
    [self setupVideoView];
    [self setupToggleButton];
    [self setupLoadingIndicator];
    [self setupMinimizedIcon];
}

- (void)setupVideoView {
    // Use RTCMTLVideoView for efficient video rendering
    self.videoView = [[RTCMTLVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
}

- (void)setupToggleButton {
    // Button to toggle preview on/off
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor];
    self.toggleButton.layer.cornerRadius = 10;
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.toggleButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.toggleButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
        [self.toggleButton.widthAnchor constraintEqualToConstant:180],
        [self.toggleButton.heightAnchor constraintEqualToConstant:40],
    ]];
}

- (void)setupLoadingIndicator {
    // Loading spinner
    if (@available(iOS 13.0, *)) {
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.loadingIndicator.color = [UIColor whiteColor];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        #pragma clang diagnostic pop
    }
    
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

- (void)setupMinimizedIcon {
    // Create icon for minimized state
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor whiteColor];
    [self addSubview:self.iconView];
    
    // Center the icon
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26]
    ]];
    
    // Set initial icon
    [self updateMinimizedIconWithState];
    
    // Initially hidden until window is minimized
    self.iconView.hidden = YES;
}

- (void)setupGestureRecognizers {
    // Pan gesture for moving the window
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    panGesture.maximumNumberOfTouches = 1;
    panGesture.minimumNumberOfTouches = 1;
    [self addGestureRecognizer:panGesture];
    
    // Tap to expand/minimize
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    
    // Configure dependencies between gestures to avoid conflicts
    [tapGesture requireGestureRecognizerToFail:panGesture];
}

#pragma mark - Public Methods

- (void)show {
    // Configure for initial state
    self.frame = self.minimizedFrame;
    self.windowState = FloatingWindowStateMinimized;
    [self updateAppearanceForState:self.windowState];
    
    // Make visible
    self.hidden = NO;
    self.alpha = 0;
    
    // Animate entry
    self.transform = CGAffineTransformMakeScale(0.5, 0.5);
    
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 0.8; // Start with reduced alpha for minimized
    } completion:nil];
    
    [self makeKeyAndVisible];
    writeLog(@"[FloatingWindow] Window shown");
}

- (void)hide {
    [self stopPreview];
    
    // Animate exit
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.5, 0.5);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    
    writeLog(@"[FloatingWindow] Window hidden");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        [self startPreview];
    }
}

- (void)startPreview {
    // Check if WebRTCManager is present
    if (!self.webRTCManager) {
        writeLog(@"[FloatingWindow] WebRTCManager not initialized");
        return;
    }
    
    self.isPreviewActive = YES;
    [self.toggleButton setTitle:@"Desativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor redColor]; // Red when active
    
    // Show loading indicator
    [self.loadingIndicator startAnimating];
    
    // Start WebRTC
    @try {
        [self.webRTCManager startWebRTC];
        
        // Ativar explicitamente o FrameBridge quando iniciamos o preview
        [FrameBridge sharedInstance].isActive = YES;
        writeLog(@"[FloatingWindow] FrameBridge ativado explicitamente ao iniciar preview");
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exception when starting WebRTC: %@", exception);
        self.isPreviewActive = NO;
        [self.loadingIndicator stopAnimating];
        
        // Revert UI
        [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        self.toggleButton.backgroundColor = [UIColor greenColor];
        return;
    }
    
    // Expand if minimized
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    }
    
    // Update minimized icon
    [self updateMinimizedIconWithState];
}

- (void)stopPreview {
    if (!self.isPreviewActive) return;
    
    self.isPreviewActive = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor]; // Green when inactive
    
    // Stop loading indicator
    [self.loadingIndicator stopAnimating];
    
    // Mark as not receiving frames
    self.isReceivingFrames = NO;
    
    // Desativa explicitamente o FrameBridge quando paramos o preview
    [FrameBridge sharedInstance].isActive = NO;
    writeLog(@"[FloatingWindow] FrameBridge desativado explicitamente ao parar preview");
    
    // Disconnect WebRTC
    if (self.webRTCManager) {
        @try {
            // Send bye message
            [self.webRTCManager sendByeMessage];
            
            // Disable after short delay to ensure message is sent
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.webRTCManager stopWebRTC:YES];
            });
        } @catch (NSException *exception) {
            writeLog(@"[FloatingWindow] Exception when disabling WebRTC: %@", exception);
            [self.webRTCManager stopWebRTC:YES];
        }
    }
    
    // Update minimized icon
    [self updateMinimizedIconWithState];
}

- (void)updateConnectionStatus:(NSString *)status {
    // Update visual state (icon color when minimized)
    [self updateMinimizedIconWithState];
}

#pragma mark - WebRTCManagerDelegate

- (void)didUpdateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateConnectionStatus:status];
    });
}

- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Add video to view
        [videoTrack addRenderer:self.videoView];
        
        // Stop loading indicator
        [self.loadingIndicator stopAnimating];
        
        // Update state
        self.isReceivingFrames = YES;
    });
}

- (void)didChangeConnectionState:(WebRTCManagerState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update UI based on connection state
        switch (state) {
            case WebRTCManagerStateConnecting:
                [self.loadingIndicator startAnimating];
                break;
                
            case WebRTCManagerStateConnected:
                // Expand if minimized
                if (self.windowState == FloatingWindowStateMinimized) {
                    [self setWindowState:FloatingWindowStateExpanded];
                }
                break;
                
            case WebRTCManagerStateError:
            case WebRTCManagerStateDisconnected:
                self.isReceivingFrames = NO;
                break;
                
            default:
                break;
        }
        
        // Update minimized icon
        [self updateMinimizedIconWithState];
        
        // Update background color
        [self updateBackgroundColorForState];
    });
}

#pragma mark - State Management

- (void)setWindowState:(FloatingWindowState)windowState {
    if (_windowState == windowState) return;
    
    _windowState = windowState;
    [self updateAppearanceForState:windowState];
}

- (void)updateAppearanceForState:(FloatingWindowState)state {
    // Determine and apply the appearance based on state
    switch (state) {
        case FloatingWindowStateMinimized:
            [self animateToMinimizedState];
            break;
            
        case FloatingWindowStateExpanded:
            [self animateToExpandedState];
            break;
    }
}

- (void)animateToMinimizedState {
    // Update the icon before animation
    [self updateMinimizedIconWithState];
    self.iconView.hidden = NO;
    
    // Animate to minimized version
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        // Apply minimized frame
        self.frame = self.minimizedFrame;
        
        // Adjust appearance for AssistiveTouch
        self.layer.cornerRadius = self.frame.size.width / 2;
        
        // Configure transparency
        self.alpha = 0.8;
        
        // Hide UI elements
        self.toggleButton.alpha = 0;
        self.videoView.alpha = 0;
        
        // Adjust background color based on state
        [self updateBackgroundColorForState];
    } completion:^(BOOL finished) {
        // Confirm that elements are hidden
        self.toggleButton.hidden = YES;
        self.videoView.hidden = YES;
    }];
}

- (void)animateToExpandedState {
    // Prepare to expand
    self.toggleButton.hidden = NO;
    self.videoView.hidden = NO;
    
    // Hide the minimized icon
    self.iconView.hidden = YES;
    
    // Animate to expanded version
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        // Apply expanded frame
        self.frame = self.expandedFrame;
        
        // Adjust appearance
        self.layer.cornerRadius = 12;
        
        // Configure transparency
        self.alpha = 1.0;
        
        // Show UI elements
        self.toggleButton.alpha = 1.0;
        self.videoView.alpha = 1.0;
        
        // Dark background
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
    } completion:nil];
}

- (void)updateBackgroundColorForState {
    // Update background color based on current state
    if (self.windowState != FloatingWindowStateMinimized) return;
    
    if (self.isPreviewActive) {
        if (self.isReceivingFrames) {
            // Green when receiving frames
            self.backgroundColor = [UIColor colorWithRed:0.0 green:0.7 blue:0.0 alpha:0.9];
        } else {
            // Yellow when connected but not receiving
            self.backgroundColor = [UIColor colorWithRed:0.7 green:0.7 blue:0.0 alpha:0.9];
        }
    } else {
        // Gray when disconnected
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
    }
}

- (void)updateMinimizedIconWithState {
    UIImage *image = nil;
    
    if (@available(iOS 13.0, *)) {
        if (self.isPreviewActive) {
            image = [UIImage systemImageNamed:@"video.fill"]; // Filled icon when active
            self.iconView.tintColor = [UIColor greenColor];   // Green when active
        } else {
            image = [UIImage systemImageNamed:@"video.slash"]; // Slashed icon when disabled
            self.iconView.tintColor = [UIColor redColor];     // Red when disabled
        }
    }
    
    if (!image) {
        // Fallback for iOS < 13
        CGSize iconSize = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(iconSize, NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) {
            CGContextSetFillColorWithColor(context,
                self.isPreviewActive ? [UIColor greenColor].CGColor : [UIColor redColor].CGColor);
            CGContextFillEllipseInRect(context, CGRectMake(0, 0, iconSize.width, iconSize.height));
            image = UIGraphicsGetImageFromCurrentImageContext();
        }
        UIGraphicsEndImageContext();
    }
    
    self.iconView.image = image;
    [self updateBackgroundColorForState];
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
        self.isDragging = YES;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        self.isDragging = NO;
        if (self.windowState == FloatingWindowStateMinimized) {
            [self snapToEdgeIfNeeded];
        }
    }
}

- (void)snapToEdgeIfNeeded {
    // Implement snap to edge when minimized
    if (self.windowState != FloatingWindowStateMinimized) return;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat padding = 10;
    
    // Decide which edge to snap to (right or left)
    if (center.x < screenBounds.size.width / 2) {
        // Snap to left edge
        center.x = self.frame.size.width / 2 + padding;
    } else {
        // Snap to right edge
        center.x = screenBounds.size.width - self.frame.size.width / 2 - padding;
    }
    
    // Animate the movement
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.center = center;
    } completion:^(BOOL finished) {
        // Update the minimized frame
        self.minimizedFrame = self.frame;
    }];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.isDragging) {
        return;
    }
    
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    } else {
        // Check if tapped on toggleButton
        CGPoint location = [gesture locationInView:self];
        CGPoint pointInButton = [self.toggleButton convertPoint:location fromView:self];
        
        if (![self.toggleButton pointInside:pointInButton withEvent:nil]) {
            [self setWindowState:FloatingWindowStateMinimized];
        }
    }
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    // Update frame size record
    self.lastFrameSize = size;
    
    // Mark as receiving frames only if dimensions are valid
    if (size.width > 0 && size.height > 0) {
        self.isReceivingFrames = YES;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Stop loading indicator
            [self.loadingIndicator stopAnimating];
            
            // Update minimized icon state
            [self updateMinimizedIconWithState];
        });
    }
}

@end
