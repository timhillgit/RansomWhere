//
//  Utilities.m
//  BlockBlock
//
//  Created by Patrick Wardle on 10/31/14.
//  Copyright (c) 2015 Objective-See. All rights reserved.
//

#import "Consts.h"
#import "Logging.h"
#import "Process.h"
#import "Utilities.h"

#import <libproc.h>
#import <sys/sysctl.h>
#import <CommonCrypto/CommonDigest.h>
#import <OpenDirectory/OpenDirectory.h>
#import <CoreFoundation/CoreFoundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ApplicationServices/ApplicationServices.h>

//return path to launch daemon's plist
NSString* launchDaemonPlist()
{
    //build and ret
    return [NSString pathWithComponents:@[@"/Library/LaunchDaemons", LAUNCH_ITEM_PLIST]];
}

//return path to launch agent's plist
NSString* launchAgentPlist(NSString* userHomeDirectory)
{
    //build and ret
    // ->utilizes user's home directory
    return [NSString pathWithComponents:@[userHomeDirectory, @"/Library/LaunchAgents", LAUNCH_ITEM_PLIST]];
}

//return path to kext
NSString* kextPath()
{
    //build and ret
    return [NSString pathWithComponents:@[@"/Library/Extensions", KEXT_NAME]];
}

//return path to bb's support directory
// ->~/Library/Application Support/<app bundle id>
NSString* supportDirectory()
{
    //path to log directory
    NSString* supportDirectory = nil;
    
    //system application support directory
    NSString* appSupportDirectory = nil;
    
    //grab application support directory
    appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    if(nil == appSupportDirectory)
    {
        //bail
        goto bail;
    }
    
    //build path
    supportDirectory = [appSupportDirectory stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]];
    
//bail
bail:
    
    return supportDirectory;
}


//given a path to binary
// parse it back up to find app's bundle
NSBundle* findAppBundle(NSString* binaryPath)
{
    //app's bundle
    NSBundle* appBundle = nil;
    
    //app's path
    NSString* appPath = nil;
    
    //first just try full path
    appPath = binaryPath;
    
    //try to find the app's bundle/info dictionary
    do
    {
        //try to load app's bundle
        appBundle = [NSBundle bundleWithPath:appPath];
        
        //check for match
        // ->binary path's match
        if( (nil != appBundle) &&
            (YES == [appBundle.executablePath isEqualToString:binaryPath]))
        {
            //all done
            break;
        }
        
        //always unset bundle var since it's being returned
        // ->and at this point, its not a match
        appBundle = nil;
        
        //remove last part
        // ->will try this next
        appPath = [appPath stringByDeletingLastPathComponent];
        
    //scan until we get to root
    // ->of course, loop will be exited if app info dictionary is found/loaded
    } while( (nil != appPath) &&
             (YES != [appPath isEqualToString:@"/"]) &&
             (YES != [appPath isEqualToString:@""]) );
    
    return appBundle;
}

//given a path to an application
// ->gets app's info dictionary
NSDictionary* getAppInfo(NSString* appPath)
{
    //app's bundle
    NSBundle* appBundle = nil;
    
    //app's info dictionary
    NSDictionary* appInfo = nil;
    
    //init bundle
    appBundle = [NSBundle bundleWithPath:appPath];
    if(nil != appBundle)
    {
        //extract info dictionary
        appInfo = [appBundle infoDictionary];
    }
    
    return appInfo;
}

//wait for a a plist
// ->then extract a value for a key
id getValueFromPlist(NSString* plistFile, NSString* key, float maxWait)
{
    //return var
    // ->value from plist
    id plistValue;
    
    //count var for loop
    NSUInteger count = 0;
    
    //contents of plist
    NSDictionary* plistContents = nil;
    
    //try/wait for plist to be written to disk
    // ->then load/parse it to get value for key
    do
    {
        //wait for plist
        if(YES == [[NSFileManager defaultManager] fileExistsAtPath:plistFile])
        {
            //nap for 1/10th of a second
            // ->just in case its still being saved
            [NSThread sleepForTimeInterval:WAIT_INTERVAL];
            
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"napping...plist");
            #endif
            
            //try to load content's of Info.plist
            plistContents = [NSDictionary dictionaryWithContentsOfFile:plistFile];
            if( (nil != plistContents) && (nil != plistContents[key]) )
            {
                //extract value
                plistValue = plistContents[key];
                
                //got it, so bail
                break;
            }
        }
        
        //nap for 1/10th of a second
        [NSThread sleepForTimeInterval:WAIT_INTERVAL];
        
    //try up to 1 second
    }while(count++ < maxWait/WAIT_INTERVAL);
    
    return plistValue;
}

