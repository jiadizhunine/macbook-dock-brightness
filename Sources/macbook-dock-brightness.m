#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>

static NSString *const MDBVersion = @"0.1.0";
static NSString *const MDBConfigEnvironmentVariable = @"MDB_CONFIG_PATH";
static NSString *const MDBAutoBrightnessKey = @"CBAutoBrightnessEnabled";

@interface DisplayServicesClient : NSObject
- (BOOL)setProperty:(id)value
            withKey:(NSString *)key
         andDisplay:(uint64_t)displayID;
- (id)copyPropertyForKey:(NSString *)key andDisplay:(uint64_t)displayID;
@end

typedef int (*MDBGetBrightnessFunction)(CGDirectDisplayID, float *);
typedef int (*MDBSetBrightnessFunction)(CGDirectDisplayID, float);

@interface MDBConfig : NSObject
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t modelID;
@property(nonatomic) uint32_t serialNumber;
@property(nonatomic) float dockedBrightness;
@property(nonatomic) float undockedBrightness;
@property(nonatomic) BOOL dockedAutoBrightness;
@property(nonatomic) BOOL undockedAutoBrightness;
@property(nonatomic) NSTimeInterval watchdogInterval;

+ (instancetype)configFromFile:(NSString *)path error:(NSString **)error;
- (NSDictionary *)dictionaryRepresentation;
@end

@implementation MDBConfig

+ (instancetype)configFromFile:(NSString *)path error:(NSString **)error {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                         options:0
                                           error:&readError];
    if (!data) {
        if (error) {
            *error = [NSString stringWithFormat:@"Could not read %@: %@",
                                                     path,
                                                     readError.localizedDescription];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSString stringWithFormat:@"Invalid JSON configuration: %@",
                                                     jsonError.localizedDescription ?: @"root must be an object"];
        }
        return nil;
    }

    NSDictionary *root = object;
    NSNumber *schemaVersion = root[@"schemaVersion"];
    id targetObject = root[@"targetDisplay"];
    id brightnessObject = root[@"brightness"];
    id autoBrightnessObject = root[@"autoBrightness"];
    id watchdogObject = root[@"watchdogIntervalSeconds"];
    if (![schemaVersion isKindOfClass:[NSNumber class]] ||
        schemaVersion.integerValue != 1 ||
        ![targetObject isKindOfClass:[NSDictionary class]] ||
        ![brightnessObject isKindOfClass:[NSDictionary class]] ||
        ![autoBrightnessObject isKindOfClass:[NSDictionary class]] ||
        (watchdogObject && ![watchdogObject isKindOfClass:[NSNumber class]])) {
        if (error) {
            *error = @"Configuration containers or schemaVersion are invalid.";
        }
        return nil;
    }

    NSDictionary *target = targetObject;
    NSDictionary *brightness = brightnessObject;
    NSDictionary *autoBrightness = autoBrightnessObject;
    NSNumber *vendor = target[@"vendorID"];
    NSNumber *model = target[@"modelID"];
    id serialObject = target[@"serialNumber"];
    NSNumber *docked = brightness[@"docked"];
    NSNumber *undocked = brightness[@"undocked"];
    NSNumber *dockedAuto = autoBrightness[@"docked"];
    NSNumber *undockedAuto = autoBrightness[@"undocked"];
    NSNumber *watchdog = watchdogObject;

    if (![vendor isKindOfClass:[NSNumber class]] ||
        ![model isKindOfClass:[NSNumber class]] ||
        (serialObject && ![serialObject isKindOfClass:[NSNumber class]]) ||
        ![docked isKindOfClass:[NSNumber class]] ||
        ![undocked isKindOfClass:[NSNumber class]] ||
        ![dockedAuto isKindOfClass:[NSNumber class]] ||
        ![undockedAuto isKindOfClass:[NSNumber class]]) {
        if (error) {
            *error = @"Configuration is missing a required target, brightness, or auto-brightness value.";
        }
        return nil;
    }

    NSNumber *serial = [serialObject isKindOfClass:[NSNumber class]] ? serialObject : nil;

    double dockedValue = docked.doubleValue;
    double undockedValue = undocked.doubleValue;
    double watchdogValue = watchdog ? watchdog.doubleValue : 2.0;
    if (vendor.unsignedLongLongValue == 0 ||
        model.unsignedLongLongValue == 0 ||
        vendor.unsignedLongLongValue > UINT32_MAX ||
        model.unsignedLongLongValue > UINT32_MAX ||
        (serial && serial.unsignedLongLongValue > UINT32_MAX) ||
        fabs(dockedValue) > 0.000001 ||
        undockedValue < 0.05 || undockedValue > 1.0 ||
        dockedAuto.boolValue || !undockedAuto.boolValue ||
        watchdogValue < 1.0 || watchdogValue > 60.0) {
        if (error) {
            *error = @"Configuration values are outside their supported ranges.";
        }
        return nil;
    }

    MDBConfig *config = [[MDBConfig alloc] init];
    config.vendorID = vendor.unsignedIntValue;
    config.modelID = model.unsignedIntValue;
    config.serialNumber = serial ? serial.unsignedIntValue : 0;
    config.dockedBrightness = (float)dockedValue;
    config.undockedBrightness = (float)undockedValue;
    config.dockedAutoBrightness = dockedAuto.boolValue;
    config.undockedAutoBrightness = undockedAuto.boolValue;
    config.watchdogInterval = watchdogValue;
    return config;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"schemaVersion" : @1,
        @"targetDisplay" : @{
            @"vendorID" : @(self.vendorID),
            @"modelID" : @(self.modelID),
            @"serialNumber" : @(self.serialNumber)
        },
        @"brightness" : @{
            @"docked" : @(self.dockedBrightness),
            @"undocked" : @(self.undockedBrightness)
        },
        @"autoBrightness" : @{
            @"docked" : @(self.dockedAutoBrightness),
            @"undocked" : @(self.undockedAutoBrightness)
        },
        @"watchdogIntervalSeconds" : @(self.watchdogInterval)
    };
}

