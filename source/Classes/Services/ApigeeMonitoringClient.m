//
//  ApigeeMonitoringClient.m
//  ApigeeMonitoringClient
//
//  Copyright (c) 2012 Apigee. All rights reserved.
//

#import <asl.h>

#include <time.h>
#include <objc/runtime.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/sysctl.h>

#import "ApigeeCrashReporter.h"
#import "NSString+UUID.h"
#import "NSDate+Apigee.h"
#import "ApigeeSystemLogger.h"
#import "ApigeeReachability.h"
#import "ApigeeOpenUDID.h"

#import "ApigeeSystemLogger.h"
#import "ApigeeLogger.h"
#import "ApigeeIntervalTimer.h"

#import "ApigeeLogEntry.h"
#import "ApigeeSessionMetrics.h"
#import "ApigeeCompositeConfiguration.h"

#import "ApigeeLogEntry+JSON.h"
#import "ApigeeNetworkEntry+JSON.h"
#import "ApigeeCompositeConfiguration+JSON.h"

#import "ApigeeQueue+NetworkMetrics.h"
#import "ApigeeCachedConfigUtil.h"
#import "ApigeeLocationService.h"
#import "ApigeeLogCompiler.h"
#import "ApigeeSessionMetricsCompiler.h"
#import "ApigeeMonitoringClient.h"
#import "ApigeeMonitoringOptions.h"

#import "ApigeeURLConnection.h"
#import "ApigeeFunctions.h"

#import "ApigeeCustomConfigParam.h"

#import "ApigeeAppIdentification.h"
#import "ApigeeDataClient.h"
#import "ApigeeClient.h"
#import "ApigeeJsonUtils.h"

#import "ApigeeNSURLSessionSupport.h"
#import "ApigeeNSURLSessionDataTaskInfo.h"

static const int64_t kOneMillion = 1000 * 1000;
static mach_timebase_info_data_t s_timebase_info;


static ApigeeMonitoringClient *singletonInstance = nil;

static const BOOL kDefaultUploadCrashReports    = YES;
static const BOOL kDefaultInterceptNetworkCalls = YES;

static NSString* kApigeeMonitoringClientTag = @"MOBILE_AGENT";


static bool AmIBeingDebugged(void)
{
    int                 mib[4];
    struct kinfo_proc   info;
    
    info.kp_proc.p_flag = 0;
    
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PID;
    mib[3] = getpid();
    
    size_t size = sizeof(info);
    const int rc = sysctl(mib, sizeof(mib) / sizeof(*mib), &info, &size, NULL, 0);
    
    if ( rc == 0 ) {
        // We're being debugged if the P_TRACED flag is set.
        return ( (info.kp_proc.p_flag & P_TRACED) != 0 );
    } else {
        return false;
    }
}




@interface ApigeeMonitoringClient ()

@property (strong) NSString *appName;

@property (strong) ApigeeReachability *reachability;

@property (assign) aslclient client;

@property (strong) ApigeeIntervalTimer* timer;

@property (assign) BOOL swizzledNSURLConnection;
@property (assign) BOOL swizzledNSURLSession;
@property (assign) BOOL sentStartingSessionData;
@property (assign) BOOL isPartOfSample;
@property (assign) BOOL isInitialized;
@property (assign) BOOL isActive;

@property (strong) NSDate *startupTime;
@property (assign) uint64_t startupTimeMach;
@property (assign) uint64_t lastUploadTime;
@property (assign) uint64_t lastNetworkTransmissionTime;

@property (strong) NSMutableDictionary *dictCustomConfigKeysByCategory;
@property (strong) NSMutableDictionary *dictCustomConfigValuesByKey;
@property (strong) NSMutableDictionary *dictCustomConfigValuesByCategoryAndKey;

@property (strong) NSMutableArray *listListeners;

@property (strong) ApigeeAppIdentification *appIdentification;
@property (strong) ApigeeDataClient *dataClient;

@property (strong) NSMutableDictionary *dictRegisteredDataTasks;
@property (strong) NSRecursiveLock *lockDataTasks;

@property (assign) BOOL autoPromoteLoggedErrors;
@property (assign) BOOL crashReportingEnabled;
@property (assign) BOOL autoInterceptNetworkCalls;
@property (assign) BOOL interceptNSURLSessionCalls;
@property (assign) BOOL showDebuggingInfo;

- (void) retrieveAndApplyServerConfig;
- (BOOL) uploadEvents;
- (void) applyConfig;
- (BOOL) hasPendingCrashReports;
- (void) uploadCrashReports;
- (BOOL) enableCrashReporter:(NSError**) error;

@end

@implementation ApigeeMonitoringClient

@synthesize appName;

@synthesize reachability;

@synthesize client;
@synthesize timer;

@synthesize activeSettings;
@synthesize sentStartingSessionData;
@synthesize isInitialized;
@synthesize isActive;

@synthesize startupTime;
@synthesize startupTimeMach;
@synthesize lastUploadTime;
@synthesize lastNetworkTransmissionTime;

@synthesize appIdentification;
@synthesize dataClient;

@synthesize autoPromoteLoggedErrors;
@synthesize crashReportingEnabled;
@synthesize autoInterceptNetworkCalls;
@synthesize interceptNSURLSessionCalls;
@synthesize showDebuggingInfo;


// this method is sometimes handy for debugging
- (void)log:(NSString*)data toFile:(NSString*)fileName
{
#if TARGET_IPHONE_SIMULATOR
    NSString* fullFileName = [NSString stringWithFormat:@"/Users/ApigeeCorporation/%@", fileName];
    FILE* f = fopen([fullFileName UTF8String],"a+");
    if( f != NULL )
    {
        time_t lt = time(NULL);
        struct tm* ptr = localtime(&lt);
        
        NSString* appIdString = [NSString stringWithFormat:@"App: %d (%@/%@)",
                                 [self.activeSettings.instaOpsApplicationId intValue],
                                 self.activeSettings.orgName,
                                 self.activeSettings.appName];
        
        fprintf(f,"%s\n", [appIdString UTF8String]);
        fprintf(f,"Time: %s\n", asctime(ptr));
        
        fprintf(f,"%s\n", [data UTF8String]);
        fprintf(f,"=======================================================\n");
        fclose(f);
    }
#endif
}

+ (NSString*)sdkVersion
{
    return [ApigeeClient sdkVersion];
}


#pragma mark - Initialization and clean up

+ (id)sharedInstance
{
    // only returns non-nil pointer if it's been already created
    return singletonInstance;
}

- (void) dealloc
{
    singletonInstance = nil;
    NSNotificationCenter *notifyCenter = [NSNotificationCenter defaultCenter];
    
    [notifyCenter removeObserver:self
                         name:kReachabilityChangedNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationDidEnterBackgroundNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationDidReceiveMemoryWarningNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationSignificantTimeChangeNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationWillEnterForegroundNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationWillResignActiveNotification
                       object:nil];
    
    [notifyCenter removeObserver:self
                         name:UIApplicationWillTerminateNotification
                       object:nil];
}

