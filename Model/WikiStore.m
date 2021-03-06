//
//  WikiStore.m
//  TouchWiki
//
//  Created by Jens Alfke on 12/18/12.
//  Copyright (c) 2012 Couchbase. All rights reserved.
//

#import "WikiStore.h"
#import "Wiki.h"
#import "WikiPage.h"
#import <CouchbaseLite/CBLModelFactory.h>


static WikiStore* sInstance;


@implementation WikiStore
{
    NSString* _username;
}


- (id) initWithDatabase: (CBLDatabase*)database {
    self = [super init];
    if (self) {
        NSAssert(!sInstance, @"Cannot create more than one WikiStore");
        sInstance = self;
        _database = database;
        [_database.modelFactory registerClass: [Wiki class] forDocumentType: @"wiki"];
        [_database.modelFactory registerClass: [WikiPage class] forDocumentType: @"page"];

        // Map function for finding wikis by title
        CBLView* view = [_database viewNamed: @"wikisByTitle"];
        [view setMapBlock: MAPBLOCK({
            if ([doc[@"type"] isEqualToString: @"wiki"]) {
                NSString* title = doc[@"title"];
                if (title)
                    emit(title, nil);
            }
        }) reduceBlock: nil version: @"1"];
        _allWikisQuery = [[view createQuery] asLiveQuery];

        // Map function for finding pages by title
        [[_database viewNamed: @"pagesByTitle"] setMapBlock: MAPBLOCK({
            if ([doc[@"type"] isEqualToString: @"page"]) {
                NSString *wikiID;
                NSString *title;
                if ([WikiPage parseDocID: (doc[@"_id"]) intoWikiID: &wikiID andTitle: &title]) {
                    emit(@[wikiID, title], nil);
                }
            }
        }) reduceBlock: nil version: @"4"];

        // Filter for push replications, to avoid sending draft page revisions to the server.
        [_database setFilterNamed: @"notDraft"
                        asBlock: ^BOOL(CBLRevision *revision, NSDictionary *params) {
                            NSString* type = revision[@"type"];
                            if (!type)
                                return NO;
                            if ([type isEqualToString: @"page"])
                                return ![revision[@"draft"] boolValue];
                            return YES;
                        }];

        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(applicationWillTerminate:)
                                                     name:
#if TARGET_OS_IPHONE
                                                             UIApplicationWillTerminateNotification
#else
                                                             NSApplicationWillTerminateNotification
#endif
                                                   object: nil];
    }
    return self;
}


+ (WikiStore*) sharedInstance {
    return sInstance;
}


- (void) applicationWillTerminate: (NSNotification*)n {
    if (_database.unsavedModels.count) {
        NSLog(@"*** Saving unsaved models...");
        NSError* error;
        if (![_database saveAllModels: &error])
            NSLog(@"WARNING: Failed to save pages: %@", error);
    }
}


- (NSString*) username {
    //FIX: This would be better stored in a _local document in the database
    return [[NSUserDefaults standardUserDefaults] stringForKey: @"UserName"];
}


- (void) setUsername:(NSString *)username {
    NSLog(@"Setting wiki username to '%@'", username);
    [[NSUserDefaults standardUserDefaults] setObject: username forKey: @"UserName"];
}


- (Wiki*) wikiWithTitle: (NSString*)title {
    for (CBLQueryRow* row in _allWikisQuery.rows) {
        if ([row.key isEqualToString: title])
            return [Wiki modelForDocument: row.document];
    }
    return nil;
}


- (Wiki*) newWikiWithTitle: (NSString*)title {
    return [[Wiki alloc] initNewWithTitle: title inWikiStore: self];
}


- (WikiPage*) pageWithID: (NSString*)pageID {
    CBLDocument* doc = [self.database documentWithID: pageID];
    if (!doc.currentRevisionID)
        return nil;
    return [WikiPage modelForDocument: doc];
}


@end
