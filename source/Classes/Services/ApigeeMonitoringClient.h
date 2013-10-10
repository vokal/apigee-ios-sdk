//
//  ApigeeMonitoringClient.h
//
//  Copyright (c) 2012 Apigee. All rights reserved.
//

#import "ApigeeActiveSettings.h"
#import "ApigeeUploadListener.h"

@class ApigeeAppIdentification;
@class ApigeeDataClient;
@class ApigeeMonitoringOptions;
@class ApigeeNSURLSessionDataTaskInfo;
@class ApigeeNetworkEntry;

@interface ApigeeMonitoringClient : NSObject

@property (strong,readonly) NSString *apigeeDeviceId;

@property (strong, nonatomic) ApigeeActiveSettings *activeSettings;


/**
 Retrieves the SDK version
 @return string version of SDK
 */
+ (NSString*)sdkVersion;



/**
 Returns the shared instance of ApigeeMonitoringClient. This method is
 provided as a convenience method. Ideally, your app delegate should
 maintain a reference to the single instance of ApigeeMonitoringClient.
 
 @return instance of ApigeeMonitoringClient
 */
+ (id)sharedInstance;

/**
 Initializes ApigeeMonitoringClient which controls the Apigee mobile agent.
 @param appIdentification the identification attributes for your application
 @param dataClient the data client object initialized by Apigee SDK
 @return initialized instance of ApigeeMonitoringClient
 */
- (id) initWithAppIdentification:(ApigeeAppIdentification*)appIdentification
                      dataClient:(ApigeeDataClient*)dataClient;

/**
 Initializes ApigeeMonitoringClient which controls the Apigee mobile agent.
 @param appIdentification the identification attributes for your application
 @param dataClient the data client object initialized by Apigee SDK
 @param monitoringOptions the options desired for monitoring
 @return initialized instance of ApigeeMonitoringClient
 */
- (id) initWithAppIdentification:(ApigeeAppIdentification*)appIdentification
                      dataClient:(ApigeeDataClient*)dataClient
                         options:(ApigeeMonitoringOptions*)monitoringOptions;

/**
 Initializes ApigeeMonitoringClient which controls the Apigee mobile agent.
 @deprecated in version 2.0 - please use initializer that accepts ApigeeMonitoringOptions
 @param appIdentification the identification attributes for your application
 @param dataClient the data client object initialized by Apigee SDK
 @param crashReportingEnabled determines whether crash reports should be uploaded to server (allows you to opt-out of crash reports)
 @return initialized instance of ApigeeMonitoringClient
 */
- (id) initWithAppIdentification: (ApigeeAppIdentification*) appIdentification
                      dataClient: (ApigeeDataClient*) dataClient
                  crashReporting: (BOOL) crashReportingEnabled __attribute__ ((deprecated));

/**
 Initializes ApigeeMonitoringClient which controls the Apigee mobile agent.
 @deprecated in version 2.0 - please use initializer that accepts ApigeeMonitoringOptions
 @param appIdentification the identification attributes for your application
 @param dataClient the data client object initialized by Apigee SDK
 @param crashReportingEnabled determines whether crash reports should be uploaded to server (allows you to opt-out of crash reports)
 @param autoInterceptCalls determines whether automatic interception of network calls is enabled (allows you to opt-out)
 @return initialized instance of ApigeeMonitoringClient
 */
- (id) initWithAppIdentification: (ApigeeAppIdentification*) appIdentification
                      dataClient: (ApigeeDataClient*) dataClient
                  crashReporting: (BOOL) crashReportingEnabled
           interceptNetworkCalls: (BOOL) autoInterceptCalls __attribute__ ((deprecated));

/**
 Initializes ApigeeMonitoringClient which controls the Apigee mobile agent.
 @deprecated in version 2.0 - please use initializer that accepts ApigeeMonitoringOptions
 @param appIdentification the identification attributes for your application
 @param dataClient the data client object initialized by Apigee SDK
 @param crashReportingEnabled determines whether crash reports should be uploaded to server (allows you to opt-out of crash reports)
 @param autoInterceptCalls determines whether automatic interception of network calls is enabled (allows you to opt-out)
 @param uploadListener listener to be notified on upload of crash reports and metrics
 @return initialized instance of ApigeeMonitoringClient
 */
- (id) initWithAppIdentification: (ApigeeAppIdentification*) appIdentification
                      dataClient: (ApigeeDataClient*) dataClient
                  crashReporting: (BOOL) crashReportingEnabled
           interceptNetworkCalls: (BOOL) autoInterceptCalls
                  uploadListener: (id<ApigeeUploadListener>)uploadListener __attribute__ ((deprecated));

/**
 Answers the question of whether the device session is participating in the sampling
 of metrics. An app configuration of 100% would cause this method to always return YES,
 while an app configuration of 100% would cause this method to always return NO.
 Intermediate values of sampling percentage will cause a random YES/NO to be returned
 with a probability equal to the sampling percentage configured for the app.
 @return boolean indicating whether device session is participating in metrics sampling
 */
- (BOOL)isParticipatingInSample;

/**
 Answers the question of whether the device is currently connected to a network
 (either WiFi or cellular).
 @return boolean indicating whether device currently has network connectivity
 */
- (BOOL)isDeviceNetworkConnected;

