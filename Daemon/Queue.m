//
//  Queue.m
//  RansomWhere
//
//  Created by Patrick Wardle on 9/26/14.
//  Copyright (c) 2016 Objective-See. All rights reserved.
//

#import "main.h"
#import "Event.h"
#import "Queue.h"
#import "Consts.h"
#import "Binary.h"
#import "Logging.h"
#import "Utilities.h"


@implementation Queue

@synthesize icon;
@synthesize eventQueue;
@synthesize reportedProcs;
@synthesize queueCondition;
@synthesize disallowedProcs;
@synthesize lastEncryptedFiles;

//init
// ->alloc & queue thead
-(id)init
{
    //init super
    self = [super init];
    if(nil != self)
    {
        //init queue
        eventQueue = [NSMutableArray array];
 
        //init empty condition
        queueCondition = [[NSCondition alloc] init];
 
        //alloc for 'user-disallowed' processes
        disallowedProcs = [NSMutableDictionary dictionary];
        
        //alloc set for reported proces
        reportedProcs = [NSMutableSet set];
        
        //alloc dictionary to pid -> last encrypted file timestamp
        lastEncryptedFiles = [NSMutableDictionary dictionary];
        
        //init path to icon
        icon = [NSURL URLWithString:[DAEMON_DEST_FOLDER stringByAppendingPathComponent:ALERT_ICON]];
    
        //kick off thread to watch/process items placed in queue
        [NSThread detachNewThreadSelector:@selector(dequeue:) toTarget:self withObject:nil];
    }
    
    return self;
}

//add an object to the queue
-(void)enqueue:(id)anObject
{
    //lock
    [self.queueCondition lock];
    
    //add to queue
    [self.eventQueue enqueue:anObject];
    
    //signal
    [self.queueCondition signal];
    
    //unlock
    [self.queueCondition unlock];
    
    return;
}

//dequeue
// ->forever, process events from queue
-(void)dequeue:(id)threadParam
{
    //watch event
    Event* event = nil;

    //for ever
    while(YES)
    {
        //pool
        @autoreleasepool {
            
        //lock queue
        [self.queueCondition lock];
        
        //wait while queue is empty
        while(YES == [self.eventQueue empty])
        {
            //wait
            [self.queueCondition wait];
        }
        
        //item is in queue!
        // ->grab it, then process
        event = [eventQueue dequeue];
            
        //unlock
        [self.queueCondition unlock];
            
        //dispatch to process event async'd
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        ^{
            [self processEvent:event];
        });
        
        }//pool
        
    }//loop: foreverz process queue
        
    return;
}

//thread method
// ->process event off queue
-(void)processEvent:(Event*)event
{
    //response
    CFOptionFlags response = 0;
    
    //last encrypted file
    NSMutableDictionary* lastEncryptedFile = nil;
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, [NSString stringWithFormat:@"processing queued event: %@", event]);
    #endif
    
    //SKIP
    // ->events generated by OS X apps (signed by Apple proper)
    if(YES == event.binary.isApple)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: is Apple binary");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"0) is not Apple binary");
    #endif

    //SKIP
    // ->events generated by apps baselined/prev. installed apps
    if(YES == event.binary.isBaseline)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: is installed/baselined app");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"1) is not installed/baselined app");
    #endif
    
    //SKIP
    // ->events generated by 'user-allowed' binaries
    if(YES == event.binary.isApproved)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: is allowed binary");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"2) is from non-allowed binary");
    #endif
    
    //sync
    @synchronized(self.disallowedProcs)
    {
    
    //SKIP
    // ->events generated by disallowed processes
    //  since a disallowed process is only set once user has killed (meaning such events are 'stale' and the proc is dead)
    if(YES == [self.disallowedProcs[event.processID] isEqualToString:event.binary.path])
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: is disallowed process");
        #endif
        
        //bail
        goto bail;
    }
    
    }//sync
        
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"3) is from non-disallowed process");
    #endif
    
    //SKIP
    // ->files under 1024, as entropy calculations don't do well on smaller files
    if([[[NSFileManager defaultManager] attributesOfItemAtPath:event.filePath error:nil] fileSize] < 1024)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"ignoring: small file (%llu bytes)", [[[NSFileManager defaultManager] attributesOfItemAtPath:event.filePath error:nil] fileSize]]);
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"4) is large enough");
    #endif
    
    //SKIP
    // ->any non-encrypted files (also ignores image files)
    if(YES != isEncrypted(event.filePath))
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: is not encrypted");
        #endif
        
        //bail
        goto bail;
    }
    
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"5) is encrypted");
    #endif
    
    //sync
    @synchronized (self.lastEncryptedFiles)
    {
        
    //grab this processes' last encrypted file
    lastEncryptedFile = self.lastEncryptedFiles[event.processID];
        
    //always update/replace timestamp and file
    self.lastEncryptedFiles[event.processID] = @{@"timestamp":[NSDate date], @"path":event.filePath};
        
    }//sync
    
    //when its new, add timestamp and file
    // ->then ignore, cuz want at least 2 encrypted files to trigger)
    if(nil == lastEncryptedFile)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: first encrypted file for process");
        #endif
        
        //first encrypted file
        // ->so ignore proc for now
        goto bail;
    }
    //ok, second (or more) encrypted file for process
    // ->check timestamp & path to make sure its recent enough and a new file
    else
    {
        //ignore when file just the same
        if(YES == [lastEncryptedFile[@"path"] isEqualToString:event.filePath])
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"ignoring: (re)encrypting same file");
            #endif
            
            //ignore
            goto bail;
        }
        
        //ignore when file is older than 5 seconds
        if([lastEncryptedFile[@"timestamp"] timeIntervalSinceNow] > 5)
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"ignoring: previously encrypted file(s) for process, too long ago");
            #endif
            
            //ignore
            goto bail;
        }
    }

    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"6) was encrypted by process that's quickly encrypting a bunch of files");
    #endif
    
    //SKIP
    // ->if user has logged out, ignore
    if(NULL == consoleUserName)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"ignoring: not user logged in");
        #endif
        
        //skip
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"suspending process and alerting user!");
    #endif
    
    //suspend process
    // ->terminated, or resumed depending on user's response
    if(-1 == kill(event.processID.intValue, SIGSTOP))
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to suspend %@ (%@), with %d", event.processID, event.binary.path, errno]);
        
        //bail
        goto bail;
    }
    
    //sycn & report
    @synchronized(self.reportedProcs)
    {
        //ignore already reported procs
        if(YES == [self.reportedProcs containsObject:event.processID])
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"ignoring process that was already reported");
            #endif
            
            //bail
            goto bail;
        }
        
        //add it as (about to) report
        [self.reportedProcs addObject:event.processID];
        
        //alert user
        // ->note: will block until user responsed
        response = [self alertUser:event prevEncryptedFile:lastEncryptedFile[@"path"]];
        
        //handle response
        // ->either resume or terminate process
        [self processResponse:event response:response];
        
    } //sync