- (id) initWithAppIdentification: (ApigeeAppIdentification*) theAppIdentification
                      dataClient: (ApigeeDataClient*) theDataClient
{
    return [self initWithAppIdentification:theAppIdentification
                                dataClient:theDataClient
                                   options:nil];
}

- (id) initWithAppIdentification:(ApigeeAppIdentification*)theAppIdentification
                      dataClient:(ApigeeDataClient*)theDataClient
                  crashReporting: (BOOL) crashReportingEnabled
           interceptNetworkCalls: (BOOL) autoInterceptCalls
                  uploadListener: (id<ApigeeUploadListener>)uploadListener
{
    ApigeeMonitoringOptions* options = [[ApigeeMonitoringOptions alloc] init];
    options.crashReportingEnabled = crashReportingEnabled;
    options.interceptNetworkCalls = autoInterceptCalls;
    options.uploadListener = uploadListener;
    
    return [self initWithAppIdentification:theAppIdentification
                                dataClient:theDataClient
                                   options:options];
}


- (id) initWithAppIdentification: (ApigeeAppIdentification*) theAppIdentification
                      dataClient: (ApigeeDataClient*) theDataClient
                  crashReporting: (BOOL) enabled
{
    ApigeeMonitoringOptions* options = [[ApigeeMonitoringOptions alloc] init];
    options.crashReportingEnabled = enabled;
    options.interceptNetworkCalls = kDefaultInterceptNetworkCalls;
    options.uploadListener = nil;

    return [self initWithAppIdentification:theAppIdentification
                                dataClient:theDataClient
                                   options:options];
}

- (id) initWithAppIdentification: (ApigeeAppIdentification*) theAppIdentification
                      dataClient: (ApigeeDataClient*) theDataClient
                  crashReporting: (BOOL) crashReportingEnabled
           interceptNetworkCalls: (BOOL) interceptCalls
{
    ApigeeMonitoringOptions* options = [[ApigeeMonitoringOptions alloc] init];
    options.crashReportingEnabled = crashReportingEnabled;
    options.interceptNetworkCalls = interceptCalls;
    options.uploadListener = nil;

    return [self initWithAppIdentification:theAppIdentification
                                dataClient:theDataClient
                                   options:options];
}

- (id) initWithAppIdentification: (ApigeeAppIdentification*) theAppIdentification
                      dataClient: (ApigeeDataClient*) theDataClient
                         options:(ApigeeMonitoringOptions*)monitoringOptions

{
    self = [super init];
    
    if (!self) {
        return nil;
    }
    
    self.crashReportingEnabled = YES;
    self.autoInterceptNetworkCalls = YES;
    self.showDebuggingInfo = NO;
    id<ApigeeUploadListener> uploadListener = nil;
    
    if( monitoringOptions ) {
        self.crashReportingEnabled = monitoringOptions.crashReportingEnabled;
        self.autoInterceptNetworkCalls = monitoringOptions.interceptNetworkCalls;
        uploadListener = monitoringOptions.uploadListener;
        self.autoPromoteLoggedErrors = monitoringOptions.autoPromoteLoggedErrors;
        self.interceptNSURLSessionCalls = monitoringOptions.interceptNSURLSessionCalls;
        self.showDebuggingInfo = monitoringOptions.showDebuggingInfo;
    } else {
        self.autoPromoteLoggedErrors = YES;
        self.interceptNSURLSessionCalls = NO;
    }
    
    self.appIdentification = theAppIdentification;
    self.dataClient = theDataClient;
    
    self.isActive = NO;
    self.isInitialized = NO;
    self.startupTimeMach = mach_absolute_time();
    self.startupTime = [NSDate date];
    
    // call to perform one-time initialization
    [self machTimeToDate:self.startupTimeMach];
    
    singletonInstance = self;
    
    self.lockDataTasks = [[NSRecursiveLock alloc] init];
    self.dictRegisteredDataTasks = [[NSMutableDictionary alloc] init];
    
    
    self.swizzledNSURLConnection = NO;
    self.swizzledNSURLSession = NO;
    self.sentStartingSessionData = NO;
    
    NSDate *startLogSearchDate = [self.startupTime dateByAddingTimeInterval:-2.0];

    [ApigeeLogCompiler refreshUploadTimestamp:startLogSearchDate];
    
    self.timer = nil;
    self.lastUploadTime = 0;
    self.lastNetworkTransmissionTime = 0;
    
    self.appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleNameKey];
    
    self.listListeners = [[NSMutableArray alloc] init];
    
    if( uploadListener != nil ) {
        [self.listListeners addObject:uploadListener];
    }
    
    self.dictCustomConfigKeysByCategory = [[NSMutableDictionary alloc] init];
    self.dictCustomConfigValuesByKey = [[NSMutableDictionary alloc] init];
    self.dictCustomConfigValuesByCategoryAndKey = [[NSMutableDictionary alloc] init];
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    self.reachability = [ApigeeReachability reachabilityForInternetConnection];
    [self.reachability startNotifier];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self retrieveAndApplyServerConfig];
    });
    
    return self;
}

- (void)printDebugMessage:(NSString*)debugMessage
{
    if (self.showDebuggingInfo) {
        NSLog(@"%@", debugMessage);
    }
}

- (void)recordNetworkEntry:(ApigeeNetworkEntry*)entry
{
    if (self.showDebuggingInfo) {
        [self printDebugMessage:@"recording network entry:"];
        [entry debugPrint];
    }
    
    [ApigeeQueue recordNetworkEntry:entry];
}

- (void) retrieveAndApplyServerConfig
{
    [self updateConfig];
    
#ifdef __arm64__
    if (self.crashReportingEnabled) {
        self.crashReportingEnabled = NO;
        ApigeeLogWarn(kApigeeMonitoringClientTag, @"Disabling crash reporting on arm64 (not supported yet)");
    }
#endif
    
    if (AmIBeingDebugged()) {
        self.crashReportingEnabled = NO;
        ApigeeLogWarn(kApigeeMonitoringClientTag, @"Disabling crash reporting under debugger");
    }
    
    if (self.crashReportingEnabled) {
        
        // look for other crash reporters that may be present
        NSString* otherCrashReporterClasses =
        @"PLCrashReporter|BITCrashManager|BugSenseCrashController|Crittercism|KSCrash|CrashController";
        NSArray* listOtherCrashReporterClasses = [otherCrashReporterClasses componentsSeparatedByString:@"|"];
        
        for( NSString* crashReporterClass in listOtherCrashReporterClasses )
        {
            Class clsCrashReporter = NSClassFromString(crashReporterClass);
            if (nil != clsCrashReporter) {
                ApigeeLogWarn(kApigeeMonitoringClientTag, @"Multiple crash reporters detected");
                break;
            }
        }
        
        NSError *error = nil;
        
        if (![self enableCrashReporter:&error] || (nil !=error)) {
            ApigeeLogAssert(kApigeeMonitoringClientTag, @"Failed to start the crash reporter: %@", error);
        } else if ([self hasPendingCrashReports]){
            [self uploadCrashReports];
        }
    } else {
        ApigeeLogInfo(kApigeeMonitoringClientTag, @"Crash reporting disabled");
    }
    
    ApigeeLogInfo(kApigeeMonitoringClientTag, @"INIT_AGENT");
    
    [self applyConfig];
    
    if (autoInterceptNetworkCalls) {
        [self enableInterceptedNetworkingCalls];
    }
    
    self.isInitialized = YES;
}