@end

typedef struct {
    CGDirectDisplayID builtInDisplay;
    CGDirectDisplayID targetDisplay;
    BOOL targetOnline;
    BOOL targetActive;
    BOOL targetMirroredWithBuiltIn;
} MDBDisplayState;

static void *gCoreBrightnessHandle = NULL;
static void *gDisplayServicesHandle = NULL;
static MDBGetBrightnessFunction gGetBrightness = NULL;
static MDBSetBrightnessFunction gSetBrightness = NULL;
static MDBConfig *gConfig = nil;
static NSInteger gLastAppliedTargetState = -1;
static NSUInteger gConsecutiveFailures = 0;
static NSTimeInterval gNextWatchdogRetry = 0;
static BOOL gNeedsRetry = NO;
static NSInteger gLastObservedTargetState = -1;
static BOOL gDiscoveryFailureObserved = NO;
static uint64_t gScheduleGeneration = 0;
static id gWakeObserver = nil;
static id gScreensWakeObserver = nil;
static id gScreenParametersObserver = nil;
static dispatch_source_t gConnectionWatchdog = nil;
static dispatch_source_t gTerminationSignal = nil;
static dispatch_source_t gInterruptSignal = nil;
static BOOL gApplyPending = NO;

static BOOL MDBRestoreBuiltInDisplay(MDBConfig *config);

static NSString *MDBConfigPath(void) {
    NSString *customPath = NSProcessInfo.processInfo.environment[MDBConfigEnvironmentVariable];
    if (customPath.length > 0) {
        return [customPath stringByStandardizingPath];
    }
    return [[NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/MacBookDockBrightness/config.json"]
        stringByStandardizingPath];
}

static NSString *MDBStatePath(void) {
    NSString *customPath = NSProcessInfo.processInfo.environment[@"MDB_STATE_PATH"];
    if (customPath.length > 0) {
        return [customPath stringByStandardizingPath];
    }
    return [MDBConfigPath().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"state.json"];
}

static BOOL MDBSetOwnerOnlyPermissions(NSString *path, NSString **failureReason) {
    NSError *permissionsError = nil;
    BOOL success = [NSFileManager.defaultManager
        setAttributes:@{NSFilePosixPermissions : @0600}
         ofItemAtPath:path
                error:&permissionsError];
    if (!success && failureReason) {
        *failureReason = [NSString stringWithFormat:@"Could not secure %@: %@",
                                                   path,
                                                   permissionsError.localizedDescription];
    }
    return success;
}

static BOOL MDBManagedStateExists(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:MDBStatePath()];
}

static BOOL MDBSetManagedState(BOOL managed, NSString **failureReason) {
    NSString *path = MDBStatePath();
    if (!managed) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            return YES;
        }
        NSError *removeError = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:path error:&removeError]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"Could not clear managed state: %@",
                                                            removeError.localizedDescription];
            }
            return NO;
        }
        return YES;
    }

    NSDictionary *state = @{
        @"schemaVersion" : @1,
        @"managed" : @YES,
        @"updatedAt" : @((long long)NSDate.date.timeIntervalSince1970)
    };
    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (!json) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Could not encode managed state: %@",
                                                        jsonError.localizedDescription];
        }
        return NO;
    }

    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Could not create state directory: %@",
                                                        directoryError.localizedDescription];
        }
        return NO;
    }
    NSError *writeError = nil;
    if (![json writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Could not save managed state: %@",
                                                        writeError.localizedDescription];
        }
        return NO;
    }
    if (!MDBSetOwnerOnlyPermissions(path, failureReason)) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return NO;
    }
    return YES;
}

static void MDBLog(NSString *message) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    fprintf(stdout, "%s  %s\n",
            [formatter stringFromDate:[NSDate date]].UTF8String,
            message.UTF8String);
    fflush(stdout);
}

static NSString *MDBDisplayName(CGDirectDisplayID displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (screenNumber.unsignedIntValue == displayID) {
            return screen.localizedName;
        }
    }
    return @"Unknown display";
}

static BOOL MDBCopyOnlineDisplays(CGDirectDisplayID **displays,
                                  uint32_t *displayCount,
                                  NSString **failureReason) {
    uint32_t initialCount = 0;
    CGError result = CGGetOnlineDisplayList(0, NULL, &initialCount);
    if (result != kCGErrorSuccess) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"CGGetOnlineDisplayList failed: %d", result];
        }
        return NO;
    }

    uint32_t capacity = MAX(initialCount + 8, 16);
    CGDirectDisplayID *buffer = calloc(capacity, sizeof(CGDirectDisplayID));
    if (!buffer) {
        if (failureReason) {
            *failureReason = @"Could not allocate a display list.";
        }
        return NO;
    }

    uint32_t actualCount = 0;
    result = CGGetOnlineDisplayList(capacity, buffer, &actualCount);
    if (result != kCGErrorSuccess) {
        free(buffer);
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"CGGetOnlineDisplayList failed: %d", result];
        }
        return NO;
    }

    *displays = buffer;
    *displayCount = actualCount;
    return YES;
}

static BOOL MDBDisplayMatchesConfig(CGDirectDisplayID display, MDBConfig *config) {
    if (CGDisplayIsBuiltin(display)) {
        return NO;
    }
    if (CGDisplayVendorNumber(display) != config.vendorID ||
        CGDisplayModelNumber(display) != config.modelID) {
        return NO;
    }
    return config.serialNumber == 0 ||
           CGDisplaySerialNumber(display) == config.serialNumber;
}

static CGDirectDisplayID MDBMirrorSource(CGDirectDisplayID display) {
    CGDirectDisplayID source = CGDisplayMirrorsDisplay(display);
    return source == kCGNullDirectDisplay ? display : source;
}

