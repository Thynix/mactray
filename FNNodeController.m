/* 
    Copyright (C) 2015 Stephen Oliver <steve@infincia.com>
    Copyright (C) 2013 Richard King <richy@wiredupandfiredup.com>

    This code is distributed under the GNU General Public License, version 2 
    (or at your option any later version).
    
    3rd party libraries may be distributed under an alternate Open Source license.
    
    See the LICENSE file included with this code for details.
    
*/

#import "FNNodeController.h"

#import "FNFCPWrapper.h"

#import "FNHelpers.h"

#import "FNConfigParser.h"

#import "MHWDirectoryWatcher.h"

@interface FNNodeController()
@property FNFCPWrapper *fcpWrapper;
@property MHWDirectoryWatcher *configWatcher;
@end

@implementation FNNodeController
@dynamic nodeLocation;
 
- (instancetype)init {
    self = [super init];
    if (self) {
        self.currentNodeState = FNNodeStateUnknown;
        self.fcpWrapper = [[FNFCPWrapper alloc] init];
        self.fcpWrapper.delegate = self;
        self.fcpWrapper.dataSource = self;
        [self.fcpWrapper nodeStateLoop];
        // spawn a thread to keep the node status indicator updated in realtime. The method called here cannot be run again while this thread is running
        [NSThread detachNewThreadSelector:@selector(checkNodeStatus) toTarget:self withObject:nil];
    }
    return self;
}

#pragma mark - Dynamic properties

-(NSURL *)nodeLocation {
    NSString *storedNodePath = [[[NSUserDefaults standardUserDefaults] objectForKey:FNNodeInstallationDirectoryKey] stringByStandardizingPath];
    NSURL *storedInstallationURL = nil;
    if (storedNodePath != nil) {
        storedInstallationURL = [NSURL fileURLWithPath:storedNodePath];
    }
    return storedInstallationURL;
}

-(void)setNodeLocation:(NSURL *)nodeLocation {
    [self.configWatcher stopWatching];
    
    NSString *nodePath = [nodeLocation.path stringByStandardizingPath];
    if (nodePath != nil) {
        [[NSUserDefaults standardUserDefaults] setObject:nodePath forKey:FNNodeInstallationDirectoryKey];
        self.configWatcher = [MHWDirectoryWatcher directoryWatcherAtPath:nodePath callback:^{
            [self readFreenetConfig];
        }];
        [self.configWatcher startWatching];
    }
    else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:FNNodeInstallationDirectoryKey];
    }
    [self readFreenetConfig];
}

#pragma mark - Node handling

- (void)checkNodeStatus {

    // start a continuous loop to set the status indicator, this whole method (checkNodeStatus) should be started from a separate thread so it doesn't block main app
    while (1) {
        @autoreleasepool {
            
            NSURL *anchorFile = [self.nodeLocation URLByAppendingPathComponent:FNNodeAnchorFilePathname];
            if (![FNHelpers validateNodeInstallationAtURL:self.nodeLocation]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.currentNodeState = FNNodeStateUnknown;
                    [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeStateUnknownNotification object:nil];
                });
            }
            //if the anchor file exists, the node should be running.
            else if ([[NSFileManager defaultManager] fileExistsAtPath:anchorFile.path]) {
            /* 
                If we find the anchor file we we send an FNNodeStateRunningNotification 
                event and save the node state here.
                
                This can be a false positive, the node may be stopped even if 
                this file exists, but normally it should be accurate.
            */
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.currentNodeState = FNNodeStateRunning;
                    [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeStateRunningNotification object:nil];
                });
            }
            else {
                /* 
                    Otherwise we send a FNNodeStateNotRunningNotification event and
                    save the node state here.
                 
                    This should be 100% accurate, the node won't run without that 
                    anchor file being present
                */
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.currentNodeState = FNNodeStateNotRunning;
                    [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeStateNotRunningNotification object:nil];
                });
            }
        }
        [NSThread sleepForTimeInterval:FNNodeCheckTimeInterval]; 
    }
}