#pragma mark - Property implementations

- (NSString*) apigeeDeviceId
{
    return [ApigeeOpenUDID value];
}

#pragma mark - System configuration

- (void) applyConfig
{
    // are we disabled?
    if (!self.activeSettings.monitoringDisabled) {
        
        //coin flip for sample rate
        const uint32_t r = arc4random_uniform(100);
        
        if (r < self.activeSettings.samplingRate) {
            self.isPartOfSample = YES;
            self.isActive = YES;
            
            NSNotificationCenter *notifyCenter = [NSNotificationCenter defaultCenter];
            [notifyCenter addObserver:self
                             selector:@selector(networkChanged:)
                                 name:kReachabilityChangedNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationDidEnterBackground:)
                                 name:UIApplicationDidEnterBackgroundNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationDidReceiveMemoryWarning:)
                                 name:UIApplicationDidReceiveMemoryWarningNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationSignificantTimeChange:)
                                 name:UIApplicationSignificantTimeChangeNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationWillEnterForeground:)
                                 name:UIApplicationWillEnterForegroundNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationWillResignActive:)
                                 name:UIApplicationWillResignActiveNotification
                               object:nil];
            
            [notifyCenter addObserver:self
                             selector:@selector(applicationWillTerminate:)
                                 name:UIApplicationWillTerminateNotification
                               object:nil];
            
            [self reset];
            
            ApigeeLogInfo(kApigeeMonitoringClientTag, @"Configuration values applied");
            
        } else {
            self.isPartOfSample = NO;
            
            if (self.timer) {
                [self.timer cancel];
                self.timer = nil;
            }
            
            SystemDebug(@"IO_Diagnostics",@"Device not chosen for sample");
        }
    } else {
        SystemDebug(@"IO_Diagnostics",@"Monitoring disabled");
    }
}

- (NSString*)baseServerURL
{
    NSString* baseServerURL = nil;
    NSString* baseURL = appIdentification.baseURL;
    
    if( [baseURL hasSuffix:@"/"] ) {
        baseServerURL = [NSString stringWithFormat:@"%@%@/%@",
                         baseURL,
                         appIdentification.organizationId,
                         appIdentification.applicationId];
    } else {
        baseServerURL = [NSString stringWithFormat:@"%@/%@/%@",
                         baseURL,
                         appIdentification.organizationId,
                         appIdentification.applicationId];
    }
    
    return baseServerURL;
}

- (NSString*)configDownloadURL
{
    return [NSString stringWithFormat:@"%@/apm/apigeeMobileConfig",
            [self baseServerURL]];
}

- (NSString*)retrieveConfigFromServer
{
    if( [self isDeviceNetworkConnected] ) {
        NSURL* url = [NSURL URLWithString:[self configDownloadURL]];
        NSURLRequest* request = [NSURLRequest requestWithURL:url];
    
        NSURLResponse* response = [[NSURLResponse alloc] init];
        NSError* error = nil;
        
        if (self.showDebuggingInfo) {
            NSString* debugMsg = [NSString stringWithFormat:@"attempting to retrieve configuration from %@",
                                  [self configDownloadURL]];
            [self printDebugMessage:debugMsg];
        }
    
        NSData* responseData = [NSURLConnection sendSynchronousRequest:request
                                                     returningResponse:&response
                                                                 error:&error];
    
        if( nil != responseData ) {
            NSString* responseDataAsString = [[NSString alloc] initWithData:responseData
                                         encoding:NSUTF8StringEncoding];
            
            if (self.showDebuggingInfo) {
                [self printDebugMessage:@"configuration retrieved from server:"];
                [self printDebugMessage:responseDataAsString];
            }
            
            return responseDataAsString;
        } else {
            if( error != nil ) {
                NSString* errorMsg = [NSString stringWithFormat:@"Error retrieving config from server: %@",
                                      [error localizedDescription]];
                ApigeeLogError(kApigeeMonitoringClientTag,errorMsg);
            } else {
                ApigeeLogError(kApigeeMonitoringClientTag,
                               @"Unable to retrieve config from server");
            }
            return nil;
        }
    } else {
        ApigeeLogDebug(kApigeeMonitoringClientTag, @"Unable to retrieve config from server, device not connected to network");
        return nil;
    }
}

- (void) updateConfig
{
    NSString* jsonConfig = [self retrieveConfigFromServer];
    if( jsonConfig != nil ) {
        
        BOOL willUpdateCacheFromServer = YES;  // until we find out otherwise
        
        NSDictionary* configDict = [ApigeeJsonUtils decode:jsonConfig];
        if( configDict != nil ) {
            id lastModifedDate = [configDict valueForKey:@"lastModifiedDate"];
            if( lastModifedDate != nil ) {
                long long lastModifiedDateValue = 0;
            
                if( [lastModifedDate isKindOfClass:[NSString class]] ) {
                    NSString* lastModifiedDateAsString = (NSString*) lastModifedDate;
                    lastModifiedDateValue = [lastModifiedDateAsString longLongValue];
                } else if( [lastModifedDate isKindOfClass:[NSNumber class]] ) {
                    NSNumber* lastModifiedDateAsNumber = (NSNumber*) lastModifedDate;
                    lastModifiedDateValue = [lastModifiedDateAsNumber longLongValue];
                }
            
                if( lastModifiedDateValue > 0 ) {
                    NSDate* serverLastModifiedDate = [NSDate dateFromMilliseconds:lastModifiedDateValue];
                    
                    if( self.activeSettings && self.activeSettings.appLastModifiedDate ) {
                        if( ! [self.activeSettings.appLastModifiedDate isEqualToDate:serverLastModifiedDate] ) {
                            NSDate* laterConfigDate = [self.activeSettings.appLastModifiedDate laterDate:serverLastModifiedDate];
                            
                            // is configuration from server newer than what we currently have?
                            if( laterConfigDate == self.activeSettings.appLastModifiedDate  ) {
                                willUpdateCacheFromServer = NO;
                            }
                        } else {
                            // server config date and local config dates match -- no need to update
                            willUpdateCacheFromServer = NO;
                        }
                    }
                }
            }
        } else {
            SystemError(kApigeeMonitoringClientTag, @"parsing of config from server returned nil");
        }
        
        if( willUpdateCacheFromServer ) {
            [self saveConfig:jsonConfig];
        }
    } else {
        // request to read config from server failed
        SystemError(kApigeeMonitoringClientTag, @"Unable to read configuration from server");
    }
}