static BOOL MDBDisplaysAreMirroredTogether(CGDirectDisplayID first,
                                           CGDirectDisplayID second) {
    return CGDisplayIsInMirrorSet(first) &&
           CGDisplayIsInMirrorSet(second) &&
           MDBMirrorSource(first) == MDBMirrorSource(second);
}

static BOOL MDBFindDisplayState(MDBConfig *config,
                                MDBDisplayState *state,
                                NSString **failureReason) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (!MDBCopyOnlineDisplays(&displays, &count, failureReason)) {
        return NO;
    }

    MDBDisplayState found = {0};
    uint32_t matchingTargets = 0;
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID display = displays[index];
        if (CGDisplayIsBuiltin(display)) {
            found.builtInDisplay = display;
        } else if (MDBDisplayMatchesConfig(display, config)) {
            matchingTargets++;
            if (!found.targetDisplay) {
                found.targetDisplay = display;
                found.targetOnline = YES;
                found.targetActive = CGDisplayIsActive(display);
            }
        }
    }
    free(displays);

    if (!found.builtInDisplay) {
        if (failureReason) {
            *failureReason = @"The built-in display is not online.";
        }
        return NO;
    }
    if (matchingTargets > 1) {
        if (failureReason) {
            *failureReason = @"More than one online display matches the target. Enable serial matching.";
        }
        return NO;
    }
    if (found.targetDisplay) {
        found.targetMirroredWithBuiltIn = MDBDisplaysAreMirroredTogether(
            found.builtInDisplay, found.targetDisplay);
    }
    *state = found;
    return YES;
}

static BOOL MDBFindBuiltInDisplay(CGDirectDisplayID *builtInDisplay,
                                  NSString **failureReason) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (!MDBCopyOnlineDisplays(&displays, &count, failureReason)) {
        return NO;
    }

    CGDirectDisplayID found = 0;
    for (uint32_t index = 0; index < count; index++) {
        if (CGDisplayIsBuiltin(displays[index])) {
            found = displays[index];
            break;
        }
    }
    free(displays);
    if (!found) {
        if (failureReason) {
            *failureReason = @"The built-in display is not online.";
        }
        return NO;
    }
    *builtInDisplay = found;
    return YES;
}

static BOOL MDBTargetIsReady(MDBDisplayState state, MDBConfig *config) {
    (void)config;
    return state.targetOnline &&
           state.targetActive &&
           state.targetMirroredWithBuiltIn;
}

static BOOL MDBLoadPrivateDisplayAPIs(NSString **failureReason) {
    if (gGetBrightness && gSetBrightness && NSClassFromString(@"DisplayServicesClient")) {
        return YES;
    }

    gCoreBrightnessHandle = dlopen(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        RTLD_NOW | RTLD_LOCAL);
    gDisplayServicesHandle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW | RTLD_LOCAL);
    if (gDisplayServicesHandle) {
        gGetBrightness = (MDBGetBrightnessFunction)dlsym(
            gDisplayServicesHandle, "DisplayServicesGetBrightness");
        gSetBrightness = (MDBSetBrightnessFunction)dlsym(
            gDisplayServicesHandle, "DisplayServicesSetBrightness");
    }

    Class clientClass = NSClassFromString(@"DisplayServicesClient");
    id probe = clientClass ? [[clientClass alloc] init] : nil;
    BOOL selectorsAvailable =
        [probe respondsToSelector:@selector(setProperty:withKey:andDisplay:)] &&
        [probe respondsToSelector:@selector(copyPropertyForKey:andDisplay:)];
    if (!gCoreBrightnessHandle || !gDisplayServicesHandle ||
        !gGetBrightness || !gSetBrightness || !clientClass || !selectorsAvailable) {
        if (failureReason) {
            *failureReason = @"Required private CoreBrightness/DisplayServices APIs are unavailable.";
        }
        return NO;
    }
    return YES;
}

static BOOL MDBReadAutoBrightness(CGDirectDisplayID display,
                                  BOOL *enabled,
                                  NSString **failureReason) {
    DisplayServicesClient *client =
        [[NSClassFromString(@"DisplayServicesClient") alloc] init];
    @try {
        id value = [client copyPropertyForKey:MDBAutoBrightnessKey andDisplay:display];
        if (![value respondsToSelector:@selector(boolValue)]) {
            if (failureReason) {
                *failureReason = @"The automatic-brightness property could not be read.";
            }
            return NO;
        }
        *enabled = [value boolValue];
        return YES;
    } @catch (NSException *exception) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Auto-brightness read raised %@.",
                                                       exception.name];
        }
        return NO;
    }
}

static BOOL MDBSetAutoBrightness(CGDirectDisplayID display,
                                 BOOL enabled,
                                 NSString **failureReason) {
    DisplayServicesClient *client =
        [[NSClassFromString(@"DisplayServicesClient") alloc] init];
    @try {
        BOOL changed = [client setProperty:@(enabled)
                                   withKey:MDBAutoBrightnessKey
                                andDisplay:display];
        BOOL current = NO;
        NSString *readFailure = nil;
        BOOL read = MDBReadAutoBrightness(display, &current, &readFailure);
        if (!changed || !read || current != enabled) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:
                    @"set=%@; read=%@; value=%@; detail=%@",
                    changed ? @"yes" : @"no",
                    read ? @"yes" : @"no",
                    current ? @"on" : @"off",
                    readFailure ?: @"none"];
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Auto-brightness write raised %@.",
                                                       exception.name];
        }
        return NO;
    }
}

static BOOL MDBReadBrightness(CGDirectDisplayID display,
                              float *brightness,
                              NSString **failureReason) {
    if (!gGetBrightness) {
        if (failureReason) {
            *failureReason = @"The brightness getter is unavailable.";
        }
        return NO;
    }
    int result = gGetBrightness(display, brightness);
    if (result != 0) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"Brightness read returned %d.", result];
        }
        return NO;
    }
    return YES;
}

