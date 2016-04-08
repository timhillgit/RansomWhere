//
//  main.m
//  RansomWhere
//
//  Created by Patrick Wardle on 3/20/16.
//  Copyright © 2016 Objective-See. All rights reserved.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "main.h"
#import "Queue.h"
#import "Consts.h"
#import "Logging.h"
#import "Binary.h"
#import "Exception.h"
#import "Utilities.h"
#import "ProcessMonitor.h"
#import "FSMonitor.h"
#import "3rdParty/ent/ent.h"


//sudo chown -R root:wheel  /Users/patrick/objective-see/tbd/DerivedData/tbd/Build/Products/Debug/tbd
//sudo chmod 4755 /Users/patrick/objective-see/tbd/DerivedData/tbd/Build/Products/Debug/tbd


//global list of binary objects
// ->running/installed/user approved apps
NSMutableDictionary* binaryList = nil;

//TODO: don't need entropy? (pi is enough?)

//TODO: allow apps from app store
//      see: https://github.com/ole/NSBundle-OBCodeSigningInfo/blob/master/NSBundle%2BOBCodeSigningInfo.m & https://github.com/rmaddy/VerifyStoreReceiptiOS
//      though looks like not trivial to do...

//main interface
// ->init some procs, kick off file-system watcher, then just runloop()
int main(int argc, const char * argv[])
{
    //pool
    @autoreleasepool
    {
        //isEncrypted([NSString stringWithUTF8String:argv[1]]);
        //return 0;
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"daemon instance");
        #endif
        
        //sanity check
        // ->gotta be r00t
        if(0 != geteuid())
        {
            //err msg
            // ->syslog() & printf() since likely run from cmdline for this to happen?
            logMsg(LOG_ERR, @"must be run as r00t");
            printf("\nRANSOMWHERE ERROR: must be run as r00t\n\n");
            
            //bail
            goto bail;
        }
        
        //first thing...
        // ->install exception handlers
        installExceptionHandlers();
        
        //handle '-reset'
        // ->delete list of installed/approved apps, etc
        if( (2 == argc) &&
            (0 == strcmp(argv[1], RESET_FLAG)) )
        {
            //do it
            reset();
            
            //all pau
            goto bail;
        }
        
        //alloc global dictionary for binary list
        binaryList = [NSMutableDictionary dictionary];
        
        //init paths
        // ->this logic will only be needed if daemon is executed from non-standard location
        if(YES != initPaths())
        {
            //err msg
            logMsg(LOG_ERR, @"failed to initialize paths");
            
            //bail
            goto bail;
        }
        
        //create binary objects for all baselined app
        // ->first time; generate list from OS (this might take a while)
        if(YES != processBaselinedApps())
        {
            //err msg
            logMsg(LOG_ERR, @"failed to enumerate/process baselined apps");
            
            //bail
            goto bail;
        }
        
        //create binary objects for all (persistent) user-approved binaries
        if(YES != processApprovedBins())
        {
            //err msg
            logMsg(LOG_ERR, @"failed to enumerate/process user-approved apps");
            
            //bail
            goto bail;
        }
        
        //create binary objects for all currently running processes
        if(YES != processRunningProcs())
        {
            //err msg
            logMsg(LOG_ERR, @"failed to enumerate/process running apps");
            
            //bail
            goto bail;
        }
        
        //priority++
        setpriority(PRIO_PROCESS, getpid(), PRIO_MIN+1);
        
        //io policy++
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
        
        //msg
        // ->always print
        syslog(LOG_ERR, "OBJECTIVE-SEE RANSOMWHERE: completed initializations; monitoring engaged!\n");
        
        //start file system monitoring
        [NSThread detachNewThreadSelector:@selector(monitor) toTarget:[[FSMonitor alloc] init] withObject:nil];
        
        //run
        CFRunLoopRun();
    }
    
//bail
bail:
    
    //dbg msg
    // ->shouldn't exit unless manually unloaded, reset mode, etc
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"exiting");
    #endif
    
    return 0;
}

