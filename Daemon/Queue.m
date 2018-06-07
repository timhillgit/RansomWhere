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
@synthesize queueCondition;


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
 
        //init path to icon
        icon = [NSURL URLWithString:[DAEMON_DEST_FOLDER stringByAppendingPathComponent:ALERT_ICON]];
    
        //kick off thread to watch/process items placed in queue
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        ^{
            //dequeue forever
            [self dequeue];
        });
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
-(void)dequeue
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
            
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"processing queued event: %@", event]);
        #endif
            
        //do basic/quick checks on event
        if(YES != [self shouldFullyProcess:event])
        {
            //next!
            continue;
        }
           
        //basic checks say 'keep processing'
        // ->dispatch to complete processing of event
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        ^{
            [self processEvent:event];
        });
        
        }//pool
        
    }//loop: foreverz process queue
        
    return;
}

//basic (read: quick) checks on event
-(BOOL)shouldFullyProcess:(Event*)event
{
    //flag
    BOOL fullyProcess = NO;
    
    //SKIP:
    // ->if user has logged out, ignore
    if(NULL == consoleUserName)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: no user logged in, sorry!");
        #endif
        
        //skip
        goto bail;
    }
    
    //SKIP:
    // ->always skip whitelisted 3rd-party apps
    if(YES == event.process.binary.isWhiteListed)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is whitelist'd 3rd-party binary");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED  CHECK 0: binary is not whitelisted binary");
    #endif
    
    //SKIP:
    // ->events generated by OS X apps
    //   ...unless gray-listed (which only applies to Apple apps)
    //      or has untrusted parent (i.e. zip being exec'd by malware)
    if( (YES == event.process.binary.isApple) &&
        (YES != event.process.binary.isGrayListed) &&
        (nil == event.process.untrustedAncestor) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is Apple binary (that's also not graylisted/doesn't have untrusted ancestor)");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 1: is not Apple binary (or is, but is graylisted/untrusted ancestor)");
    #endif
    
    //SKIP:
    // ->events generated by apps from the App Store
    if(YES == event.process.binary.isAppStore)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is App Store binary");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 2: is not App Store binary");
    #endif
    
    //SKIP:
    // ->events generated by apps baselined/prev installed apps
    //   unless they are graylisted or have untrusted ancestor
    if( (YES == event.process.binary.isBaseline) &&
        (YES != event.process.binary.isGrayListed) &&
        (nil == event.process.untrustedAncestor) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is installed/baselined app (that's also not graylisted/doesn't have untrusted ancestor)");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 3: is not installed/baselined app (or is, but is graylisted/untrusted ancestor)");
    #endif
    
    //SKIP:
    // ->events generated by 'user-allowed' binaries
    if(YES == event.process.binary.isApproved)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is user approved/allowed binary");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 4: is from non-allowed binary");
    #endif
    
    //SKIP:
    // ->events generated by processes that were already reported
    //   might just be 'stale' events (from a process that was killed)
    if(YES == event.process.wasReported)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: previously reported process");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 5: is from non-reported process");
    #endif
    
    //SKIP:
    // ->files under 1024, as entropy calculations don't do well on smaller files
    if([[[NSFileManager defaultManager] attributesOfItemAtPath:event.filePath error:nil] fileSize] < 1024)
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, [NSString stringWithFormat:@"IGNORING: small file (%llu bytes)", [[[NSFileManager defaultManager] attributesOfItemAtPath:event.filePath error:nil] fileSize]]);
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 6: is large enough");
    #endif
    
    //ok, should do more complex processing
    fullyProcess = YES;
    
//bail
bail:
    
    return fullyProcess;
}