static BOOL MDBSetBrightness(CGDirectDisplayID display,
                             float requested,
                             NSString **failureReason) {
    if (!gSetBrightness || !gGetBrightness) {
        if (failureReason) {
            *failureReason = @"Brightness functions are unavailable.";
        }
        return NO;
    }

    int setResult = gSetBrightness(display, requested);
    float actual = -1.0f;
    int getResult = gGetBrightness(display, &actual);
    BOOL verified = setResult == 0 && getResult == 0 &&
                    fabsf(actual - requested) <= 0.005f;
    if (!verified && failureReason) {
        *failureReason = [NSString stringWithFormat:
            @"set=%d; get=%d; requested=%.4f; actual=%.4f",
            setResult, getResult, requested, actual];
    }
    return verified;
}

static BOOL MDBApplyPolicy(MDBConfig *config,
                           BOOL dryRun,
                           BOOL *targetReadyOut) {
    MDBDisplayState state = {0};
    NSString *failureReason = nil;
    if (!MDBFindDisplayState(config, &state, &failureReason)) {
        if (MDBManagedStateExists()) {
            if (dryRun) {
                printf("target=unknown action=would-restore reason=discovery-failed\n");
                return YES;
            }
            MDBLog([NSString stringWithFormat:
                @"Policy discovery failed while managed; attempting fail-open restore: %@",
                failureReason]);
            return MDBRestoreBuiltInDisplay(config);
        }
        MDBLog([NSString stringWithFormat:@"Skipped: %@", failureReason]);
        return NO;
    }

    BOOL targetReady = MDBTargetIsReady(state, config);
    if (targetReadyOut) {
        *targetReadyOut = targetReady;
    }

    float requestedBrightness = targetReady ?
        config.dockedBrightness : config.undockedBrightness;
    BOOL requestedAutoBrightness = targetReady ?
        config.dockedAutoBrightness : config.undockedAutoBrightness;

    BOOL managed = MDBManagedStateExists();
    if (!targetReady && !managed) {
        if (dryRun) {
            printf("target=%s action=none reason=not-managed\n",
                   state.targetOnline ? "not-ready" : "absent");
        } else {
            MDBLog(@"Target absent/not ready and no managed state exists; settings left unchanged.");
        }
        return YES;
    }

    if (dryRun) {
        const char *targetDescription = "absent";
        if (targetReady) {
            targetDescription = "ready";
        } else if (state.targetOnline && !state.targetActive) {
            targetDescription = "inactive";
        } else if (state.targetOnline && !state.targetMirroredWithBuiltIn) {
            targetDescription = "not-mirrored";
        }
        printf("target=%s target_id=%u built_in_id=%u brightness=%.4f auto_brightness=%s\n",
               targetDescription,
               state.targetDisplay,
               state.builtInDisplay,
               requestedBrightness,
               requestedAutoBrightness ? "on" : "off");
        return YES;
    }

    BOOL brightnessSuccess = NO;
    BOOL autoSuccess = NO;
    if (targetReady) {
        if (!managed && !MDBSetManagedState(YES, &failureReason)) {
            MDBLog([NSString stringWithFormat:@"Refusing to dim without recovery state: %@",
                                               failureReason]);
            return NO;
        }
        autoSuccess = MDBSetAutoBrightness(
            state.builtInDisplay, requestedAutoBrightness, &failureReason);
        if (!autoSuccess) {
            MDBLog([NSString stringWithFormat:@"Failed to set automatic brightness: %@",
                                               failureReason]);
            NSString *rollbackBrightnessFailure = nil;
            NSString *rollbackAutoFailure = nil;
            BOOL rollbackBrightness = MDBSetBrightness(
                state.builtInDisplay,
                config.undockedBrightness,
                &rollbackBrightnessFailure);
            BOOL rollbackAuto = MDBSetAutoBrightness(
                state.builtInDisplay,
                config.undockedAutoBrightness,
                &rollbackAutoFailure);
            MDBLog([NSString stringWithFormat:
                @"Automatic-brightness write failed; fail-open rollback brightness=%@ auto=%@.",
                rollbackBrightness ? @"restored" : (rollbackBrightnessFailure ?: @"failed"),
                rollbackAuto ? @"restored" : (rollbackAutoFailure ?: @"failed")]);
            if (rollbackBrightness && rollbackAuto) {
                MDBSetManagedState(NO, NULL);
            }
            return NO;
        }
        failureReason = nil;
        brightnessSuccess = MDBSetBrightness(
            state.builtInDisplay, requestedBrightness, &failureReason);
        if (!brightnessSuccess) {
            NSString *rollbackBrightnessFailure = nil;
            NSString *rollbackAutoFailure = nil;
            BOOL rollbackBrightness = MDBSetBrightness(
                state.builtInDisplay,
                config.undockedBrightness,
                &rollbackBrightnessFailure);
            BOOL rollbackAuto = MDBSetAutoBrightness(
                state.builtInDisplay,
                config.undockedAutoBrightness,
                &rollbackAutoFailure);
            MDBLog([NSString stringWithFormat:
                @"Dark-state write failed; fail-open rollback brightness=%@ auto=%@.",
                rollbackBrightness ? @"restored" : (rollbackBrightnessFailure ?: @"failed"),
                rollbackAuto ? @"restored" : (rollbackAutoFailure ?: @"failed")]);
            if (rollbackBrightness && rollbackAuto) {
                MDBSetManagedState(NO, NULL);
            }
        }
    } else {
        brightnessSuccess = MDBSetBrightness(
            state.builtInDisplay, requestedBrightness, &failureReason);
        NSString *autoFailure = nil;
        autoSuccess = MDBSetAutoBrightness(
            state.builtInDisplay, requestedAutoBrightness, &autoFailure);
        if (!autoSuccess) {
            MDBLog([NSString stringWithFormat:@"Failed to restore automatic brightness: %@",
                                               autoFailure]);
        }
    }

    if (!brightnessSuccess) {
        MDBLog([NSString stringWithFormat:@"Failed to set brightness: %@",
                                           failureReason ?: @"unknown error"]);
    }
    if (!brightnessSuccess || !autoSuccess) {
        return NO;
    }
    if (!targetReady) {
        NSString *stateFailure = nil;
        if (!MDBSetManagedState(NO, &stateFailure)) {
            MDBLog(stateFailure);
            return NO;
        }
    }

    MDBLog([NSString stringWithFormat:
        @"Target %@: built-in display %u -> brightness %.0f%%, automatic brightness %@.",
        targetReady ? @"ready" : @"absent/inactive",
        state.builtInDisplay,
        requestedBrightness * 100.0f,
        requestedAutoBrightness ? @"on" : @"off"]);
    return YES;
}