//given a pid and process name, try to find full path
// ->first tries proc_pidpath(), then 'which'
NSString* getFullPath(NSNumber* processID, NSString* processName, BOOL tryWhich)
{
    //full path
    NSString* fullPath = nil;
    
    //buffer for proc_pidpath()
    char pidPath[PROC_PIDPATHINFO_MAXSIZE] = {0};

    //first try proc_pidpath w/ pID
    if(0 != proc_pidpath([processID intValue], pidPath, PROC_PIDPATHINFO_MAXSIZE))
    {
        //save it
        fullPath = [NSString stringWithUTF8String:pidPath];
    }
    //otherwise try 'which'
    // ->scans path looking for (likely) match
    else
    {
        //try using 'which'
        fullPath = which(processName);
    }
    
    return fullPath;
}


//given a 'short' path or process name
// ->find the full path by scanning $PATH
NSString* which(NSString* processName)
{
    //full path
    NSString* fullPath = nil;
    
    //get path
    NSString* path = nil;
    
    //tokenized paths
    NSArray* pathComponents = nil;
    
    //candidate file
    NSString* candidateBinary = nil;
    
    //get path
    path = [[[NSProcessInfo processInfo]environment]objectForKey:@"PATH"];
    
    //split on ':'
    pathComponents = [path componentsSeparatedByString:@":"];
    
    //iterate over all path components
    // ->build candidate path and check if it exists
    for(NSString* pathComponent in pathComponents)
    {
        //build candidate path
        // ->current path component + process name
        candidateBinary = [pathComponent stringByAppendingPathComponent:processName];
        
        //check if it exists
        if(YES == [[NSFileManager defaultManager] fileExistsAtPath:candidateBinary])
        {
            //check its executable
            if(YES == [[NSFileManager defaultManager] isExecutableFileAtPath:candidateBinary])
            {
                //ok, happy now
                fullPath = candidateBinary;
                
                //stop processing
                break;
            }
        }
    }//for path components

    return fullPath;
}

//start an NSTask
NSUInteger execTask(NSString* path, NSArray* arguments, BOOL waitUntilExit)
{
    //task object
    NSTask *task = nil;
    
    //task status
    NSUInteger taskStatus = -1;
    
    //make sure path exists
    // ->otherwise NSTask will throw an NSInvalidArgumentException error
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:path])
    {
        //error
        logMsg(LOG_ERR, [NSString stringWithFormat:@"cannot exec NSTask since %@ was not found", path]);
        
        //bail
        goto bail;
    }
    
    //create task
    task = [[NSTask alloc] init];
    
    //set launch path
    // ->unzip binary
    [task setLaunchPath:path];
    
    //set args
    if(nil != arguments)
    {
        //set
        [task setArguments:arguments];
    }
    
    //wrap task launch
    @try
    {
        //exec task
        [task launch];
    }
    @catch(NSException* exception)
    {
        //bail
        goto bail;
    }
    
    //wait for task to exit
    // ->then grab status
    if(YES == waitUntilExit)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"waiting for task to exit");
        #endif
        
        //wait
        [task waitUntilExit];
        
        //get status
        taskStatus = [task terminationStatus];
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"task exited with %lu", (unsigned long)taskStatus]);
        #endif

    }
    //don't wait
    // ->just set status to zero
    else
    {
        //set zero task status
        taskStatus = 0;
    }
    
//bail
bail:
    
    return taskStatus;
}