//bail
bail:
    
    return;
}

//show alert to the user
// ->block until response, which is returned from this method
-(CFOptionFlags)alertUser:(Event*)event prevEncryptedFile:(NSString*)prevEncryptedFile
{
    //user's response
    CFOptionFlags response = 0;
    
    //header
    CFStringRef title = NULL;
    
    //body
    CFStringRef body = NULL;
    
    //init title
    title = (__bridge CFStringRef)([NSString stringWithFormat:@"%@ is 🔒'ing files!", [event.binary.path lastPathComponent]]);
   
    //init body
    body = (__bridge CFStringRef)([NSString stringWithFormat:@"proc:\t%@ (%d)\r\nfiles:\t%@\r\n\t%@...", event.binary.path, event.processID.unsignedIntValue, prevEncryptedFile, event.filePath]);
    
    //show alert
    // ->will block until user interaction, then response saved in 'response' variable
    CFUserNotificationDisplayAlert(0.0f, kCFUserNotificationStopAlertLevel, (CFURLRef)self.icon, NULL, NULL, title, body, (__bridge CFStringRef)@"Terminate", (__bridge CFStringRef)@"Allow", NULL, &response);
    
//bail
bail:
    
    return response;
}

//handle response
// ->either resume or terminate process
-(void)processResponse:(Event*)event response:(CFOptionFlags)response
{
    //approved apps plist
    NSString* approvedAppsPlist = nil;
    
    //array of approved apps from file
    NSMutableArray* approvedApps = nil;
    
    //terminate process
    if(PROCESS_TERMINATE == response)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"user responded with: terminated");
        #endif
        
        //terminate
        if(-1 == kill(event.processID.intValue, SIGKILL))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to kill %@ (%@), with %d", event.processID, event.binary.path, errno]);
            
            //bail
            goto bail;
        }
        
        //sync to add
        @synchronized(self.disallowedProcs)
        {
            //add to 'disallowed' procs set
            self.disallowedProcs[event.processID] = event.binary.path;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"terminated process");
        #endif
    }
    
    //resume process
    else
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"user responded with: resume (allow)");
        #endif
        
        //resume process
        if(-1 == kill(event.processID.intValue, SIGCONT))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to resume %@ (%@), with %d", event.processID, event.binary.path, errno]);
            
            //bail
            goto bail;
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"resumed process");
        #endif
        
        //update binary object
        event.binary.isApproved = YES;
        
        //init path to approved apps
        approvedAppsPlist = [DAEMON_DEST_FOLDER stringByAppendingPathComponent:USER_APPROVED_BINARIES];
        
        //append to approved file
        approvedApps = [NSMutableArray arrayWithContentsOfFile:approvedAppsPlist];
      
        //not found (first approved app?)
        // ->initialize array to add binary
        if(nil == approvedApps)
        {
            //init
            approvedApps = [NSMutableArray array];
        }
        
        //add if new one
        if(YES != [approvedApps containsObject:event.binary.path])
        {
            //add
            [approvedApps addObject:event.binary.path];
        }
        
        //write out atomically
        [approvedApps writeToFile:approvedAppsPlist atomically:YES];
        
         //dbg msg
         #ifdef DEBUG
         logMsg(LOG_DEBUG, [NSString stringWithFormat:@"updated persistent list of user approved apps (%@)", approvedAppsPlist]);
         #endif
    }
    
//bail
bail:
 
    return;
}


@end