static BOOL MDBRestoreBuiltInDisplay(MDBConfig *config) {
    CGDirectDisplayID builtInDisplay = 0;
    NSString *failureReason = nil;
    if (!MDBFindBuiltInDisplay(&builtInDisplay, &failureReason)) {
        MDBLog([NSString stringWithFormat:@"Restore failed: %@", failureReason]);
        return NO;
    }

    BOOL brightnessSuccess = MDBSetBrightness(
        builtInDisplay, config.undockedBrightness, &failureReason);
    if (!brightnessSuccess) {
        MDBLog([NSString stringWithFormat:@"Brightness restore failed: %@", failureReason]);
    }
    NSString *autoFailure = nil;
    BOOL autoSuccess = MDBSetAutoBrightness(
        builtInDisplay, config.undockedAutoBrightness, &autoFailure);
    if (!autoSuccess) {
        MDBLog([NSString stringWithFormat:@"Automatic-brightness restore failed: %@",
                                           autoFailure]);
    }
    if (brightnessSuccess && autoSuccess) {
        NSString *stateFailure = nil;
        if (!MDBSetManagedState(NO, &stateFailure)) {
            MDBLog(stateFailure);
            return NO;
        }
        MDBLog([NSString stringWithFormat:
            @"Restored built-in display %u -> brightness %.0f%%, automatic brightness %@.",
            builtInDisplay,
            config.undockedBrightness * 100.0f,
            config.undockedAutoBrightness ? @"on" : @"off"]);
    }
    return brightnessSuccess && autoSuccess;
}

static void MDBRecordApplyResult(BOOL success, BOOL targetReady) {
    if (success) {
        gLastAppliedTargetState = targetReady ? 1 : 0;
        gConsecutiveFailures = 0;
        gNextWatchdogRetry = 0;
        gNeedsRetry = NO;
        return;
    }

    gNeedsRetry = YES;
    gConsecutiveFailures++;
    NSUInteger exponent = MIN(gConsecutiveFailures, 6);
    NSTimeInterval delay = MIN(60.0, pow(2.0, (double)exponent));
    gNextWatchdogRetry = NSDate.date.timeIntervalSince1970 + delay;
    MDBLog([NSString stringWithFormat:@"Retry delayed for %.0f seconds after %lu failure(s).",
                                       delay,
                                       (unsigned long)gConsecutiveFailures]);
}

static void MDBApplyCurrentState(void) {
    BOOL targetReady = NO;
    BOOL success = MDBApplyPolicy(gConfig, NO, &targetReady);
    gLastObservedTargetState = targetReady ? 1 : 0;
    MDBRecordApplyResult(success, targetReady);
}

static void MDBScheduleApply(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gApplyPending = YES;
        uint64_t generation = ++gScheduleGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (generation == gScheduleGeneration) {
                MDBApplyCurrentState();
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (generation == gScheduleGeneration) {
                MDBApplyCurrentState();
                gApplyPending = NO;
            }
        });
    });
}

static void MDBScheduleExternalEventApply(void) {
    gConsecutiveFailures = 0;
    gNextWatchdogRetry = 0;
    gNeedsRetry = YES;
    MDBScheduleApply();
}

static void MDBCheckForConnectionChange(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    MDBDisplayState state = {0};
    if (!MDBFindDisplayState(gConfig, &state, NULL)) {
        BOOL firstFailure = !gDiscoveryFailureObserved;
        gDiscoveryFailureObserved = YES;
        if (MDBManagedStateExists() && !gApplyPending &&
            (firstFailure || (gNeedsRetry && now >= gNextWatchdogRetry))) {
            MDBLog(@"Watchdog found an ambiguous/unavailable target while managed; restoring.");
            MDBScheduleApply();
        }
        return;
    }
    gDiscoveryFailureObserved = NO;

    NSInteger currentState = MDBTargetIsReady(state, gConfig) ? 1 : 0;
    BOOL stateChanged = currentState != gLastObservedTargetState;
    if (stateChanged) {
        gLastObservedTargetState = currentState;
        gConsecutiveFailures = 0;
        gNextWatchdogRetry = 0;
        gNeedsRetry = YES;
    }
    if (gApplyPending) {
        return;
    }
    if (stateChanged) {
        MDBLog(@"Watchdog observed a target-display connection state change.");
        MDBScheduleApply();
        return;
    }
    if (now < gNextWatchdogRetry) {
        return;
    }
    if (gNeedsRetry || currentState != gLastAppliedTargetState) {
        MDBLog(@"Watchdog observed an unapplied target-display state.");
        MDBScheduleApply();
    }
}

static void MDBDisplayConfigurationChanged(CGDirectDisplayID display,
                                           CGDisplayChangeSummaryFlags flags,
                                           void *userInfo) {
    (void)userInfo;
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    MDBLog([NSString stringWithFormat:@"Display event: id=%u flags=0x%x.",
                                       display, flags]);
    MDBScheduleExternalEventApply();
}