//note: this can be called by async background thread
- (void) reset
{
    @synchronized (self) {
        if (self.timer) {
            [self.timer cancel];
            self.timer = nil;
        }
        
#if !(TARGET_IPHONE_SIMULATOR)
        [[ApigeeLocationService defaultService] reset];
#endif
        
        NSError *error;
        ApigeeCompositeConfiguration* config = [ApigeeCachedConfigUtil getConfiguration:&error];
        
        if (!config) {
            SystemError(kApigeeMonitoringClientTag, @"Initializing configuration failed: %@", [error localizedDescription]);
            return;
        }
        
        
        //we always want these values to be set from what was passed during SDK initialization
        
        
        self.activeSettings = [[ApigeeActiveSettings alloc] initWithConfig:config];
        self.activeSettings.activeNetworkStatus = [self.reachability currentReachabilityStatus];
        
        // populate our internal dictionaries with custom config parameters
        [self.dictCustomConfigKeysByCategory removeAllObjects];
        [self.dictCustomConfigValuesByKey removeAllObjects];
        [self.dictCustomConfigValuesByCategoryAndKey removeAllObjects];
        
        NSArray *settings = self.activeSettings.customConfigParams;
        
        for (ApigeeCustomConfigParam *param in settings) {
            NSString *category = param.category;
            NSString *key = param.key;
            NSString *value = param.value;
            
            NSMutableArray *listKeysForCategory =
                [self.dictCustomConfigKeysByCategory valueForKey:category];
            
            if( nil == listKeysForCategory )
            {
                listKeysForCategory = [[NSMutableArray alloc] init];
                [self.dictCustomConfigKeysByCategory setValue:listKeysForCategory
                                                       forKey:category];
            }
            
            [listKeysForCategory addObject:key];
            
            [self.dictCustomConfigValuesByKey setValue:value forKey:key];
            
            NSString *combinedCategoryKey =
                [self dictionaryKeyForCategory:category
                                           key:key];
            [self.dictCustomConfigValuesByCategoryAndKey setValue:value
                                                          forKey:combinedCategoryKey];
        }

        if (self.activeSettings.monitoringDisabled) {
            return;
        }
        
#if !(TARGET_IPHONE_SIMULATOR)
        if (self.activeSettings.locationCaptureEnabled) {
            [[ApigeeLocationService defaultService] startScan];
        }
#endif
        
        // if we've never sent any data to server, do so now
        if (!self.sentStartingSessionData) {
            [self timerFired];
        } else {
            self.timer = [[ApigeeIntervalTimer alloc] init];
            [self.timer fireOnInterval:self.activeSettings.agentUploadIntervalInSeconds
                                target:self
                              selector:@selector(timerFired)
                               repeats:NO];
        }
    }
}

- (void)timerFired
{
    if (!self.isPartOfSample) {
        return;
    }
    
    self.timer = [[ApigeeIntervalTimer alloc] init];
    [self.timer fireOnInterval:self.activeSettings.agentUploadIntervalInSeconds
                        target:self
                      selector:@selector(timerFired)
                       repeats:NO];

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        if (self.showDebuggingInfo) {
            [self printDebugMessage:@"attempting to upload data to server"];
        }
        
        [self uploadEvents];
    });
}