//get all users
NSMutableArray* getUsers()
{
    //users
    NSMutableArray* users = nil;
    
    //root node
    ODNode *root = nil;
    
    //user query
    ODQuery *userQuery = nil;
    
    //alloc
    users = [NSMutableArray array];
    
    //init root node
    root = [ODNode nodeWithSession:[ODSession defaultSession] name:@"/Local/Default" error:nil];
    
    //make query
    userQuery = [ODQuery queryWithNode:root forRecordTypes:kODRecordTypeUsers attribute:nil matchType:0 queryValues:nil returnAttributes:nil maximumResults:0 error:nil];
    
    //iterate over all users and save
    for(ODRecord* record in [userQuery resultsAllowingPartial:NO error:nil])
    {
        //dbg msg
        //logMsg(LOG_DEBUG, [NSString stringWithFormat:@"record: %@", record]);
        
        //save
        [users addObject:record];
    }
    
    //dbg msg
    //logMsg(LOG_DEBUG, [NSString stringWithFormat:@"all users: %@", users]);
    
    return users;
}

//bring an app to foreground (to get an icon in the dock) or background
void transformProcess(ProcessApplicationTransformState location)
{
    //process serial no
    ProcessSerialNumber processSerialNo;
    
    //init process stuct
    // ->high to 0
    processSerialNo.highLongOfPSN = 0;
    
    //init process stuct
    // ->low to self
    processSerialNo.lowLongOfPSN = kCurrentProcess;
    
    //transform to foreground
    if(STATUS_SUCCESS != TransformProcessType(&processSerialNo, location))
    {
        //err msg
        // ->ignored by the process, but good to log...
        logMsg(LOG_ERR, @"failed to transform process to foreground");
    }
    
    return;
}

//get info about current logged in/active user
NSDictionary* getCurrentConsoleUser()
{
    //all users
    NSArray* allUsers = nil;
    
    //user info dictionary
    NSMutableDictionary* userInfo = nil;
    
    //user's name
    NSString* userName = nil;
    
    //user's uid
    uid_t userID = 0;
    
    //user's gid
    gid_t groupID = 0;
    
    //user's home directory
    NSString* userHomeDirectory = nil;
    
    //record data
    NSArray* recordData = nil;
    
    //get current user
    userName = (__bridge NSString *)(SCDynamicStoreCopyConsoleUser(NULL, &userID, &groupID));
    
    //sanity check
    if(NULL == userName)
    {
        //bail
        goto bail;
    }
    
    //treat "loginwindow" as no user
    if(YES == [userName isEqualToString:@"loginwindow"])
    {
        //bail
        goto bail;
    }
    
    //get all users
    // ->need user's home directory
    allUsers = getUsers();
    
    //iterate over all users till we find match
    for(ODRecord* userRecord in allUsers)
    {
        //dbg msg
        //logMsg(LOG_DEBUG, [NSString stringWithFormat:@"record: %@", userRecord]);
        
        //get current uid
        recordData = [userRecord valuesForAttribute:kODAttributeTypeUniqueID error:NULL];
        
        //check if there is a uid
        if(0 == [recordData count])
        {
            //skip
            continue;
        }
        
        //logMsg(LOG_DEBUG, [NSString stringWithFormat:@"record class %@", [[recordData firstObject] className]]);
        
        //check for match
        if(userID == [[recordData firstObject] intValue])
        {
            //extract home dirs
            recordData = [userRecord valuesForAttribute:kODAttributeTypeNFSHomeDirectory error:NULL];
            
            //check if there is a home dir
            if(0 != [recordData count])
            {
                //save
                userHomeDirectory = [recordData firstObject];
                
                //done
                break;
            }
        }
    
    }
    
    //alloc
    userInfo = [NSMutableDictionary dictionary];
    
    //add name
    userInfo[@"name"] = userName;
    
    //add uid
    userInfo[@"uid"] = [NSNumber numberWithInt:userID];
    
    //add gid
    userInfo[@"gid"] = [NSNumber numberWithInt:groupID];
    
    //add user's home directory
    if(nil != userHomeDirectory)
    {
        //add
        userInfo[@"homeDirectory"] = userHomeDirectory;
    }
    
//bail
bail:
    
    //free user name
    if(NULL != userName)
    {
        //free
        CFRelease((CFStringRef)userName);
        userName = NULL;
    }

    return userInfo;
}