static BOOL MDBPrintDisplays(void) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    NSString *failureReason = nil;
    if (!MDBCopyOnlineDisplays(&displays, &count, &failureReason)) {
        fprintf(stderr, "%s\n", failureReason.UTF8String);
        return NO;
    }

    printf("ID  TYPE      ACTIVE  MIRRORED  VENDOR       MODEL        SERIAL       NAME\n");
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID display = displays[index];
        printf("%-3u %-9s %-7s %-9s 0x%08x   0x%08x   0x%08x   %s\n",
               display,
               CGDisplayIsBuiltin(display) ? "built-in" : "external",
               CGDisplayIsActive(display) ? "yes" : "no",
               CGDisplayIsInMirrorSet(display) ? "yes" : "no",
               CGDisplayVendorNumber(display),
               CGDisplayModelNumber(display),
               CGDisplaySerialNumber(display),
               MDBDisplayName(display).UTF8String);
    }
    free(displays);
    return YES;
}

static NSString *MDBArgumentValue(NSArray<NSString *> *arguments, NSString *option) {
    NSUInteger index = [arguments indexOfObject:option];
    if (index == NSNotFound || index + 1 >= arguments.count) {
        return nil;
    }
    return arguments[index + 1];
}

static BOOL MDBArgumentsContain(NSArray<NSString *> *arguments, NSString *option) {
    return [arguments containsObject:option];
}

static BOOL MDBParseUnsigned(NSString *value, uint32_t *parsed) {
    if (!value.length) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:value];
    unsigned long long result = 0;
    BOOL success = [value hasPrefix:@"0x"] || [value hasPrefix:@"0X"] ?
        [scanner scanHexLongLong:&result] : [scanner scanUnsignedLongLong:&result];
    if (!success || !scanner.isAtEnd || result > UINT32_MAX) {
        return NO;
    }
    *parsed = (uint32_t)result;
    return YES;
}

static BOOL MDBParseDouble(NSString *value, double *parsed) {
    if (!value.length) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double result = 0;
    if (![scanner scanDouble:&result] || !scanner.isAtEnd || !isfinite(result)) {
        return NO;
    }
    *parsed = result;
    return YES;
}

static BOOL MDBWriteInitialConfig(NSArray<NSString *> *arguments) {
    NSString *path = MDBConfigPath();
    BOOL force = MDBArgumentsContain(arguments, @"--force");
    if (!force && [NSFileManager.defaultManager fileExistsAtPath:path]) {
        fprintf(stderr, "Configuration already exists at %s. Use --force to replace it.\n",
                path.UTF8String);
        return NO;
    }

    NSString *displayIDValue = MDBArgumentValue(arguments, @"--target-display-id");
    uint32_t requestedDisplayID = 0;
    if (!displayIDValue || !MDBParseUnsigned(displayIDValue, &requestedDisplayID)) {
        fprintf(stderr, "--target-display-id is required and must be a valid display ID.\n");
        return NO;
    }

    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    NSString *failureReason = nil;
    if (!MDBCopyOnlineDisplays(&displays, &count, &failureReason)) {
        fprintf(stderr, "%s\n", failureReason.UTF8String);
        return NO;
    }

    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    CGDirectDisplayID builtInDisplay = 0;
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID display = displays[index];
        if (CGDisplayIsBuiltin(display)) {
            builtInDisplay = display;
        } else if (CGDisplayIsActive(display) && display == requestedDisplayID) {
            [candidates addObject:@(display)];
        }
    }

    if (candidates.count != 1) {
        free(displays);
        fprintf(stderr,
                "Expected exactly one active external target, found %lu. "
                "Use --list-displays and --target-display-id ID.\n",
                (unsigned long)candidates.count);
        return NO;
    }

    CGDirectDisplayID target = candidates.firstObject.unsignedIntValue;
    if (!builtInDisplay || !MDBDisplaysAreMirroredTogether(builtInDisplay, target)) {
        free(displays);
        fprintf(stderr,
                "The selected display must be mirrored with the built-in display before installation.\n");
        return NO;
    }
    if (CGDisplayVendorNumber(target) == 0 || CGDisplayModelNumber(target) == 0) {
        free(displays);
        fprintf(stderr,
                "The selected display does not expose a stable vendor/model identity.\n");
        return NO;
    }
    free(displays);

    NSString *brightnessValue = MDBArgumentValue(arguments, @"--undocked-brightness");
    double undockedBrightness = 0.32;
    if (brightnessValue && !MDBParseDouble(brightnessValue, &undockedBrightness)) {
        fprintf(stderr, "Invalid --undocked-brightness value.\n");
        return NO;
    }
    if (undockedBrightness < 0.05 || undockedBrightness > 1.0) {
        fprintf(stderr, "--undocked-brightness must be between 0.05 and 1.\n");
        return NO;
    }

    NSString *watchdogValue = MDBArgumentValue(arguments, @"--watchdog-interval");
    double watchdogInterval = 2.0;
    if (watchdogValue && !MDBParseDouble(watchdogValue, &watchdogInterval)) {
        fprintf(stderr, "Invalid --watchdog-interval value.\n");
        return NO;
    }
    if (watchdogInterval < 1.0 || watchdogInterval > 60.0) {
        fprintf(stderr, "--watchdog-interval must be between 1 and 60 seconds.\n");
        return NO;
    }

    MDBConfig *config = [[MDBConfig alloc] init];
    config.vendorID = CGDisplayVendorNumber(target);
    config.modelID = CGDisplayModelNumber(target);
    config.serialNumber = MDBArgumentsContain(arguments, @"--match-serial") ?
        CGDisplaySerialNumber(target) : 0;
    config.dockedBrightness = 0.0f;
    config.undockedBrightness = (float)undockedBrightness;
    config.dockedAutoBrightness = NO;
    config.undockedAutoBrightness = YES;
    config.watchdogInterval = watchdogInterval;

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:config.dictionaryRepresentation
                                                   options:(NSJSONWritingPrettyPrinted |
                                                            NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!json) {
        fprintf(stderr, "Could not encode configuration: %s\n",
                jsonError.localizedDescription.UTF8String);
        return NO;
    }

    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        fprintf(stderr, "Could not create configuration directory: %s\n",
                directoryError.localizedDescription.UTF8String);
        return NO;
    }

    NSError *writeError = nil;
    if (![json writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        fprintf(stderr, "Could not write configuration: %s\n",
                writeError.localizedDescription.UTF8String);
        return NO;
    }
    NSString *permissionsFailure = nil;
    if (!MDBSetOwnerOnlyPermissions(path, &permissionsFailure)) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        fprintf(stderr, "%s\n", permissionsFailure.UTF8String);
        return NO;
    }

    printf("Created %s for display %u (%s), vendor=0x%08x, model=0x%08x%s.\n",
           path.UTF8String,
           target,
           MDBDisplayName(target).UTF8String,
           config.vendorID,
           config.modelID,
           config.serialNumber ? ", serial matching enabled" : "");
    return YES;
}