- (NSData*)postString:(NSString*)postBody toUrl:(NSString*)urlAsString contentType:(NSString*)contentType
{
    NSURL* url = [NSURL URLWithString:urlAsString];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    
    [request setHTTPMethod:@"POST"];
    
    if( [contentType length] > 0 ) {
        [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    
    if (self.showDebuggingInfo) {
        NSString* debugMsg = [NSString stringWithFormat:@"attempting to POST to %@",
                              urlAsString];
        [self printDebugMessage:debugMsg];
        [self printDebugMessage:postBody];
    }
    
    NSData* postData = [postBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString* postLength = [NSString stringWithFormat:@"%d", [postData length]];
    
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    
    [request setHTTPBody:postData];
    
    NSURLResponse* response = nil;
    NSError* err = nil;
    
    NSData* responseData = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&err];
    
    if( err != nil ) {
        ApigeeLogError(kApigeeMonitoringClientTag, [NSString stringWithFormat:@"%@",[err localizedDescription]]);
    } else {
        if (self.showDebuggingInfo) {
            NSString* responseDataAsString =
                [[NSString alloc] initWithData:responseData
                                      encoding:NSUTF8StringEncoding];
            [self printDebugMessage:@"server response:"];
            [self printDebugMessage:responseDataAsString];
        }
    }
    
    return responseData;
}

- (NSData*)postString:(NSString*)postBody toUrl:(NSString*)urlAsString
{
    return [self postString:postBody toUrl:urlAsString contentType:@"application/json; charset=utf-8"];
}

- (NSData*)putString:(NSString*)postBody toUrl:(NSString*)urlAsString contentType:(NSString*)contentType
{
    NSURL* url = [NSURL URLWithString:urlAsString];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    
    [request setHTTPMethod:@"PUT"];
    
    if( [contentType length] > 0 ) {
        [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    
    if (self.showDebuggingInfo) {
        NSString* debugMsg = [NSString stringWithFormat:@"attempting to PUT to %@",
                              urlAsString];
        [self printDebugMessage:debugMsg];
        [self printDebugMessage:postBody];
    }
    
    NSData* postData = [postBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString* postLength = [NSString stringWithFormat:@"%d", [postData length]];
    
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    
    [request setHTTPBody:postData];
    
    NSURLResponse* response = nil;
    NSError* err = nil;
    
    NSData* responseData = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&err];
    
    if( err != nil ) {
        ApigeeLogError(kApigeeMonitoringClientTag, [NSString stringWithFormat:@"%@",[err localizedDescription]]);
    } else {
        if (self.showDebuggingInfo) {
            NSString* responseDataAsString =
                [[NSString alloc] initWithData:responseData
                                      encoding:NSUTF8StringEncoding];
            [self printDebugMessage:@"server response:"];
            [self printDebugMessage:responseDataAsString];
        }
    }
    
    return responseData;
}

- (NSData*)putString:(NSString*)postBody toUrl:(NSString*)urlAsString
{
    return [self putString:postBody toUrl:urlAsString contentType:@"application/json; charset=utf-8"];
}


#pragma mark - Crash reporter

- (BOOL) hasPendingCrashReports
{
    BOOL haveCrashReport = [[Apigee_PLCrashReporter sharedReporter] hasPendingCrashReport];
    
    if (self.showDebuggingInfo) {
        [self printDebugMessage:@"crash report found from prior session"];
    }
    
    return haveCrashReport;
}

- (NSString*)crashReportUploadURL:(NSString*)crashFileName
{
    return [NSString stringWithFormat:@"%@/apm/crashLogs/%@",
            [self baseServerURL],
            crashFileName];
}

- (void) uploadCrashReports
{
    if (![self hasPendingCrashReports]) {
        return;
    }
    
    Apigee_PLCrashReporter* crashReporter = [Apigee_PLCrashReporter sharedReporter];
    NSError* error = nil;
    NSData* data = [crashReporter loadPendingCrashReportDataAndReturnError:&error];
    Apigee_PLCrashReport *report = [[Apigee_PLCrashReport alloc] initWithData:data error:&error];
    
    if (error) {
        SystemError(@"CrashReporter", @"Error loading crash report: %@", [error localizedDescription]);
        return;
    }
    
    NSString *log = [Apigee_PLCrashReportTextFormatter stringValueForCrashReport:report
                                                                  withTextFormat:Apigee_PLCrashReportTextFormatiOS];
    
    NSString* uuid = [NSString uuid];
    NSString* fileName = [NSString stringWithFormat:@"%@.crash", uuid];
    
    if( [self.listListeners count] > 0 ) {
        for( id<ApigeeUploadListener> listener in self.listListeners ) {
            if( [listener respondsToSelector:@selector(onUploadCrashReport:)] ) {
                [listener onUploadCrashReport:log];
            }
        }
    }
    
    NSData* crashReportUploadResponseData = [self putString:log
                                                       toUrl:[self crashReportUploadURL:fileName]
                                                 contentType:@"text/plain"];
    if( nil != crashReportUploadResponseData ) {
        if ([self sendCrashNotification:fileName]) {
            [self printDebugMessage:@"crash report uploaded to server"];
            [crashReporter purgePendingCrashReport];
            [self printDebugMessage:@"crash report deleted from device"];
        } else {
            [self printDebugMessage:@"error: unable to upload crash report"];
        }
    } else {
        ApigeeLogAssert(@"Apigee Data Client",
                        @"There was an error with the request to upload the crash report");
    }
    
    [self uploadEvents];
}

- (BOOL) enableCrashReporter:(NSError**) error
{
    return [[Apigee_PLCrashReporter sharedReporter] enableCrashReporterAndReturnError:error];
}

#pragma mark - Internal implementations

- (void) networkChanged:(NSNotification *) notice
{
    if (self.showDebuggingInfo) {
        [self printDebugMessage:@"network status changed"];
    }
    
    self.activeSettings.activeNetworkStatus = [self.reachability currentReachabilityStatus];
}

- (void)populateClientMetricsEnvelope:(NSMutableDictionary*)clientMetricsEnvelope
{
    [clientMetricsEnvelope setObject:self.activeSettings.instaOpsApplicationId forKey:@"instaOpsApplicationId"];
    [clientMetricsEnvelope setObject:self.activeSettings.orgName forKey:@"orgName"];
    [clientMetricsEnvelope setObject:self.activeSettings.appName forKey:@"appName"];
    [clientMetricsEnvelope setObject:self.activeSettings.fullAppName forKey:@"fullAppName"];
    [clientMetricsEnvelope setObject:[NSDate unixTimestampAsString] forKey:@"timeStamp"];
}

- (NSString*)metricsUploadURL
{
    return [NSString stringWithFormat:@"%@/apm/apmMetrics",
            [self baseServerURL]];
}

- (BOOL) uploadEvents
{
    @autoreleasepool {
        
        ApigeeNetworkStatus netStatus = self.activeSettings.activeNetworkStatus;
        
        // do we have network connectivity?
        if (Apigee_NotReachable == netStatus) {
            ApigeeLogVerbose(kApigeeMonitoringClientTag, @"Cannot upload events -- no network connectivity");
            return NO;  // no connectivity, can't upload
        }

        // not on WiFi?
        if (netStatus != Apigee_ReachableViaWiFi) {
            // should we not upload when mobile (not on wifi)?
            if (!self.activeSettings.enableUploadWhenMobile) {
                ApigeeLogVerbose(kApigeeMonitoringClientTag, @"Cannot upload events -- upload when on mobile network disallowed");
                return NO;
            }
        }
        
        NSArray *logEntries = [[ApigeeLogCompiler systemCompiler] compileLogsForSettings:self.activeSettings
                               autoPromoteErrors:self.autoPromoteLoggedErrors];
        
        NSArray *networkMetrics = [[ApigeeQueue networkMetricsQueue] dequeueAll];

        if (([logEntries count] == 0) &&
            ([networkMetrics count] == 0) &&
            self.sentStartingSessionData)
        {
            // no log entries, no network metrics, and we've already sent the
            // initial session data
            ApigeeLogVerbose(kApigeeMonitoringClientTag, @"Not uploading events -- nothing to send");
            return NO;
        }
        
        ApigeeSessionMetrics *sessionMetrics =
            [[ApigeeSessionMetricsCompiler systemCompiler] compileMetricsForSettings:self.activeSettings];
    
        NSMutableDictionary *clientMetricsEnvelope = [NSMutableDictionary dictionary];
        [self populateClientMetricsEnvelope:clientMetricsEnvelope];
        [clientMetricsEnvelope setObject:[ApigeeLogEntry toDictionaries:logEntries] forKey:@"logs"];
        [clientMetricsEnvelope setObject:[ApigeeNetworkEntry toDictionaries:networkMetrics] forKey:@"metrics"];
        [clientMetricsEnvelope setObject:[sessionMetrics asDictionary] forKey:@"sessionMetrics"];
    
        NSError* error = nil;
        NSString *json = [ApigeeJsonUtils encode:clientMetricsEnvelope error:&error];
        
        if( json != nil ) {
            BOOL reachedServerSuccessfully = NO;
            
            NSData* responseData = [self postString:json
                                              toUrl:[self metricsUploadURL]];
        
            if( (nil != responseData) && ([responseData length] > 0) ) {
                
                NSString *responseDataAsString =
                    [[NSString alloc] initWithData:responseData
                                          encoding:NSUTF8StringEncoding];
                NSDictionary *jsonResponse =
                    [ApigeeJsonUtils decode:responseDataAsString];
                
                NSString* serverResponseMessage =
                    [jsonResponse valueForKey:@"message"];
                NSString* lowerResponseMessage = [serverResponseMessage lowercaseString];
                if ([lowerResponseMessage hasPrefix:@"successfully sent"]) {
                    reachedServerSuccessfully = YES;
                    
                    ApigeeLogVerbose(kApigeeMonitoringClientTag,responseDataAsString);
                    
                    if (!self.sentStartingSessionData) {
                        self.sentStartingSessionData = YES;
                    }

                    // let our listeners know
                    if( self.listListeners && ([self.listListeners count] > 0) ) {
                        for( id<ApigeeUploadListener> listener in self.listListeners ) {
                            [listener onUploadMetrics:json];
                        }
                    }

                } else {
                    NSString* errorMessage = [NSString stringWithFormat:@"error: %@",
                                              responseDataAsString];
                    ApigeeLogVerbose(kApigeeMonitoringClientTag,errorMessage);
                }
            
                self.lastUploadTime = mach_absolute_time();
            
                //[ApigeeLogCompiler refreshUploadTimestamp];
            
                return reachedServerSuccessfully;
            } else {
                NSLog(@"error: unable to send data to server");
                return NO;
            }
        } else {
            NSLog( @"error: unable to encode metrics to json, not sending to server. %@", clientMetricsEnvelope );
            if( error != nil ) {
                NSLog( @"error: %@", [error localizedDescription]);
            } else {
                NSLog( @"no error given");
            }
            return NO;
        }
    }
}

- (BOOL) sendCrashNotification:(NSString *) fileName
{
    NSString* nowTimestamp = [NSDate unixTimestampAsString];
    
    ApigeeLogEntry *logEntry = [[ApigeeLogEntry alloc] init];
    logEntry.timeStamp = nowTimestamp;
    logEntry.tag = @"CRASH";
    logEntry.logMessage = fileName;
    logEntry.logLevel = @"A"; // assert
    
    ApigeeSessionMetrics *sessionMetrics = [[ApigeeSessionMetricsCompiler systemCompiler] compileMetricsForSettings:self.activeSettings];
    NSArray *logEntries = [NSArray arrayWithObject:logEntry];

    NSMutableDictionary *clientMetricsEnvelope = [NSMutableDictionary dictionary];
    [self populateClientMetricsEnvelope:clientMetricsEnvelope];
    [clientMetricsEnvelope setObject:[ApigeeLogEntry toDictionaries:logEntries] forKey:@"logs"];
    [clientMetricsEnvelope setObject:[sessionMetrics asDictionary] forKey:@"sessionMetrics"];

    NSError* error = nil;
    NSString *json = [ApigeeJsonUtils encode:clientMetricsEnvelope error:&error];
    
    if (json != nil) {
        if( nil != [self postString:json
                              toUrl:[self metricsUploadURL]] ) {
            self.lastUploadTime = mach_absolute_time();
            SystemAssert(@"Crash Log", @"Crash notification sent for %@", fileName);
            return YES;
        }
    } else {
        NSLog( @"error: unable to encode crash notification to JSON. %@", clientMetricsEnvelope );
        if (error != nil) {
            NSLog( @"error: encoding crash report payload: %@", [error localizedDescription]);
        } else {
            NSLog( @"no error given");
        }
    }
    
    return NO;
}

- (void) saveConfig:(NSString *) json
{
    if ([json length] == 0) {
        SystemError(kApigeeMonitoringClientTag, @"We have no json to deserialize.");
        return;
    }
    
    NSError *error = nil;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    [ApigeeCachedConfigUtil updateConfiguration:data error:&error];
    [self reset];
    
    if (error) {
        SystemError(kApigeeMonitoringClientTag, @"Error updating cached config file: %@", [error localizedDescription]);
        return;
    }
}

- (BOOL) swizzleClass:(Class) targetClass
          classMethod:(SEL) originalSelector
replacementClassMethod:(SEL) replacementSelector
{
    Method origMethod = class_getClassMethod(targetClass, originalSelector);
    Method newMethod = class_getClassMethod(targetClass, replacementSelector);
    
    if( origMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(originalSelector),
              NSStringFromClass(targetClass));
        return NO;
    }
    
    if( newMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(replacementSelector),
              NSStringFromClass(targetClass));
        return NO;
    }
    
    method_exchangeImplementations(origMethod, newMethod);
    
    return YES;
}

- (BOOL) swizzleClass:(Class) targetClass
       instanceMethod:(SEL) originalSelector
replacementInstanceMethod:(SEL) replacementSelector
{
    Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
    Method replacementMethod = class_getInstanceMethod(targetClass, replacementSelector);
    
    /*
     If the method we're swizzling is actually defined in a superclass, we have
     to use class_addMethod to add an implementation to the target class, which
     we do using our replacement implementation. Then we can use
     class_replaceMethod to replace with the superclass's implementation, so
     our new version will be able to correctly call the old.
     
     If the method is defined in the target class, class_addMethod will fail
     but then we can use method_exchangeImplementations to just swap the new
     and old versions.
     */

    if( originalMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(originalSelector),
              NSStringFromClass(targetClass));
        return NO;
    }
    
    if( replacementMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(replacementSelector),
              NSStringFromClass(targetClass));
        return NO;
    }

    if (class_addMethod(targetClass,
                        originalSelector,
                        method_getImplementation(replacementMethod),
                        method_getTypeEncoding(replacementMethod))) {
        class_replaceMethod(targetClass,
                            replacementSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }

    return YES;
}

- (BOOL) swizzleClass:(Class) targetClass
       instanceMethod:(SEL) originalSelector
     replacementClass:(Class) replacementClass
replacementInstanceMethod:(SEL) replacementSelector
{
    Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
    Method replacementMethod = class_getInstanceMethod(replacementClass, replacementSelector);
    
    /*
     If the method we're swizzling is actually defined in a superclass, we have
     to use class_addMethod to add an implementation to the target class, which
     we do using our replacement implementation. Then we can use
     class_replaceMethod to replace with the superclass's implementation, so
     our new version will be able to correctly call the old.
     
     If the method is defined in the target class, class_addMethod will fail
     but then we can use method_exchangeImplementations to just swap the new
     and old versions.
     */
    
    if( originalMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(originalSelector),
              NSStringFromClass(targetClass));
        return NO;
    }
    
    if( replacementMethod == NULL ) {
        NSLog( @"error: can't find method %@ in class %@",
              NSStringFromSelector(replacementSelector),
              NSStringFromClass(replacementClass));
        return NO;
    }
    
     if (class_addMethod(targetClass,
                         originalSelector,
                         method_getImplementation(replacementMethod),
                         method_getTypeEncoding(replacementMethod))) {
         class_replaceMethod(targetClass,
                             replacementSelector,
                             method_getImplementation(originalMethod),
                             method_getTypeEncoding(originalMethod));
     } else {
         method_exchangeImplementations(originalMethod, replacementMethod);
    }
    
    return YES;
}