- (void)startFreenet {
    NSString *storedNodePath = [[[NSUserDefaults standardUserDefaults] objectForKey:FNNodeInstallationDirectoryKey] stringByStandardizingPath];
    NSURL *nodeLocation;
    if (storedNodePath != nil) {
        nodeLocation = [NSURL fileURLWithPath:storedNodePath];
    }
    if ([FNHelpers validateNodeInstallationAtURL:nodeLocation]) {
        NSURL *runScript = [nodeLocation URLByAppendingPathComponent:FNNodeRunscriptPathname];
        [NSTask launchedTaskWithLaunchPath:runScript.path arguments:@[@"start"]];       
    }
    else {
        [FNHelpers displayNodeMissingAlert];
    }
}

- (void)stopFreenet {
    NSString *storedNodePath = [[[NSUserDefaults standardUserDefaults] objectForKey:FNNodeInstallationDirectoryKey] stringByStandardizingPath];
    NSURL *nodeLocation;
    if (storedNodePath != nil) {
        nodeLocation = [NSURL fileURLWithPath:storedNodePath];
    }
    if ([FNHelpers validateNodeInstallationAtURL:nodeLocation]) {
        NSURL *runScript = [nodeLocation URLByAppendingPathComponent:FNNodeRunscriptPathname];
        [NSTask launchedTaskWithLaunchPath:runScript.path arguments:@[@"stop"]];       
    }
    else {
        [FNHelpers displayNodeMissingAlert];
    }
}

#pragma mark - Configuration handlers

-(void)readFreenetConfig {
    if ([FNHelpers validateNodeInstallationAtURL:self.nodeLocation]) {
        NSURL *wrapperConfigFile = [self.nodeLocation URLByAppendingPathComponent:FNNodeWrapperConfigFilePathname];
        self.wrapperConfig = [FNConfigParser dictionaryFromWrapperConfigFile:wrapperConfigFile];
        
        NSURL *freenetConfigFile = [self.nodeLocation URLByAppendingPathComponent:FNNodeFreenetConfigFilePathname];    
        self.freenetConfig = [FNConfigParser dictionaryFromWrapperConfigFile:freenetConfigFile];
        
        NSArray *fcpBindings = [self.freenetConfig[FNNodeFreenetConfigFCPBindAddressesKey] componentsSeparatedByString:@","];
        if (fcpBindings.count > 0) {
            NSString *fcpBindTo = fcpBindings[0]; // first one should be ipv4
            NSString *fcpPort = self.freenetConfig[FNNodeFreenetConfigFCPPortKey];
            self.fcpLocation = [NSURL URLWithString:[NSString stringWithFormat:@"tcp://%@:%@", fcpBindTo, fcpPort]];
        }
        
        NSArray *fproxyBindings = [self.freenetConfig[FNNodeFreenetConfigFProxyBindAddressesKey] componentsSeparatedByString:@","];
        if (fproxyBindings.count > 0) {
            NSString *fproxyBindTo = fproxyBindings[0]; // first one should be ipv4
            NSString *fproxyPort = self.freenetConfig[FNNodeFreenetConfigFProxyPortKey];
            self.fproxyLocation = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@", fproxyBindTo, fproxyPort]];
        }
        
        BOOL isDirectory;
        NSString *downloadsPath = self.freenetConfig[FNNodeFreenetConfigDownloadsDirKey];
        if ([[NSFileManager defaultManager] fileExistsAtPath:downloadsPath isDirectory:&isDirectory] && isDirectory) {
            self.downloadsFolder = [NSURL fileURLWithPath:downloadsPath isDirectory:YES];
        }
        else if (downloadsPath != nil) {
            // node.downloadsDir isn't a full path, so probably relative to the node files
            self.downloadsFolder = [self.nodeLocation URLByAppendingPathComponent:downloadsPath isDirectory:YES];
        }
        else {
            // last resort, freenet.ini doesn't have a node.downloadsDir key, use a sane temporary default
            self.downloadsFolder = [self.nodeLocation URLByAppendingPathComponent:@"downloads" isDirectory:YES];
        }
    }
}

#pragma mark - FNFCPWrapperDelegate methods

-(void)didDisconnect {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeFCPDisconnectedNotification object:nil];
    });

}

-(void)didReceiveNodeHello:(NSDictionary *)nodeHello {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeHelloReceivedNotification object:nodeHello];
    });
}

-(void)didReceiveNodeStats:(NSDictionary *)nodeStats {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FNNodeStatsReceivedNotification object:nodeStats];
    });
}

#pragma mark - FNFCPWrapperDataSource methods

-(NSURL *)nodeFCPURL {
    return self.fcpLocation;
}

@end