static BOOL MDBPrintStatus(MDBConfig *config) {
    MDBDisplayState state = {0};
    NSString *failureReason = nil;
    if (!MDBFindDisplayState(config, &state, &failureReason)) {
        fprintf(stderr, "%s\n", failureReason.UTF8String);
        return NO;
    }

    printf("config: %s\n", MDBConfigPath().UTF8String);
    printf("target: %s (online=%s, active=%s, id=%u)\n",
           MDBTargetIsReady(state, config) ? "ready" : "not ready",
           state.targetOnline ? "yes" : "no",
           state.targetActive ? "yes" : "no",
           state.targetDisplay);
    printf("mirrored with built-in: %s\n",
           state.targetMirroredWithBuiltIn ? "yes" : "no");
    printf("built-in: id=%u\n", state.builtInDisplay);
    printf("managed state: %s\n", MDBManagedStateExists() ? "yes" : "no");

    if (!MDBLoadPrivateDisplayAPIs(&failureReason)) {
        printf("brightness APIs: unavailable (%s)\n", failureReason.UTF8String);
        return NO;
    }

    float brightness = -1.0f;
    BOOL autoBrightness = NO;
    NSString *brightnessFailure = nil;
    NSString *autoFailure = nil;
    BOOL brightnessRead = MDBReadBrightness(
        state.builtInDisplay, &brightness, &brightnessFailure);
    BOOL autoRead = MDBReadAutoBrightness(
        state.builtInDisplay, &autoBrightness, &autoFailure);
    printf("brightness: %s", brightnessRead ? "" : "unavailable");
    if (brightnessRead) {
        printf("%.4f", brightness);
    }
    printf("\n");
    printf("automatic brightness: %s\n",
           autoRead ? (autoBrightness ? "on" : "off") : "unavailable");
    if (!brightnessRead && brightnessFailure) {
        fprintf(stderr, "%s\n", brightnessFailure.UTF8String);
    }
    if (!autoRead && autoFailure) {
        fprintf(stderr, "%s\n", autoFailure.UTF8String);
    }
    return brightnessRead && autoRead;
}

static MDBConfig *MDBLoadConfigOrPrintError(void) {
    NSString *failureReason = nil;
    MDBConfig *config = [MDBConfig configFromFile:MDBConfigPath() error:&failureReason];
    if (!config) {
        fprintf(stderr, "%s\n", failureReason.UTF8String);
    }
    return config;
}

static MDBConfig *MDBSafeRestoreFallbackConfig(void) {
    MDBConfig *fallback = [[MDBConfig alloc] init];
    fallback.undockedBrightness = 0.32f;
    fallback.undockedAutoBrightness = YES;
    return fallback;
}

static MDBConfig *MDBLoadRestoreConfig(void) {
    NSString *failureReason = nil;
    MDBConfig *config = [MDBConfig configFromFile:MDBConfigPath() error:&failureReason];
    if (config) {
        return config;
    }

    fprintf(stderr,
            "%s\nUsing the safe recovery fallback: brightness 0.32, automatic brightness on.\n",
            failureReason.UTF8String);
    return MDBSafeRestoreFallbackConfig();
}

static void MDBPrintHelp(void) {
    printf(
        "MacBook Dock Brightness %s\n\n"
        "Usage:\n"
        "  macbook-dock-brightness --daemon            Run the background monitor\n"
        "  macbook-dock-brightness --list-displays     List online displays\n"
        "  macbook-dock-brightness --init-config [options]\n"
        "  macbook-dock-brightness --status            Show current policy state\n"
        "  macbook-dock-brightness --dry-run           Print the next action\n"
        "  macbook-dock-brightness --restore           Restore the built-in display\n"
        "  macbook-dock-brightness --version\n\n"
        "Config options:\n"
        "  --target-display-id ID      Required: select one mirrored external display\n"
        "  --match-serial              Match its serial number as well\n"
        "  --undocked-brightness N     Restore level from 0.05 to 1 (default 0.32)\n"
        "  --watchdog-interval N       Safety check from 1 to 60 seconds (default 2)\n"
        "  --force                     Replace an existing configuration\n",
        MDBVersion.UTF8String);
}

static int MDBHandleDaemonStartupFailure(MDBConfig *config,
                                         NSString *reason,
                                         BOOL fullRestoreSupport) {
    MDBLog([NSString stringWithFormat:@"Disabled: %@", reason]);
    if (!MDBManagedStateExists()) {
        return 0;
    }
    MDBLog(fullRestoreSupport ?
        @"Managed recovery state exists; attempting a fail-open restore before exit." :
        @"Private API support is incomplete; attempting each available restore operation before exit.");
    if (MDBRestoreBuiltInDisplay(config)) {
        return 0;
    }
    MDBLog(@"Managed recovery state remains; use the brightness key or --restore after repairing compatibility.");
    return fullRestoreSupport ? 71 : 69;
}