//determine if there is a new version
// -1, YES or NO
NSInteger isNewVersion(NSMutableString* versionString)
{
    //flag
    NSInteger newVersionExists = -1;
    
    //installed version
    NSString* installedVersion = nil;
    
    //latest version
    NSString* latestVersion = nil;
    
    //get installed version
    installedVersion = getAppVersion();
    
    //get latest version
    // ->will query internet (bb's website)
    latestVersion = getLatestVersion();
    if(nil == latestVersion)
    {
        //set error msg
        [versionString setString:@"failed to get latest version"];
        
        //bail
        goto bail;
    }
    
    //save version
    [versionString setString:latestVersion];
    
    //set version flag
    // ->YES/NO
    newVersionExists = (NSOrderedAscending == [installedVersion compare:latestVersion options:NSNumericSearch]);
    
//bail
bail:
    
    return newVersionExists;
}


//get version
// ->either of self, or installed
NSString* getVersion(NSUInteger instance)
{
    //version
    NSString* currentVersion = nil;
    
    //info dictionary
    NSDictionary* infoDictionary = nil;
    
    //for current version
    // ->get info dictionary from main bundle
    if(VERSION_INSTANCE_SELF == instance)
    {
        //get info dictionary
        infoDictionary = [[NSBundle mainBundle] infoDictionary];
    }
    //for installed version
    // ->get info dictionary from loaded bundle
    else if(VERSION_INSTANCE_INSTALLED == instance)
    {
        //get info dictionary
        infoDictionary = getAppInfo([INSTALL_DIRECTORY stringByAppendingPathComponent:APPLICATION_NAME]);
    }
    
    //extract version string
    // ->'CFBundleVersion'
    if(nil != infoDictionary)
    {
        //extract
        currentVersion = infoDictionary[@"CFBundleVersion"];
    }
    
    return currentVersion;
}

//query interwebz to get latest version
NSString* getLatestVersion()
{
    //product version(s) data
    NSData* productsVersionData = nil;
    
    //version dictionary
    NSDictionary* productsVersionDictionary = nil;
    
    //latest version
    NSString* latestVersion = nil;
    
    //get version from remote URL
    productsVersionData = [[NSData alloc] initWithContentsOfURL:[NSURL URLWithString:PRODUCT_VERSIONS_URL]];
    if(nil == productsVersionData)
    {
        //bail
        goto bail;
    }
    
    //convert JSON to dictionary
    // ->wrap as may throw exception
    @try
    {
        //convert
        productsVersionDictionary = [NSJSONSerialization JSONObjectWithData:productsVersionData options:0 error:nil];
        if(nil == productsVersionDictionary)
        {
            //bail
            goto bail;
        }
    }
    @catch(NSException* exception)
    {
        //bail
        goto bail;
    }
    
    //extract latest version
    latestVersion = [[productsVersionDictionary objectForKey:@"BlockBlock"] objectForKey:@"version"];
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"latest version: %@", latestVersion]);
    #endif
    
//bail
bail:
    
    return latestVersion;
}



//check if process is alive
BOOL isProcessAlive(pid_t processID)
{
    //ret var
    BOOL bIsAlive = NO;
    
    //signal status
    int signalStatus = -1;
    
    //send kill with 0 to determine if alive
    // -> see: http://stackoverflow.com/questions/9152979/check-if-process-exists-given-its-pid
    signalStatus = kill(processID, 0);
    
    //is alive?
    if( (0 == signalStatus) ||
        ( (0 != signalStatus) && (errno != ESRCH) ) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"agent (%d) is ALIVE", processID]);
        #endif
        
        //alive!
        bIsAlive = YES;
    }
    
    return bIsAlive;
}

