//
//  Control.h
//  BlockBlock
//
//  Created by Patrick Wardle on 11/23/14.
//  Copyright (c) 2015 Objective-See. All rights reserved.
//

#ifndef BlockBlock_Control_h
#define BlockBlock_Control_h

@interface Control : NSObject
{

    /* IVARS */
    
    //PID of (auth'd) self 
    pid_t authPID;
    
}

//PID
@property pid_t authPID;


/* METHODS */

//install or uninstall
//-(BOOL)lifeCycle:(NSUInteger)action;

//control a launch item
// ->either load/unload the launch daemon/agent(s)
-(BOOL)controlLaunchItem:(NSUInteger)itemType plist:(NSString*)plist action:(NSString*)action;

//start the launch daemon
-(BOOL)startDaemon;

//start the launch agent(s)
-(BOOL)startAgent:(NSString*)plist;

//stop the launch daemon
-(BOOL)stopDaemon;

//stop the launch agent
-(BOOL)stopAgent:(NSString*)plist;

//wait till the instance of the (auth'd) self exists
-(BOOL)waitTillPau;

//spawns auth'd instance of installer/uninstaller
// ->then wait till it exits
-(BOOL)execControlInstance:(NSString*)parameter;

@end

#endif