//delete list of installed/approved apps, etc
// ->note: as invoked via cmdline, use printf()'s for output
BOOL reset()
{
    //flag
    BOOL fullReset = NO;
    
    //error
    NSError* error = nil;
    
    //status var
    // ->since want to keep trying
    BOOL bAnyErrors = NO;
    
    //path to prev. saved list of installed apps
    NSString* installedAppsFile = nil;
    
    //file for user approved bins
    NSString* approvedBinsFile = nil;
    
    //init path to save list of installed apps
    installedAppsFile = [DAEMON_DEST_FOLDER stringByAppendingPathComponent:INSTALLED_APPS];
    
    //when found
    // ->delete list of installed apps
    if(YES == [[NSFileManager defaultManager] fileExistsAtPath:installedAppsFile])
    {
        //delete
        if(YES != [[NSFileManager defaultManager] removeItemAtPath:installedAppsFile error:&error])
        {
            //set flag
            bAnyErrors = YES;
            
            //err msg
            printf("ERROR: failed to list of installed apps %s (%s)", installedAppsFile.UTF8String, error.description.UTF8String);
        }
    }
    
    //init path for where to save user approved binaries
    approvedBinsFile = [DAEMON_DEST_FOLDER stringByAppendingPathComponent:USER_APPROVED_BINARIES];
    
    //when found
    // ->delete list of 'user approved' apps
    if(YES == [[NSFileManager defaultManager] fileExistsAtPath:approvedBinsFile])
    {
        //delete
        if(YES != [[NSFileManager defaultManager] removeItemAtPath:approvedBinsFile error:&error])
        {
            //set flag
            bAnyErrors = YES;
            
            //err msg
            printf("ERROR: failed to list of approvedBinsFile apps %s (%s)\n", approvedBinsFile.UTF8String, error.description.UTF8String);
        }
    }
    
    //all good?
    if(YES != bAnyErrors)
    {
        //set flag
        fullReset = YES;
        
        //dbg msg
        printf("\nRANDSOMWHERE: reset\n\t      removed list of installed and all 'user approved' binaries\n\n");
    }

    return fullReset;
}

//init paths
// ->this logic will only be needed if daemon is executed from non-standard location
BOOL initPaths()
{
    //flag
    BOOL pathsInitd = NO;
    
    //error
    NSError* error = nil;
    
    //check if daemon's installation directory needs to be created
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:DAEMON_DEST_FOLDER])
    {
        //create it
        if(YES != [[NSFileManager defaultManager] createDirectoryAtPath:DAEMON_DEST_FOLDER withIntermediateDirectories:YES attributes:nil error:&error])
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to create daemon's directory %@ (%@)", DAEMON_DEST_FOLDER, error]);
            
            //bail
            goto bail;
        }
        
        //set group/owner to root/wheel
        if(YES != setFileOwner(DAEMON_DEST_FOLDER, @0, @0, YES))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to set daemon's directory %@ to be owned by root", DAEMON_DEST_FOLDER]);
            
            //bail
            goto bail;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"created %@", DAEMON_DEST_FOLDER]);
        #endif
    }
    
    //happy
    pathsInitd = YES;
    
//bail
bail:
    
    return pathsInitd;
}

//load list of apps installed at time of baseline
// ->first time; generate them (this might take a while)
BOOL processBaselinedApps()
{
    //flag
    BOOL wereProcessed = NO;
    
    //list of installed apps
    NSMutableArray* installedApps = nil;

    //path to prev. saved list of installed apps
    NSString* installedAppsFile = nil;
    
    //enumerated apps
    // ->array of detailed app dictionaries
    NSMutableArray* enumeratedApps = nil;
    
    //app bundle path
    NSString* appBundlePath = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //app path
    NSString* appPath = nil;
    
    //binary object
    Binary* binary = nil;
    
    //alloc set for installed apps
    installedApps = [NSMutableArray array];
    
    //init path to save list of installed apps
    installedAppsFile = [DAEMON_DEST_FOLDER stringByAppendingPathComponent:INSTALLED_APPS];
    
    //enumerate apps if necessary
    // ->done via system_profiler, w/ 'SPApplicationsDataType' flag (slow!)
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:installedAppsFile])
    {
        //enumerate
        enumeratedApps = enumerateInstalledApps();
        if( (nil == enumeratedApps) ||
            (0 == enumeratedApps.count) )
        {
            //err msg
            logMsg(LOG_ERR, @"failed to enumerate installed apps");
            
            //bail
            goto bail;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"enumerated all installed applications");
        #endif
        
        //process all enumerated apps
        // ->extract app path and load bundle to get full path
        for(NSDictionary* enumeratedApp in enumerateInstalledApps())
        {
            //grab path to app's bundle
            appBundlePath = [enumeratedApp objectForKey:@"path"];
            if(nil == appBundlePath)
            {
                //skip
                continue;
            }
            
            //load app bundle
            appBundle = [NSBundle bundleWithPath:appBundlePath];
            if(nil == appBundle)
            {
                //skip
                continue;
            }
            
            //grab full path to app's binary
            appPath = appBundle.executablePath;
            if(nil == appPath)
            {
                //skip
                continue;
            }
            
            //save
            [installedApps addObject:appPath];
        }
       
        //save to disk
        if(YES != [installedApps writeToFile:installedAppsFile atomically:NO])
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to save installed apps to %@", installedAppsFile]);
            
            //bail
            goto bail;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"saved list of installed apps to %@", installedAppsFile]);
        #endif
    }
    
    //already enumerated
    // ->load them from disk into memory
    else
    {
        //load
        installedApps = [NSMutableArray arrayWithContentsOfFile:installedAppsFile];
        if(nil == installedApps)
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to load installed apps from %@", installedAppsFile]);
            
            //bail
            goto bail;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"loaded list of installed apps from %@", installedAppsFile]);
        #endif
    }
    
    //iterate overall all installed apps
    // ->create binary objects for all, passing in 'baselined' flag
    for(NSString* appPath in installedApps)
    {
        //init binary object
        binary = [[Binary alloc] init:appPath attributes:@{@"baselined":[NSNumber numberWithBool:YES]}];
        
        //add to global list
        // ->path is key; object is value
        binaryList[binary.path] = binary;
    }
    
    //happy
    wereProcessed = YES;
    