static int MDBRunDaemon(MDBConfig *config) {
    NSString *failureReason = nil;
    if (!MDBLoadPrivateDisplayAPIs(&failureReason)) {
        return MDBHandleDaemonStartupFailure(config, failureReason, NO);
    }
    gConfig = config;

    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyProhibited];

    CGError callbackResult = CGDisplayRegisterReconfigurationCallback(
        MDBDisplayConfigurationChanged, NULL);
    if (callbackResult != kCGErrorSuccess) {
        return MDBHandleDaemonStartupFailure(
            config,
            [NSString stringWithFormat:@"display callback returned %d.", callbackResult],
            YES);
    }

    NSNotificationCenter *workspaceCenter =
        NSWorkspace.sharedWorkspace.notificationCenter;
    gWakeObserver = [workspaceCenter
        addObserverForName:NSWorkspaceDidWakeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        MDBLog(@"Workspace wake event.");
        MDBScheduleExternalEventApply();
    }];
    gScreensWakeObserver = [workspaceCenter
        addObserverForName:NSWorkspaceScreensDidWakeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        MDBScheduleExternalEventApply();
    }];
    gScreenParametersObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        MDBScheduleExternalEventApply();
    }];

    gConnectionWatchdog = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t interval = (uint64_t)(config.watchdogInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(
        gConnectionWatchdog,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
        interval,
        250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gConnectionWatchdog, ^{
        MDBCheckForConnectionChange();
    });
    dispatch_resume(gConnectionWatchdog);

    signal(SIGTERM, SIG_IGN);
    gTerminationSignal = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTerminationSignal, ^{
        BOOL restored = YES;
        if (MDBManagedStateExists()) {
            MDBLog(@"Termination requested; restoring the built-in display.");
            restored = MDBRestoreBuiltInDisplay(gConfig);
            if (!restored) {
                MDBLog(@"Restoration was incomplete; use the brightness key or --restore.");
            }
        } else {
            MDBLog(@"Termination requested; no managed display state to restore.");
        }
        exit(restored ? 0 : 71);
    });
    dispatch_resume(gTerminationSignal);

    signal(SIGINT, SIG_IGN);
    gInterruptSignal = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gInterruptSignal, ^{
        BOOL restored = YES;
        if (MDBManagedStateExists()) {
            MDBLog(@"Interrupt requested; restoring the built-in display.");
            restored = MDBRestoreBuiltInDisplay(gConfig);
            if (!restored) {
                MDBLog(@"Restoration was incomplete; use the brightness key or --restore.");
            }
        } else {
            MDBLog(@"Interrupt requested; no managed display state to restore.");
        }
        exit(restored ? 0 : 71);
    });
    dispatch_resume(gInterruptSignal);

    MDBApplyCurrentState();
    [application run];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (argc == 1) {
            MDBPrintHelp();
            return 0;
        }

        NSString *command = arguments[1];
        if ([command isEqualToString:@"--help"] ||
            [command isEqualToString:@"-h"]) {
            MDBPrintHelp();
            return 0;
        }
        if ([command isEqualToString:@"--version"]) {
            printf("%s\n", MDBVersion.UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"--list-displays"]) {
            return MDBPrintDisplays() ? 0 : 72;
        }
        if ([command isEqualToString:@"--init-config"]) {
            return MDBWriteInitialConfig(arguments) ? 0 : 65;
        }
        if ([command isEqualToString:@"--daemon"]) {
            MDBConfig *daemonConfig = MDBLoadConfigOrPrintError();
            if (daemonConfig) {
                return MDBRunDaemon(daemonConfig);
            }
            if (!MDBManagedStateExists()) {
                return 0;
            }
            MDBLog(@"Invalid configuration found with managed recovery state; using the safe restore fallback.");
            NSString *failureReason = nil;
            BOOL fullRestoreSupport = MDBLoadPrivateDisplayAPIs(&failureReason);
            if (!fullRestoreSupport) {
                MDBLog([NSString stringWithFormat:@"Full emergency restore support is unavailable: %@",
                                                   failureReason]);
            }
            if (MDBRestoreBuiltInDisplay(MDBSafeRestoreFallbackConfig())) {
                return 0;
            }
            return fullRestoreSupport ? 71 : 69;
        }
        if ([command isEqualToString:@"--restore"]) {
            MDBConfig *restoreConfig = MDBLoadRestoreConfig();
            NSString *failureReason = nil;
            BOOL fullRestoreSupport = MDBLoadPrivateDisplayAPIs(&failureReason);
            if (!fullRestoreSupport) {
                fprintf(stderr, "%s\nAttempting each available restore operation.\n",
                        failureReason.UTF8String);
            }
            if (MDBRestoreBuiltInDisplay(restoreConfig)) {
                return 0;
            }
            return fullRestoreSupport ? 71 : 69;
        }

        MDBConfig *config = MDBLoadConfigOrPrintError();
        if (!config) {
            return 66;
        }
        if ([command isEqualToString:@"--dry-run"]) {
            return MDBApplyPolicy(config, YES, NULL) ? 0 : 67;
        }
        if ([command isEqualToString:@"--validate-config"]) {
            printf("Configuration is valid: %s\n", MDBConfigPath().UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"--status"]) {
            return MDBPrintStatus(config) ? 0 : 68;
        }
        NSString *failureReason = nil;
        if (!MDBLoadPrivateDisplayAPIs(&failureReason)) {
            fprintf(stderr, "%s\n", failureReason.UTF8String);
            return 69;
        }
        fprintf(stderr, "Unknown command: %s\n", command.UTF8String);
        MDBPrintHelp();
        return 64;
    }
}