- (void) enableInterceptedNetworkingCalls
{
    if (!self.activeSettings.monitoringDisabled && !self.swizzledNSURLConnection) {

        Class clsNSURLConnection = [NSURLConnection class];
        
        if (self.showDebuggingInfo) {
            [self printDebugMessage:@"swizzling NSURLConnection methods"];
        }
    
        [self swizzleClass:clsNSURLConnection
               classMethod:@selector(sendSynchronousRequest:returningResponse:error:)
    replacementClassMethod:@selector(swzSendSynchronousRequest:returningResponse:error:)];

        [self swizzleClass:clsNSURLConnection
               classMethod:@selector(connectionWithRequest:delegate:)
    replacementClassMethod:@selector(swzConnectionWithRequest:delegate:)];

        [self swizzleClass:clsNSURLConnection
            instanceMethod:@selector(initWithRequest:delegate:startImmediately:)
 replacementInstanceMethod:@selector(initSwzWithRequest:delegate:startImmediately:)];
    
        [self swizzleClass:clsNSURLConnection
            instanceMethod:@selector(initWithRequest:delegate:)
 replacementInstanceMethod:@selector(initSwzWithRequest:delegate:)];
        
        [self swizzleClass:clsNSURLConnection
            instanceMethod:@selector(start)
 replacementInstanceMethod:@selector(swzStart)];
    
        self.swizzledNSURLConnection = YES;
        
        if (self.interceptNSURLSessionCalls) {
        
            // swizzle NSURLSession if we're on iOS 7.0 or later
            Class clsNSURLSession = NSClassFromString(@"NSURLSession");
        
            if( clsNSURLSession != nil )  // iOS 7.0 or later?
            {
                if (self.showDebuggingInfo) {
                    [self printDebugMessage:@"swizzling NSURLSession methods"];
                }
                
                self.swizzledNSURLSession =
                    [ApigeeNSURLSessionSupport setupAtStartup];
            }
        }
    }
}