//check if current OS version is supported
// ->for now, just...?
BOOL isSupportedOS()
{
    //support flag
    BOOL isSupported = NO;
    
    //OS version info
    NSDictionary* osVersionInfo = nil;
    
    //get OS version info
    osVersionInfo = getOSVersion();
    
    //sanity check
    if(nil == osVersionInfo)
    {
        //bail
        goto bail;
    }
    
    //gotta be OS X
    if(10 != [osVersionInfo[@"majorVersion"] intValue])
    {
        //err msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"OS major version %@ not supported", osVersionInfo[@"majorVersion"]]);
        #endif
        
        //bail
        goto bail;
    }
    
    //gotta be OS X 10.9
    if([osVersionInfo[@"minorVersion"] intValue] < 9)
    {
        //err msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"OS minor version %@ not supported", osVersionInfo[@"minor"]]);
        #endif
        
        //bail
        goto bail;
    }
    
    //OS version is supported
    isSupported = YES;
    
//bail
bail:
    
    return isSupported;
}

//set dir's|file's group/owner
BOOL setFileOwner(NSString* path, NSNumber* groupID, NSNumber* ownerID, BOOL recursive)
{
    //ret var
    BOOL bRet = NO;
    
    //owner dictionary
    NSDictionary* fileOwner = nil;
    
    //sub paths
    NSArray *subPaths = nil;
    
    //full path
    // ->for recursive
    NSString* fullPath = nil;
    
    //init permissions dictionary
    fileOwner = @{NSFileGroupOwnerAccountID:groupID, NSFileOwnerAccountID:ownerID};
    
    //set group/owner
    if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:path error:NULL])
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", path, fileOwner]);
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"set ownership for %@ (%@)", path, fileOwner]);
    #endif
    
    //do it recursively
    if(YES == recursive)
    {
        //sanity check
        // ->make sure root starts with '/'
        if(YES != [path hasSuffix:@"/"])
        {
            //add '/'
            path = [NSString stringWithFormat:@"%@/", path];
        }
        
        //get all subpaths
        subPaths = [[NSFileManager defaultManager] subpathsAtPath:path];
        for(NSString *subPath in subPaths)
        {
            //init full path
            fullPath = [path stringByAppendingString:subPath];
            
            //set group/owner
            if(YES != [[NSFileManager defaultManager] setAttributes:fileOwner ofItemAtPath:fullPath error:NULL])
            {
                //err msg
                logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set ownership for %@ (%@)", fullPath, fileOwner]);
                
                //bail
                goto bail;
            }
        }
    }
    
    //no errors
    bRet = YES;
    
//bail
bail:
    
    return bRet;
}

//given a list of process and a path
// ->find most recent process that matches
pid_t mostRecentProc(OrderedDictionary* processList, NSString* path)
{
    //pid
    pid_t pID = 0;
    
    //process
    Process* process = nil;

    //sync
    @synchronized(processList)
    {
        
    //iterate over all processes backwards
    // ->find pid of process (of must recent process) that matches path
    for(NSString* processID in [processList reverseKeyEnumerator])
    {
        //extract process
        process = processList[processID];
        
        //check for match
        if( (YES == [process.path isEqualToString:path]) ||
            (YES ==  [[process.bundle bundlePath] isEqualToString:path]) )
        {
            //save pid
            pID = process.pid;
            
            //bail
            break;
        }
    }
        
    }//sync

    return pID;
}

//get OS version
NSDictionary* getOSVersion()
{
    //os version info
    NSMutableDictionary* osVersionInfo = nil;

    //major v
    SInt32 majorVersion = 0;
    
    //minor v
    SInt32 minorVersion = 0;
    
    //alloc dictionary
    osVersionInfo = [NSMutableDictionary dictionary];
    
    //get major version
    if(STATUS_SUCCESS != Gestalt(gestaltSystemVersionMajor, &majorVersion))
    {
        //reset
        osVersionInfo = nil;
        
        //bail
        goto bail;
    }
    
    //get minor version
    if(STATUS_SUCCESS != Gestalt(gestaltSystemVersionMinor, &minorVersion))
    {
        //reset
        osVersionInfo = nil;
        
        //bail
        goto bail;
    }
    
    //set major version
    osVersionInfo[@"majorVersion"] = [NSNumber numberWithInteger:majorVersion];
    
    //set minor version
    osVersionInfo[@"minorVersion"] = [NSNumber numberWithInteger:minorVersion];
    
    //dbg msg
    //logMsg(LOG_DEBUG, [NSString stringWithFormat:@"current OS version info: %@", osVersionInfo]);
    
//bail
bail:
    
    return osVersionInfo;
    
}