//thread method
// ->process event off queue
-(void)processEvent:(Event*)event
{
    //response
    CFOptionFlags response = 0;
    
    //hit encrypted file limit
    BOOL hitLimit = NO;
    
    //ancestor hit encryted file limit
    BOOL ancestorHitLimit = NO;
    
    //SKIP:
    // ->any files that aren't encrypted
    //  note: check first if event is generated by encryption util
    if( (YES != [self isEncryptionUtility:event]) &&
        (YES != isEncrypted(event.filePath)) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: is not encrypted/nor encryption util");
        #endif
        
        //bail
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 7: is encrypted/is encryption util");
    #endif
    
    //sync to add encrypted file
    @synchronized (event.process.encryptedFiles)
    {
        //add
        event.process.encryptedFiles[event.filePath] = [NSDate date];
    }

    //process hit limit?
    hitLimit = [event.process hitEncryptedTheshold];
    
    //process has untrusted ancestor?
    // ->also add into ancestor's list and then check limit
    if(nil != event.process.untrustedAncestor)
    {
        //save
        event.process.untrustedAncestor.encryptedFiles[event.filePath] = [NSDate date];
        
        //hit limit?
        ancestorHitLimit = [event.process.untrustedAncestor hitEncryptedTheshold];
    }
    
    //SKIP
    // ->process that haven't hit encryption theshold
    //   or processes with untrusted ancestor that hasn't hit limit
    if( (YES != hitLimit) &&
        (YES != ancestorHitLimit) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"IGNORING: process (and any untrusted ancestor) hasn't encrypted enough files quickly enough");
        #endif
        
        //ignore
        goto bail;
    }
    
    //dbg msg
    #ifdef DEBUG
    logMsg(LOG_DEBUG, @"PASSED CHECK 8: was encrypted by process that's quickly encrypting a bunch of files");
    #endif
    
    //sync to prevent multiple report on same process
    @synchronized(self)
    {
        
    //suspend process that hit the limit
    // ->check this before ancestor hit limit
    if(YES == hitLimit)
    {
        //ignore if already reported
        if(YES == event.process.wasReported)
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"IGNORING: process that was already reported, so ignoring");
            #endif
            
            //ignore
            goto bail;
        }
        
        //dbg msg(s)
        // ->always show
        syslog(LOG_ERR, "%s", [NSString stringWithFormat:@"OBJECTIVE-SEE RANSOMWHERE?: %@ is quickly creating encrypted files", event.process.binary.path].UTF8String);
        syslog(LOG_ERR, "OBJECTIVE-SEE RANSOMWHERE?: suspending and alerting user");
        
        //suspend
        if(-1 == kill(event.process.pid, SIGSTOP))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to suspend %d (%@), with %d", event.process.pid, event.process.binary.path, errno]);
            
            //bail
            goto bail;
        }
    }
    //when ancestor the reason for triggering a limit
    // ->suspend it & kids (as kids will be the ones encrypting)
    else if(YES == ancestorHitLimit)
    {
        //ignore if already reported
        if(YES == event.process.untrustedAncestor.wasReported)
        {
            //dbg msg
            #ifdef DEBUG
            logMsg(LOG_DEBUG, @"IGNORING: process that was already reported, so ignoring");
            #endif
            
            //ignore
            goto bail;
        }
        
        //dbg msg(s)
        // ->always show
        syslog(LOG_ERR, "%s", [NSString stringWithFormat:@"OBJECTIVE-SEE RANSOMWHERE?: %@ (ancestor of %@) has childen quickly creating encrypted files", event.process.untrustedAncestor.binary.path, event.process.binary.path].UTF8String);
        syslog(LOG_ERR, "OBJECTIVE-SEE RANSOMWHERE?: suspending and alerting user");
        
        //set flag
        event.ancestorTriggered = YES;
        
        //suspend ancestor & kids
        [self sendSignalToAll:event signal:SIGSTOP];
    }
    
    //alert user
    // ->note: call will *block* until user respondes
    response = [self alertUser:event];
    
    //set process reported flag
    if(YES != event.ancestorTriggered)
    {
        //set flag
        event.process.wasReported  = YES;
    }
    //set ancestor reported flag
    else
    {
        //set flag
        event.process.untrustedAncestor.wasReported = YES;
    }
        
    //handle response
    // ->either resume or terminate process
    [self processResponse:event response:response];
        
    }//sync

//bail
bail:
    
    return;
}

//determine if process is a known encryption utility (zip -P, openssl enc, etc)
// that is creating encrypted files (can check arguments)
-(BOOL)isEncryptionUtility:(Event*)event
{
    //flag
    BOOL encryptionUtil = NO;
    
    //ingore if not apple
    if(YES != event.process.binary.isApple)
    {
        //bail
        goto bail;
    }
    
    //is zip?
    // ->running w/ '-P' cmdline option?
    if( (YES == [event.process.binary.signingInfo[KEY_SIGNATURE_IDENTIFIER] isEqualToString:ZIP_IDENTIFIER]) &&
        (YES == [event.process.arguments containsObject:@"-P"]) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"detected 'zip' creating encrypted file");
        #endif
        
        //is zip w/ -P
        encryptionUtil = YES;
        
        //all done
        goto bail;
    }
    
    //is openssl?
    // ->running w/ 'enc' cmdline option?
    if( (YES == [event.process.binary.signingInfo[KEY_SIGNATURE_IDENTIFIER] isEqualToString:OPENSSL_IDENTIFIER]) &&
        (YES == [event.process.arguments containsObject:@"enc"]) )
    {
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"detected 'openssl' creating encrypted file");
        #endif
        
        //is openssl w/ enc
        encryptionUtil = YES;
        
        //all done
        goto bail;
    }
    
//bail
bail:

    return encryptionUtil;
}

