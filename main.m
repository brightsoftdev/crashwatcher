#import "main.h"
#import "GTM/GTMLogger.h"

#import "CrashLogFinder.h"
#import "ResizabilityExtensions.h"

static NSString* gTargetApp = @"UnknownApp"; // will be set to TotalTerminal, TotalFinder, etc.

@implementation Reporter
// =============================================================================
-(id) init {
    if ((self = [super init])) {
        remainingDialogTime_ = 0;
    }

    // Because the reporter is embedded in the framework (and many copies
    // of the framework may exist) its not completely certain that the OS
    // will obey the com.apple.PreferenceSync.ExcludeAllSyncKeys in our
    // Info.plist. To make sure, also set the key directly if needed.
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:@"com.apple.PreferenceSync.ExcludeAllSyncKeys"]) {
        [ud setBool:YES forKey:@"com.apple.PreferenceSync.ExcludeAllSyncKeys"];
    }

    return self;
}

// =============================================================================
-(BOOL) readConfigurationData {
    parameters_ = [[NSBundle mainBundle] infoDictionary];
    return YES;
}

// =============================================================================
-(BOOL) askUserPermissionToSend {
    // Initialize Cocoa, needed to display the alert
    NSApplicationLoad();

    // Get the timeout value for the notification.
    NSTimeInterval timeout = [self messageTimeout];

    NSInteger buttonPressed = NSAlertAlternateReturn;

    // Determine whether we should create a text box for user feedback.
    BOOL didLoadNib = [NSBundle loadNibNamed:@"CrashWatcher" owner:self];
    if (!didLoadNib) {
        return NO;
    }

    [self configureAlertWindow];

    buttonPressed = [self runModalWindow:alertWindow_ withTimeout:timeout];
    [alertWindow_ orderOut:self];
    return buttonPressed == NSAlertDefaultReturn;
}

-(void) configureAlertWindow {
    // Swap in localized values, making size adjustments to impacted elements as
    // we go. Remember that the origin is in the bottom left, so elements above
    // "fall" as text areas are shrunk from their overly-large IB sizes.

    [dialogTitle_ setStringValue:NSLocalizedString(@"crashDialogHeader", @"")];
    [commentMessage_ setStringValue:NSLocalizedString(@"crashDialogMsg", @"")];
    [dialogNote_ setStringValue:NSLocalizedString(@"crashDialogNote", @"")];

    // Localize the buttons, and keep the cancel button at the right distance.
    [sendButton_ setTitle:NSLocalizedString(@"sendReportButton", @"")];
    CGFloat sendButtonWidthDelta = [sendButton_ breakpad_smartSizeToFit];
    [cancelButton_ breakpad_shiftHorizontally:(-sendButtonWidthDelta)];
    [cancelButton_ setTitle:NSLocalizedString(@"cancelButton", @"")];
    [cancelButton_ breakpad_smartSizeToFit];
}

-(NSInteger) runModalWindow:(NSWindow*)window withTimeout:(NSTimeInterval)timeout {
    // Queue a |stopModal| message to be performed in |timeout| seconds.
    if (timeout > 0.001) {
        remainingDialogTime_ = timeout;
        SEL updateSelector = @selector(updateSecondsLeftInDialogDisplay:);
        messageTimer_ = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:updateSelector
                                                       userInfo:nil
                                                        repeats:YES];
    }

    // Run the window modally and wait for either a |stopModal| message or a button click.
    [self updateSecondsLeftInDialogDisplay:messageTimer_];
    [NSApp activateIgnoringOtherApps:YES];
    NSInteger returnMethod = [NSApp runModalForWindow:window];

    return returnMethod;
}

// UI Button Actions
// =============================================================================
-(IBAction) sendReport:(id)sender {
    // Use NSAlertDefaultReturn so that the return value of |runModalWithWindow|
    // matches the AppKit function NSRunAlertPanel()
    [NSApp stopModalWithCode:NSAlertDefaultReturn];
}