/**
 Retrieves all customer configuration parameter keys that belong to the
 specified category.
 @param category the category whose keys are desired
 @return array of keys belonging to category, or nil if no keys exist
 */
- (NSArray*)customConfigPropertyKeysForCategory:(NSString*)category;

/**
 Retrieves the value for the specified custom configuration parameter.
 @param key the key name for the desired custom configuration parameter
 @return value associated with key, or nil if no property exists
 */
- (NSString*)customConfigPropertyValueForKey:(NSString*)key;

/**
 Retrieves the value for the specified custom configuration parameter.
 @param key the key name for the desired custom configuration parameter
 @param categoryName the category for the desired custom configuration parameter
 @return value associated with key and category, or nil if no property exists
 */
- (NSString*)customConfigPropertyValueForKey:(NSString *)key
                                 forCategory:(NSString*)categoryName;

/**
 Forces device metrics to be uploaded.
 @return boolean indicating whether metrics were able to be uploaded
 */
- (BOOL)uploadMetrics;

/**
 Forces upload of metrics asynchronously
 @param completionHandler a completion handler to run when the upload completes
 */
- (void)asyncUploadMetrics:(void (^)(BOOL))completionHandler;

/**
 Forces update (re-read) of configuration information.
 @return boolean indicating whether the re-read of configuration parameters
 was successful
 */
- (BOOL)refreshConfiguration;

/**
 Force update (re-read) of configuration asynchronously
 @param completionHandler a completion handler to run when the refresh completes
 */
- (void)asyncRefreshConfiguration:(void (^)(BOOL))completionHandler;

/**
 Adds an upload listener (observer) that will be notified when uploads are sent to server
 @param uploadListener the listener to add (and be called) when uploads occur
 @return boolean indicating whether the listener was added
 */
- (BOOL)addUploadListener:(id<ApigeeUploadListener>)uploadListener;

/**
 Removes an upload listener (observer)
 @param uploadListener the listener to remove so that it's no longer called
 @return boolean indicating whether the listener was removed
 */
- (BOOL)removeUploadListener:(id<ApigeeUploadListener>)uploadListener;

/**
 Records a successful network call.
 @param url the url accessed
 @param startTime the time when the call was initiated
 @param endTime the time when the call completed
 @return boolean indicating whether the recording was made or not
 */
- (BOOL)recordNetworkSuccessForUrl:(NSString*)url
                         startTime:(NSDate*)startTime
                           endTime:(NSDate*)endTime;

/**
 Records a failed network call.
 @param url the url accessed
 @param startTime the time when the call was initiated
 @param endTime the time when the call failed
 @param errorDescription description of the error encountered
 @return boolean indicating whether the recording was made or not
 */
- (BOOL)recordNetworkFailureForUrl:(NSString*)url
                         startTime:(NSDate*)startTime
                           endTime:(NSDate*)endTime
                             error:(NSString*)errorDescription;

/**
 Retrieves the base URL path used by monitoring
 @return string indicating base URL path used by monitoring
 */
- (NSString*)baseURLPath;

/** The following methods are advanced methods intended to be used in
   conjunction with our C API. They would not be needed for a typical
   Objective-C application. */

/**
 Retrieves the time that the mobile agent was initialized (i.e., startup time)
 @return date object representing mobile agent startup time
 */
- (NSDate*)timeStartup;

/**
 Retrieves the Mach time that the mobile agent was initialized (i.e., startup time)
 @return Mach time in billionths of a second representing mobile agent startup time
 */
- (uint64_t)timeStartupMach;

/**
 Retrieves the Mach time that the mobile agent last uploaded metrics to portal
 @return Mach time in billionths of a second representing time of last metrics upload (or 0 if no upload has occurred)
 */
- (uint64_t)timeLastUpload;

/**
 Retrieves the Mach time that the mobile agent last recognized a network transmission
 @return Mach time in billionths of a second representing time of last network transmission (or 0 if none has occurred)
 */
- (uint64_t)timeLastNetworkTransmission;

/**
 Converts a Mach time to an NSDate object
 @param mach_time the Mach time (in billionths of a second) to convert
 @return the Mach time represented as an NSDate
 */
- (NSDate*)machTimeToDate:(uint64_t)mach_time;

/*
- (void) updateLastNetworkTransmissionTime:(NSString*) networkTransmissionTime;
*/

// an internal-use method
- (void)recordNetworkEntry:(ApigeeNetworkEntry*)entry;

// the following methods are used for auto-capture of network performance
// with NSURLSession. they are for internal use within the framework only.
#ifdef __IPHONE_7_0
- (id)generateIdentifierForDataTask;
- (void)registerDataTaskInfo:(ApigeeNSURLSessionDataTaskInfo*)dataTaskInfo withIdentifier:(id)identifier;
- (ApigeeNSURLSessionDataTaskInfo*)dataTaskInfoForIdentifier:(id)identifier;
- (ApigeeNSURLSessionDataTaskInfo*)dataTaskInfoForTask:(NSURLSessionTask*)task;
- (void)removeDataTaskInfoForIdentifier:(id)identifier;
- (void)removeDataTaskInfoForTask:(NSURLSessionTask*)task;
- (void)setStartTime:(NSDate*)startTime forSessionDataTask:(NSURLSessionDataTask*)dataTask;
#endif

@end