//show alert to the user
// ->block until response, which is returned from this method
-(CFOptionFlags)alertUser:(Event*)event
{
    //user's response
    CFOptionFlags response = 0;
    
    //header
    NSString* title = NULL;
    
    //body
    NSMutableString* body = NULL;
    
    //process that triggered
    Process* process = nil;
    
    //signing info
    NSString* signingInfo = nil;
    
    //encrypted file
    NSArray* encryptedFiles = nil;
    
    //set process for non-ancestor
    if(YES != event.ancestorTriggered)
    {
        //set
        process = event.process;
        
        //init title
        title = [NSString stringWithFormat:@"%@ is 🔒'ing files!", [process.binary.path lastPathComponent]];
    }
    //set process as ancestor
    else
    {
        //set
        process = event.process.untrustedAncestor;
        
        //init title
        title = [NSString stringWithFormat:@"%@'s kids are 🔒'ing files!", [process.path lastPathComponent]];
    }
    
    //format signing info
    signingInfo = [process.binary formatSigningInfo];
    
    //start body
    body = [NSMutableString stringWithFormat:@"proc: (%d) %@\r\nsign: %@\r\n", process.pid, process.binary.path, signingInfo];
    
    //spacing
    [body appendFormat:@"\r\n"];
    
    //get files
    encryptedFiles = process.encryptedFiles.allKeys;
    
    //add first file
    [body appendFormat:@"files:\r\n › %@", encryptedFiles[0]];
    
    //add next if it's there
    if(encryptedFiles.count >= 2)
    {
        //append
        [body appendFormat:@"\r\n › %@", encryptedFiles[1]];
    }
    
    //show alert
    // ->will *block* until user interaction, then response saved in 'response' variable
    CFUserNotificationDisplayAlert(0.0f, kCFUserNotificationStopAlertLevel, (CFURLRef)self.icon, NULL, NULL, (__bridge CFStringRef)title, (__bridge CFStringRef)body, (__bridge CFStringRef)@"Terminate", (__bridge CFStringRef)@"Allow", NULL, &response);
    
bail:
    
    return response;
}

//handle response
// ->either resume or terminate process
-(void)processResponse:(Event*)event response:(CFOptionFlags)response
{
    //process that triggered
    Process* process = nil;

    //set process as either child or ancestor
    process = (YES == event.ancestorTriggered) ? event.process.untrustedAncestor : event.process;
    
    //terminate process
    if(PROCESS_TERMINATE == response)
    {
        //dbg msg
        // ->always show
        syslog(LOG_ERR, "OBJECTIVE-SEE RANSOMWHERE?: user responded with 'terminate'");
        
        //kill
        if(-1 == kill(process.pid, SIGKILL))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to kill %d (%@), with %d", process.pid, process.binary.path, errno]);
            
            //bail
            goto bail;
        }
        
        //if ancestor is to blame
        // ->kill any kids as well
        if(YES == event.ancestorTriggered)
        {
            //kill kids
            [self sendSignalToAll:event signal:SIGKILL];
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"terminated process");
        #endif
    }
    
    //resume process
    // ->also add to allowed proc (unless it's an apple proc, with untrusted ancestor)
    else
    {
        //dbg msg
        // ->always show
        syslog(LOG_ERR, "OBJECTIVE-SEE RANSOMWHERE?: user responded with 'resume' (allow)");
        
        //set flag
        process.binary.isApproved = YES;
        
        //allowed process w/ untrusted ancestor
        // ->reset the ancestor's encryption file count
        if(nil != event.process.untrustedAncestor)
        {
            //sync to reset
            @synchronized (event.process.untrustedAncestor.encryptedFiles)
            {
                //reset
                [event.process.untrustedAncestor.encryptedFiles removeAllObjects];
            }
        }
        
        //resume process
        if(-1 == kill(process.pid, SIGCONT))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to resume %d (%@), with %d", event.process.pid, event.process.binary.path, errno]);
            
            //bail
            goto bail;
        }
        
        //white list process
        [whitelist updateApproved:event.process.binary];
        
        //if ancestor was flagged
        // ->resume any kids and also approve ancestor
        if(YES == event.ancestorTriggered)
        {
            //resume kids
            [self sendSignalToAll:event signal:SIGCONT];
            
            //whitelist ancestor
            [whitelist updateApproved:event.process.binary];
        }
        
        //dbg msg
        #ifdef DEBUG
        logMsg(LOG_DEBUG, @"resumed process(es)");
        #endif
    }
    
//bail
bail:
 
    return;
}

//suspend, terminate, or resume all kids up to an ancestor
-(void)sendSignalToAll:(Event*)event signal:(int)signal
{
    //signal bottom child
    if(-1 == kill(event.process.pid, signal))
    {
        //err msg
        logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to %d child %d (%@), (errno: %d)", signal, event.process.pid, event.process.binary.path, errno]);
    }
    
    //singal everything else up to and including ancestor
    for(NSNumber* ancestor in event.process.ancestors)
    {
        //signal
        if(-1 == kill(ancestor.unsignedShortValue, signal))
        {
            //err msg
            logMsg(LOG_ERR, [NSString stringWithFormat:@"failed to %d child %@ (errno: %d)", signal, ancestor, errno]);
        }
        
        //bail when untrusted ancestor is reached
        if(ancestor.unsignedShortValue == event.process.untrustedAncestor.pid)
        {
            //done
            break;
        }
    }
}


@end