-(IBAction) cancel:(id)sender {
    // Use NSAlertDefaultReturn so that the return value of |runModalWithWindow|
    // matches the AppKit function NSRunAlertPanel()
    [NSApp stopModalWithCode:NSAlertAlternateReturn];
}

-(void) updateSecondsLeftInDialogDisplay:(NSTimer*)theTimer {
    remainingDialogTime_ -= 1;

    NSString* countdownMessage;
    NSString* formatString;

    int displayedTimeLeft; // This can be either minutes or seconds.

    if (remainingDialogTime_ > 59) {
        // calculate minutes remaining for UI purposes
        displayedTimeLeft = (int)(remainingDialogTime_ / 60);

        if (displayedTimeLeft == 1) {
            formatString = NSLocalizedString(@"countdownMsgMinuteSingular", @"");
        } else {
            formatString = NSLocalizedString(@"countdownMsgMinutesPlural", @"");
        }
    } else {
        displayedTimeLeft = (int)remainingDialogTime_;
        if (displayedTimeLeft == 1) {
            formatString = NSLocalizedString(@"countdownMsgSecondSingular", @"");
        } else {
            formatString = NSLocalizedString(@"countdownMsgSecondsPlural", @"");
        }
    }
    countdownMessage = [NSString stringWithFormat:formatString,
                        displayedTimeLeft];
    if (remainingDialogTime_ <= 30) {
        [countdownLabel_ setTextColor:[NSColor redColor]];
    }
    [self setCountdownMessage:countdownMessage];
    if (remainingDialogTime_ <= 0) {
        [messageTimer_ invalidate];
        [NSApp stopModal];
    }
}

#pragma mark Accessors
#pragma mark -
// =============================================================================

-(NSString*) countdownMessage {
    return [[countdownMessage_ retain] autorelease];
}

-(void) setCountdownMessage:(NSString*)value {
    if (countdownMessage_ != value) {
        [countdownMessage_ release];
        countdownMessage_ = [value copy];
    }
}

#pragma mark -

-(NSTimeInterval) messageTimeout {
    NSTimeInterval timeout = [[parameters_ objectForKey:@"ConfirmTimeout"] floatValue];

    return timeout;
}

-(NSString*) runShellCommand:(NSString*)name withCrashFile:(NSString*)cfile {
    NSTask* task = [[NSTask alloc] init];
    
    NSString* command = [NSString stringWithFormat:@"\"%@\" \"%@\"", [[NSBundle bundleForClass:[self class]] pathForResource:name ofType:@"rb"], cfile];

    [task setLaunchPath:@"/bin/bash"];
    NSArray	*args = [NSArray arrayWithObjects:@"-l",
    				 @"-c",
    				 command,
    				 nil];
    [task setArguments: args];    

    NSPipe* pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    NSFileHandle* file;
    file = [pipe fileHandleForReading];

    [task launch];

    NSString* string;
    string = [[NSString alloc] initWithData:[file readDataToEndOfFile] encoding:NSUTF8StringEncoding];

    [task waitUntilExit];
    [task release];

    return string;
}

// http://vgable.com/blog/2008/03/05/calling-the-command-line-from-cocoa/
-(int) askShellCommand:(NSString*)name withCrashFile:(NSString*)cfile {
    NSTask* task = [[NSTask alloc] init];

    NSString* command = [NSString stringWithFormat:@"\"%@\" \"%@\"", [[NSBundle bundleForClass:[self class]] pathForResource:name ofType:@"rb"], cfile];

    [task setLaunchPath:@"/bin/bash"];
    NSArray	*args = [NSArray arrayWithObjects:@"-l",
    				 @"-c",
    				 command,
    				 nil];
    [task setArguments: args];    

    NSPipe* pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    NSFileHandle* file;
    file = [pipe fileHandleForReading];

    [task launch];
    [task waitUntilExit];

    int status = [task terminationStatus];
    [task release];

    return status;
}