- (BOOL) isNSURLConnectionIntercepted
{
    return self.swizzledNSURLConnection;
}

- (NSDate*)timeStartup
{
    if (self.isInitialized) {
        return self.startupTime;
    } else {
        return nil;
    }
}

- (uint64_t)timeStartupMach
{
    if (self.isInitialized) {
        return self.startupTimeMach;
    } else {
        return 0;
    }
}

- (uint64_t)timeLastUpload
{
    if (self.isInitialized) {
        return self.lastUploadTime;
    } else {
        return 0;
    }
}

- (uint64_t)timeLastNetworkTransmission
{
    if (self.isInitialized) {
        return self.lastNetworkTransmissionTime;
    } else {
        return 0;
    }
}

- (NSDate*)machTimeToDate:(uint64_t)mach_time
{
    if (self.isInitialized) {
        const uint64_t startupMachTime = self.timeStartupMach;
        const uint64_t elapsedMachTime = mach_time - startupMachTime;
        
        if (s_timebase_info.denom == 0) {
            (void) mach_timebase_info(&s_timebase_info);
        }
        
        // mach_absolute_time() returns billionth of seconds,
        // so divide by one million to get milliseconds
        const double elapsedMillis = (elapsedMachTime * s_timebase_info.numer) /
                                        (kOneMillion * s_timebase_info.denom);
        
        const NSTimeInterval timeInterval = elapsedMillis / 1000;
        
        return [self.timeStartup dateByAddingTimeInterval:timeInterval];
    } else {
        return nil;
    }
}

- (uint64_t)dateToMachTime:(NSDate*)date
{
    if (self.isInitialized) {
        // calculate elapsed time (in seconds) from date argument from our startup time
        NSTimeInterval intervalElapsedSeconds = [date timeIntervalSinceDate:self.timeStartup];
        const double elapsedMillis = intervalElapsedSeconds * 1000;
        const uint64_t elapsedMachTime = (elapsedMillis *
                                          (kOneMillion * s_timebase_info.denom)) /
                                            s_timebase_info.numer;
        return self.timeStartupMach + elapsedMachTime;
    } else {
        return 0;
    }
}

- (BOOL)isParticipatingInSample
{
    if (self.isInitialized) {
        return self.isPartOfSample;
    } else {
        return NO;  // at least not yet
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    // turn off our timer if we have one
    if (self.timer) {
        [self.timer cancel];
        self.timer = nil;
    }
}

- (void)applicationDidReceiveMemoryWarning:(NSNotification *)notification
{
    if (self.isInitialized) {
        ApigeeLogDebug(kApigeeMonitoringClientTag, @"app received memory warning");
    
        // throw away any performance metrics that we have to reduce the
        // memory footprint
        [[ApigeeQueue networkMetricsQueue] removeAllObjects];
    }
}

- (void)applicationSignificantTimeChange:(NSNotification *)notification
{
    //TODO: is there anything we need to do on this notification??
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    if (self.isInitialized) {
        // is monitoring not disabled?
        if (!self.activeSettings.monitoringDisabled) {
            // re-establish our timer
            self.timer = [[ApigeeIntervalTimer alloc] init];
            [self.timer fireOnInterval:self.activeSettings.agentUploadIntervalInSeconds
                                target:self
                              selector:@selector(timerFired)
                               repeats:NO];
        }
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    // turn off our timer if we have one
    if (self.timer) {
        [self.timer cancel];
        self.timer = nil;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    // turn off our timer if we have one
    if (self.timer) {
        [self.timer cancel];
        self.timer = nil;
    }
}

- (BOOL)isDeviceNetworkConnected
{
    if (self.activeSettings) {
        return (Apigee_NotReachable != self.activeSettings.activeNetworkStatus);
    } else {
        return (Apigee_NotReachable != [self.reachability currentReachabilityStatus]);
    }
    
    return NO;
}

- (NSString*)dictionaryKeyForCategory:(NSString*)categoryName key:(NSString*)keyName
{
    return [NSString stringWithFormat:@"%@:%@", categoryName, keyName];
}

- (NSArray*)customConfigPropertyKeysForCategory:(NSString*)category
{
    if (self.isInitialized) {
        return [self.dictCustomConfigKeysByCategory valueForKey:category];
    } else {
        return nil;
    }
}

- (NSString*)customConfigPropertyValueForKey:(NSString*)key
{
    if (self.isInitialized) {
        return [self.dictCustomConfigValuesByKey valueForKey:key];
    } else {
        return nil;
    }
}

- (NSString*)customConfigPropertyValueForKey:(NSString *)key
                                 forCategory:(NSString*)categoryName
{
    if (self.isInitialized) {
        NSString *dictKey = [self dictionaryKeyForCategory:categoryName key:key];
        return [self.dictCustomConfigValuesByCategoryAndKey valueForKey:dictKey];
    } else {
        return nil;
    }
}

- (BOOL)uploadMetrics
{
    BOOL metricsUploaded = NO;
    
    if(self.isInitialized && self.isActive)
    {
        // are we currently connected to network?
        if( [self isDeviceNetworkConnected] ) {
            ApigeeLogInfo(kApigeeMonitoringClientTag, @"Manually uploading metrics now");
            metricsUploaded = [self uploadEvents];
        } else {
            ApigeeLogInfo(kApigeeMonitoringClientTag, @"uploadMetrics called, device not connected to network");
        }
    } else {
        ApigeeLogInfo(kApigeeMonitoringClientTag, @"Configuration was not able to initialize. Not uploading metrics.");
    }
    
    return metricsUploaded;
}

- (void)asyncUploadMetrics:(void (^)(BOOL))completionHandler
{
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    dispatch_async(queue,^{
        BOOL uploadSucceeded = [self uploadMetrics];
        
        if( completionHandler ) {
            dispatch_async(dispatch_get_main_queue(),^{
                completionHandler(uploadSucceeded);
            });
        }
    });
}

- (BOOL)refreshConfiguration
{
    BOOL configurationUpdated = NO;
    
    if(self.isInitialized && self.isActive)
    {
        // are we currently connected to network?
        if( [self isDeviceNetworkConnected] ) {
            ApigeeLogInfo(kApigeeMonitoringClientTag, @"Manually refreshing configuration now");
            [self updateConfig];
            [self applyConfig];
            configurationUpdated = YES;
        } else {
            ApigeeLogInfo(kApigeeMonitoringClientTag, @"refreshConfiguration called, device not connected to network");
        }
    } else {
        ApigeeLogInfo(kApigeeMonitoringClientTag, @"Configuration was not able to initialize. Unable to refresh.");
    }
    
    return configurationUpdated;
}

- (void)asyncRefreshConfiguration:(void (^)(BOOL))completionHandler
{
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    dispatch_async(queue,^{
        BOOL refreshSucceeded = [self refreshConfiguration];
        
        if( completionHandler ) {
            dispatch_async(dispatch_get_main_queue(),^{
                completionHandler(refreshSucceeded);
            });
        }
    });
}

- (BOOL)recordNetworkSuccessForUrl:(NSString*)url
                         startTime:(NSDate*)startTime
                           endTime:(NSDate*)endTime
{
    BOOL metricsRecorded = NO;
    
    if(self.isInitialized && self.isActive)
    {
        ApigeeNetworkEntry *entry = [[ApigeeNetworkEntry alloc] init];
        [entry populateWithURLString:url];
        [entry populateStartTime:startTime ended:endTime];
    
        [self recordNetworkEntry:entry];
        
        metricsRecorded = YES;
    } else {
        ApigeeLogWarn(kApigeeMonitoringClientTag, @"Unable to record network metrics. Agent not initialized or active");
    }
    
    return metricsRecorded;
}

- (BOOL)recordNetworkFailureForUrl:(NSString*)url
                         startTime:(NSDate*)startTime
                           endTime:(NSDate*)endTime
                             error:(NSString*)errorDescription
{
    BOOL metricsRecorded = NO;
    
    if(self.isInitialized && self.isActive)
    {
        ApigeeNetworkEntry *entry = [[ApigeeNetworkEntry alloc] init];
        [entry populateWithURLString:url];
        [entry populateStartTime:startTime ended:endTime];
    
        // error occurred
        entry.numErrors = @"1";
        entry.transactionDetails = errorDescription;
    
        [self recordNetworkEntry:entry];
        
        metricsRecorded = YES;
    } else {
        ApigeeLogWarn(kApigeeMonitoringClientTag, @"Unable to record network metrics. Agent not initialized or active");
    }
    
    return metricsRecorded;
}

- (NSString*)baseURLPath
{
    return [NSString stringWithFormat:@"%@/apm/",
            [self baseServerURL]];
}

- (BOOL)addUploadListener:(id<ApigeeUploadListener>)uploadListener
{
    BOOL listenerAdded = NO;
    
    if (self.isInitialized) {
        if (uploadListener != nil) {
            if (!self.listListeners) {
                self.listListeners = [[NSMutableArray alloc] init];
            }
        
            [self.listListeners addObject:uploadListener];
            listenerAdded = YES;
            
            if (self.showDebuggingInfo) {
                [self printDebugMessage:@"added upload listener"];
            }
        } else {
            [self printDebugMessage:@"not adding upload listener (listener is nil)"];
        }
    } else {
        [self printDebugMessage:@"not adding upload listener (monitoring client not initialized successfully)"];
    }
    
    return listenerAdded;
}

- (BOOL)removeUploadListener:(id<ApigeeUploadListener>)uploadListener
{
    BOOL listenerRemoved = NO;
    
    if (self.isInitialized) {
        if( self.listListeners ) {
            if( [self.listListeners containsObject:uploadListener] ) {
                [self.listListeners removeObject:uploadListener];
                listenerRemoved = YES;
            } else {
                [self printDebugMessage:@"not removing upload listener (not found)"];
            }
        } else {
            [self printDebugMessage:@"not removing upload listener (none registered)"];
        }
    } else {
        [self printDebugMessage:@"not removing upload listener (monitoring client not initialized successfully)"];
    }
    
    return listenerRemoved;
}

#pragma mark Support for NSURLSession

- (id)generateIdentifierForDataTask
{
    NSDate* identifier = nil;
    
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        identifier = [NSDate date];
        [self.lockDataTasks unlock];
    }
    
    return identifier;
}

- (void)registerDataTaskInfo:(ApigeeNSURLSessionDataTaskInfo*)dataTaskInfo
              withIdentifier:(id)identifier
{
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        [self.dictRegisteredDataTasks setObject:dataTaskInfo
                                         forKey:identifier];
        [self.lockDataTasks unlock];
    }
}

- (ApigeeNSURLSessionDataTaskInfo*)dataTaskInfoForIdentifier:(id)identifier
{
    ApigeeNSURLSessionDataTaskInfo* sessionDataTaskInfo = nil;
    
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        sessionDataTaskInfo = [self.dictRegisteredDataTasks objectForKey:identifier];
        [self.lockDataTasks unlock];
    }
        
    return sessionDataTaskInfo;
}