//bail
bail:
    
    return wereProcessed;
}

//create binary objects for all (persistent) user-approved binaries
BOOL processApprovedBins()
{
    //flag
    BOOL wereProcessed = NO;
    
    //file for user approved bins
    NSString* approvedBinsFile = nil;
    
    //array for approved bins
    NSMutableArray* userApprovedBins = nil;
    
    //binary object
    Binary* binary = nil;
    
    //alloc set
    userApprovedBins = [NSMutableArray array];
    
    //init path for where to save user approved binaries
    approvedBinsFile = [DAEMON_DEST_FOLDER stringByAppendingPathComponent:USER_APPROVED_BINARIES];
    
    //bail if file doesn't exist yet
    // ->for example, first time daemon is run
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:approvedBinsFile])
    {
        //not an error though!
        wereProcessed = YES;
        
        //bail
        goto bail;
    }
    
    //load from disk
    userApprovedBins = [NSMutableArray arrayWithContentsOfFile:approvedBinsFile];
    if(nil == userApprovedBins)
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to loaded user approved binaries from %@", approvedBinsFile]);
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"loaded list of user approved binaries from %@", approvedBinsFile]);
    #endif
    
    //iterate overall all approved binaries
    // ->create binary objects for all, passing in 'approved' flag
    for(NSString* binaryPath in userApprovedBins)
    {
        //init binary object
        binary = [[Binary alloc] init:binaryPath attributes:@{@"approved":[NSNumber numberWithBool:YES]}];
        
        //add to global list
        // ->path is key; object is value
        binaryList[binary.path] = binary;
    }
    
    //happy
    wereProcessed = YES;
    
//bail
bail:
    
    return wereProcessed;
}

//create binary objects for all currently running processes
BOOL processRunningProcs()
{
    //flag
    BOOL wereProcessed = NO;
    
    //running processes
    NSMutableArray* runningProcesses = nil;
    
    //process path
    NSString* processPath = nil;
    
    //binary object
    Binary* binary = nil;
    
    //enumerate all running processes
    runningProcesses = enumerateProcesses();
    if( (nil == runningProcesses) ||
        (0 == runningProcesses.count) )
    {
        //err msg
        logMsg(LOG_ERR, @"failed to enumerate running processes");
        
        //bail
        goto bail;
    }
    
    //iterate over all running processes
    // ->create process obj & save into global list
    for(NSNumber* processID in runningProcesses)
    {
        //get process path from pid
        processPath = getProcessPath(processID.unsignedIntValue);
        if(nil == processPath)
        {
            //skip
            continue;
        }
        
        //skip existing binary objects
        // ->since existings ones will be baselined/approved, so don't want to overwrite
        if(nil != binaryList[processPath])
        {
            //skip
            continue;
        }
        
        //init binary object
        binary = [[Binary alloc] init:processPath attributes:nil];
        if(nil == binary)
        {
            //skip
            continue;
        }
        
        //add to global list
        // ->path is key; object is value
        binaryList[binary.path] = binary;
    }
    
    //happy
    wereProcessed = YES;
    
//bail
bail:
    
    return wereProcessed;
}