-(NSString*) readTargetAppVersion {
    // CrashWatcher bundle should be located in Resources folder of the target app
    //   /Library/ScriptingAdditions/TotalTerminal.osax/Contents/Resources/TotalTerminal.bundle/Contents/Resources/TotalTerminalCrashWatcher.app
    // so going for 
    //   /Library/ScriptingAdditions/TotalTerminal.osax/Contents/Resources/TotalTerminal.bundle/Contents/Info.plist
    // should be safe
    
    NSString* bundlePath = [[NSBundle bundleForClass:[self class]] bundlePath];
    NSDictionary* dict = [[NSDictionary alloc] initWithContentsOfFile:[NSString stringWithFormat:@"%@/../../Info.plist", bundlePath]];
    if (!dict) return @"???";
    id o = [dict objectForKey:@"CFBundleVersion"];
    if (!o) return @"?";
    return o;
}

-(void) report:(NSString*)lastCrash {
    NSString* gistUrl = @"unable to find last crash :-(";
    NSString* extraInfo = @"";

    if (lastCrash) {
        NSLog(@"Uploading crash report to gist.github.com: %@", lastCrash);
        gistUrl = [self runShellCommand:@"upload-gist" withCrashFile:lastCrash];
        NSLog(@"  => %@", gistUrl);
        if (gistUrl) {
            extraInfo = [self runShellCommand:@"extract-crash-info" withCrashFile:lastCrash];
            if (!extraInfo) {
                extraInfo = @"";
            }
        }
    }

    NSString* version = [self readTargetAppVersion];
    NSString* subjectString = [NSString stringWithFormat:@"%@ %@ crash %@", gTargetApp, version, extraInfo];
    NSString* email = @"crash-reports@binaryage.com";
    NSString* emailBody =
        [NSString stringWithFormat:
         @"Hi Antonin,\n\nMy %@ just crashed!\n\nThe crash report is available here:\n%@\n\n>\n> You may help me fix the problem by describing what happened before the crash.\n> I appreciate your help and I read these crash reports, but don't expect my direct answer.\n> For further discussion please open a topic at\n> http://getsatisfaction.com/binaryage.\n>\n> Thank you, Antonin",
         gTargetApp,
         gistUrl];
    [gistUrl release];

    BOOL result = NO;
    NSString* mailto = [NSString stringWithFormat:@"mailto:%@?SUBJECT=%@&BODY=%@", email, subjectString, emailBody];
    NSString* encodedURLString = [mailto stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (encodedURLString) {
        result = [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:encodedURLString]];

        NSArray* apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.mail"];
        if ([apps count] > 0) {
            GTMLoggerDebug(@"activating ... %@", apps);
            [(NSRunningApplication*)[apps objectAtIndex:0] activateWithOptions:NSApplicationActivateAllWindows];
        }
    }
}

@end

Reporter * reporter = NULL;
bool dialogInProgress = false;

void mycallback(
        ConstFSEventStreamRef streamRef,
        void* clientCallBackInfo,
        size_t numEvents,
        void* eventPaths,
        const FSEventStreamEventFlags eventFlags[],
        const FSEventStreamEventId eventIds[]) {
    GTMLoggerDebug(@"Reporter awaken");
    if (dialogInProgress) {
        GTMLoggerDebug(@"Dialog still open - ignoring");
        return;
    }

    dialogInProgress = true;

    NSArray* crashFiles = [CrashLogFinder findCrashLogsSince:[[NSDate date] addTimeInterval:-10]]; // 10 seconds ago
    NSString* lastCrash = NULL;
    if ([crashFiles count] > 0) {
        for (NSString* crash in crashFiles) {
            int status = [reporter askShellCommand:@"related-crash-report" withCrashFile:crash];
            if (status == 1) {
                NSLog(@"'%@' crash report was related to the target app -> open Crash Reporting Dialog", crash);
                lastCrash = [crashFiles objectAtIndex:[crashFiles count] - 1];
                break;
            } else {
                NSLog(@"'%@' crash report was not related to the target app", crash);
            }
        }
    }

    if (lastCrash) {
        BOOL okayToSend = [reporter askUserPermissionToSend];
        if (okayToSend) {
            GTMLoggerDebug(@"Show Report Dialog");
            [reporter report:lastCrash];
            GTMLoggerDebug(@"Report Sent!");
        } else {
            GTMLoggerDebug(@"Not sending crash report okayToSend=%d", okayToSend);
        }
    }

    dialogInProgress = false;
}