//get path to app's (self) 'Info.plist' file
NSString* infoPlistFile()
{
    //path
    NSString* path = nil;
    
    //contents
    NSDictionary* contents = nil;
    
    //load 'Info.plist'
    contents = [[NSBundle mainBundle] infoDictionary];
    
    //sanity check
    if(nil == contents[@"CFBundleInfoPlistURL"])
    {
        //bail
        goto bail;
    }
    
    //extract path
    path = [NSString stringWithUTF8String:[contents[@"CFBundleInfoPlistURL"] fileSystemRepresentation]];
    
//bail
bail:
    
    return path;
}

//get app's version
// ->extracted from Info.plist
NSString* getAppVersion()
{
    //read and return 'CFBundleVersion' from bundle
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
}


//given a pid, get its parent (ppid)
pid_t getParentID(int pid)
{
    //parent id
    pid_t parentID = -1;
    
    //kinfo_proc struct
    struct kinfo_proc processStruct = {0};
    
    //size
    size_t procBufferSize = sizeof(processStruct);
    
    //mib
    const u_int mibLength = 4;
    
    //syscall result
    int sysctlResult = -1;
    
    //init mib
    int mib[mibLength] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    
    //make syscall
    sysctlResult = sysctl(mib, mibLength, &processStruct, &procBufferSize, NULL, 0);
    
    //check if got ppid
    if( (STATUS_SUCCESS == sysctlResult) &&
        (0 != procBufferSize) )
    {
        //save ppid
        parentID = processStruct.kp_eproc.e_ppid;
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"extracted parent ID %d for process: %d", parentID, pid]);
        #endif
    }
    
    return parentID;
}


//determine if instance is daemon (background) instance
BOOL isDaemonInstance()
{
    //flag
    BOOL isDaemon = NO;
    
    //args
    NSArray* arguments = nil;
    
    //grab args
    arguments = NSProcessInfo.processInfo.arguments;

    //check args for 'run daemon' flag
    if( (2 == arguments.count) &&
        (YES == [arguments[1] isEqualToString:ACTION_RUN_DAEMON]))
    {
        //daemon
        isDaemon = YES;
    }
    
    return isDaemon;
}

//wait until a window is non nil
// ->then make it modal
void makeModal(NSWindowController* windowController)
{
    //wait up to 1 second window to be non-nil
    // ->then make modal
    for(int i=0; i<20; i++)
    {
        //can make it modal once we have a window
        if(nil != windowController.window)
        {
            //make modal on main thread
            dispatch_sync(dispatch_get_main_queue(), ^{
                
                //modal
                [[NSApplication sharedApplication] runModalForWindow:windowController.window];
                
            });
            
            //all done
            break;
        }
        
        //nap
        [NSThread sleepForTimeInterval:0.05f];
        
    }//until 1 second
    
    return;
}

//hash a file (sha1)
NSMutableString* hashFile(NSString* filePath)
{
    //file's contents
    NSData* fileContents = nil;
    
    //hash digest (sha1)
    uint8_t digestSHA1[CC_SHA1_DIGEST_LENGTH] = {0};
    
    //sha1 hash as string
    NSMutableString* sha1 = nil;
    
    //index var
    NSUInteger index = 0;
    
    //init sha1 hash string
    sha1 = [NSMutableString string];
    
    //sanity check
    if(nil == filePath)
    {
        //bail
        goto bail;
    }
    
    //load file
    if(nil == (fileContents = [NSData dataWithContentsOfFile:filePath]))
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load %@ to hash", filePath]);
        
        //bail
        goto bail;
    }
    
    //sha1 it
    CC_SHA1(fileContents.bytes, (unsigned int)fileContents.length, digestSHA1);
    
    //convert to NSString
    // ->iterate over each bytes in computed digest and format
    for(index=0; index < CC_SHA1_DIGEST_LENGTH; index++)
    {
        //format/append
        [sha1 appendFormat:@"%02lX", (unsigned long)digestSHA1[index]];
    }
    
//bail
bail:
    
    return sha1;
}