- (ApigeeNSURLSessionDataTaskInfo*)dataTaskInfoForTask:(NSURLSessionTask*)task
{
    ApigeeNSURLSessionDataTaskInfo* sessionDataTaskInfo = nil;
 
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        NSArray* listAllValues = [self.dictRegisteredDataTasks allValues];
        for( ApigeeNSURLSessionDataTaskInfo* taskInfo in listAllValues )
        {
            if( taskInfo.sessionDataTask == task )
            {
                sessionDataTaskInfo = taskInfo;
                break;
            }
        }
        [self.lockDataTasks unlock];
    }
    
    return sessionDataTaskInfo;
}

- (void)removeDataTaskInfoForIdentifier:(id)identifier
{
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        [self.dictRegisteredDataTasks removeObjectForKey:identifier];
        [self.lockDataTasks unlock];
    }
}

- (void)removeDataTaskInfoForTask:(NSURLSessionTask*)task
{
    if (self.isInitialized) {
        [self.lockDataTasks lock];
        NSArray* listAllValues = [self.dictRegisteredDataTasks allValues];
        for( ApigeeNSURLSessionDataTaskInfo* taskInfo in listAllValues )
        {
            if( taskInfo.sessionDataTask == task )
            {
                [self.dictRegisteredDataTasks removeObjectForKey:taskInfo.key];
                break;
            }
        }
        [self.lockDataTasks unlock];
    }
}

- (void)setStartTime:(NSDate*)startTime forSessionDataTask:(NSURLSessionDataTask*)dataTask
{
    if (self.isInitialized) {
        if( startTime && dataTask )
        {
            [self.lockDataTasks lock];
            NSArray* listDataTaskInfoKeys = [self.dictRegisteredDataTasks allKeys];
    
            for( NSDate* date in listDataTaskInfoKeys )
            {
                ApigeeNSURLSessionDataTaskInfo* dataTaskInfo =
                    [self.dictRegisteredDataTasks objectForKey:date];
                if( dataTaskInfo && (dataTaskInfo.sessionDataTask == dataTask) )
                {
                    dataTaskInfo.startTime = startTime;
                    [self.lockDataTasks unlock];
                    return;
                }
            }
            [self.lockDataTasks unlock];
        }
    }
}

@end


@implementation ApigeeMonitoringClient (NetworkActivityTracking)

- (void) updateLastNetworkTransmissionTime:(NSString*) networkTransmissionTime
{
    if (self.isInitialized) {
        if ([networkTransmissionTime length] > 0) {
            // the time is represented in milliseconds as a string
        
            // get the value as a 64-bit integer
            int64_t msNetworkTransTime = [networkTransmissionTime longLongValue];
        
            // convert that to an NSDate
            NSDate *dateNetworkTransTime = [NSDate dateFromMilliseconds:msNetworkTransTime];
        
            // convert date to mach time
            uint64_t machTime = [self dateToMachTime:dateNetworkTransTime];
        
            self.lastNetworkTransmissionTime = machTime;
        }
    }
}

@end