static volatile BOOL caughtSIGINT = NO;
void handle_SIGINT(int signum) {
    caughtSIGINT = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

void handle_SIGUSR1(int signum) {
    mycallback(NULL, NULL, 0, NULL, 0, 0);
}

static int lock = 0;

static NSString* lockPath() {
    NSString* cachedLockPath = nil;
    
    if (!cachedLockPath) {
        cachedLockPath = [[NSString stringWithFormat:@"~/Library/Application Support/.%@CrashWatcher.lock", gTargetApp] stringByStandardizingPath];
    }
    return cachedLockPath;
}

static bool acquireLock() {
    const char* path = [lockPath() fileSystemRepresentation];
    lock = open(path, O_CREAT|O_RDWR);
    if (flock(lock, LOCK_EX|LOCK_NB) != 0) {
        NSLog(@"Unable to obtain lock '%s' - exiting to prevent multiple CrashWatcher instances", path);
        close(lock);
        return false;
    }
    return true;
}

static void releaseLock() {
    if (!lock) return;
    flock(lock, LOCK_UN|LOCK_NB);
    close(lock);
    unlink([lockPath() fileSystemRepresentation]);
}

static void initTargetApp() {
    gTargetApp = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"TargetApp"];
    if (!gTargetApp || ![gTargetApp isKindOfClass:[NSString class]]) {
        NSLog(@"TargetApp key is missing in Info.plist");
        gTargetApp = @"UnknownApp";
    }
}

// =============================================================================
int main(int argc, const char* argv[]) {
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    initTargetApp();
    
    // prevent multiple instances
    if (!acquireLock()) {
        [pool release];
        exit(1);
    }
    
    signal(SIGHUP, SIG_IGN);
    signal(SIGUSR1, handle_SIGUSR1);
    signal(SIGUSR2, SIG_IGN);
    signal(SIGINT, handle_SIGINT);

#if DEBUG
    // Log to stderr in debug builds.
    [GTMLogger setSharedLogger:[GTMLogger standardLoggerWithStderr]];
#endif
    GTMLoggerDebug(@"Reporter Launched, argc=%d", argc);

    reporter = [[Reporter alloc] init];
    
    // gather the configuration data
    if (![reporter readConfigurationData]) {
        GTMLoggerDebug(@"reporter readConfigurationData failed");
        [reporter release];
        [pool release];
        exit(10);
    }
    
    NSString* path = [@"~/Library/Logs/DiagnosticReports" stringByStandardizingPath];
    NSLog(@"Watching '%@' for recent crash reports with prefix '%@'", path, [CrashLogFinder crashLogPrefix]);
    CFArrayRef pathsToWatch = CFArrayCreate(NULL, (const void**)&path, 1, NULL);
    void* callbackInfo = NULL;
    CFAbsoluteTime latency = 1.0;

    FSEventStreamRef stream = FSEventStreamCreate(NULL,
            &mycallback,
            callbackInfo,
            pathsToWatch,
            kFSEventStreamEventIdSinceNow,
            latency,
            kFSEventStreamCreateFlagNone
            );

    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    FSEventStreamStart(stream);

    GTMLoggerDebug(@"looping...");
    CFRunLoopRun();
    if (caughtSIGINT) {
        NSLog(@"caught SIGINT - exiting...");
    }

    FSEventStreamStop(stream);
    FSEventStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    [reporter release];
    releaseLock();
    [pool release];

    return 0;
}
