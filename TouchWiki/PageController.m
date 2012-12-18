//
//  PageController.m
//  TouchWiki
//
//  Created by Jens Alfke on 12/15/12.
//  Copyright (c) 2012 Couchbase. All rights reserved.
//

#import "PageController.h"
#import "PageEditController.h"
#import "PageListController.h"
#import "AppDelegate.h"
#import "Wiki.h"
#import "WikiPage.h"
#import "GHMarkdownParser.h"

#define kFlipDuration 0.4
#define kFlipToEditAnimation UIViewAnimationOptionTransitionFlipFromLeft
#define kFlipToPreviewAnimation UIViewAnimationOptionTransitionFlipFromRight


static NSString *sHTMLPrefix, *sHTMLSuffix;
static NSRegularExpression* sWikiWordRegex;


@implementation PageController
{
    IBOutlet UITextField* _titleView;
    IBOutlet UIWebView* _webView;
    IBOutlet UIBarButtonItem* _backButton;
    IBOutlet UIBarButtonItem* _fwdButton;
    IBOutlet UIBarButtonItem* _editButton;
    IBOutlet UIBarButtonItem* _previewButton;
    IBOutlet UIBarButtonItem* _saveButton;

    Wiki* _wiki;
    PageEditController* _editController;
    UIPopoverController *_masterPopoverController;
    NSString* _pendingTitle;
    NSURL* _pendingURL;
}


+ (void) initialize {
    if (!sHTMLPrefix) {
        NSURL* url = [[NSBundle bundleForClass: self] URLForResource: @"PageTemplate" withExtension: @"html"];
        NSString* html = [NSString stringWithContentsOfURL: url encoding: NSUTF8StringEncoding error: nil];
        NSArray* parts = [html componentsSeparatedByString: @"{{BODY}}"];
        NSAssert(parts.count == 2, @"PageTemplate.html does not contain {{BODY}}");
        sHTMLPrefix = parts[0];
        sHTMLSuffix = parts[1];

        sWikiWordRegex = [NSRegularExpression regularExpressionWithPattern: @"\\[\\[([\\w ]+)\\]\\]"
                                                                   options: 0
                                                                     error: nil];
        NSAssert(sWikiWordRegex != nil, @"Bad regex");
    }
}


- (id)initWithWiki: (Wiki*)wiki {
    self = [super initWithNibName:@"PageController" bundle:nil];
    if (self) {
        _wiki = wiki;
    }
    return self;
}


- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = _editButton;
    [self.navigationItem setLeftBarButtonItems: @[_backButton, _fwdButton]];
    [self configureView];

    // Restore the current page:
    NSString* curPageID = [[NSUserDefaults standardUserDefaults] stringForKey: @"CurrentPageID"];
    if (curPageID) {
        self.page = [_wiki pageWithID: curPageID];
    }
}


- (void) setPage: (WikiPage*)newPage {
    NSLog(@"setPage: %@", newPage);
    if (_page != newPage) {
        [self hideEditor: self];

        [_page removeObserver: self forKeyPath: @"needsSave"];
        _page = newPage;
        [_page addObserver: self forKeyPath: @"needsSave" options: 0 context: NULL];
        [self configureView];

        [[NSUserDefaults standardUserDefaults] setObject: _page.document.documentID
                                                  forKey: @"CurrentPageID"];
    }
    [_masterPopoverController dismissPopoverAnimated:YES];
}


// Display the page in the UI.
- (void)configureView {
    [self loadContent];
    [self configureButtons];
}


- (void) configureButtons {
    (void)self.view; // make sure nib is loaded
    
    NSMutableArray* buttons = [NSMutableArray array];
    
    if (_editController) {
        [buttons addObject: _previewButton];
        _previewButton.title = _page.needsSave ? @"Preview" : @"Done";
    } else {
        [buttons addObject: _editButton];
    }
    
    if (_page.editing && _page.needsSave)
        [buttons addObject: _saveButton];

    [self.navigationItem setRightBarButtonItems: buttons animated: YES];
}


- (void) loadContent {
    self.title = _page ? _page.title : NSLocalizedString(@"No Page", @"No Page");
    _titleView.text = _page.title;

    NSMutableString* html = [sHTMLPrefix mutableCopy];

    if (_page.needsSave) {
        [html appendString: @"<div id='banner'>PREVIEW</div>\n"];
    }

    NSMutableString* markdown = _page.markdown.mutableCopy;
    if (markdown.length > 0) {
        // Markdown parsing:
        [sWikiWordRegex replaceMatchesInString: markdown options: 0
                                         range: NSMakeRange(0,markdown.length)
                                  withTemplate: @"[$1](wiki:$1)"];
        [html appendString: [GHMarkdownParser flavoredHTMLStringFromMarkdownString: markdown]];
    }
    [html appendString: sHTMLSuffix];
    [_webView loadHTMLString: html baseURL: nil];
    //NSLog(@"HTML = %@", html);
}


- (IBAction) showEditor: (id)sender {
    if (_editController)
        return;
    // Start editing:
    if (!_page.editing) {
        NSLog(@"*** EDITING '%@'", _page.title);
        _page.editing = YES;
    }
    
    _editController = [[PageEditController alloc] initWithPage: _page];
    [_editController willMoveToParentViewController: self];
    [self addChildViewController: _editController];

    [self configureButtons];

    [UIView transitionWithView: self.view
                      duration: kFlipDuration
                       options: kFlipToEditAnimation
                    animations: ^{ [self.view addSubview: _editController.view]; }
                    completion: nil];
}


- (IBAction) hideEditor: (id)sender {
    if (!_editController)
        return;
    
    if (_page.needsSave)
        [self loadContent];
    else
        _page.editing = NO;
    
    [_editController willMoveToParentViewController: nil];
    [_editController removeFromParentViewController];

    [UIView transitionWithView: self.view
                      duration: kFlipDuration
                       options: kFlipToPreviewAnimation
                    animations: ^{ [_editController.view removeFromSuperview]; }
                    completion: nil];

    _editController = nil;
    [self configureButtons];
}


- (IBAction) saveChanges: (id)sender {
    [_editController storeText];

    NSError* error;
    NSLog(@"Saving...");
    if (![_page save: &error]) {
        [gAppDelegate showAlert: @"Couldn't save page" error: error fatal: NO];
        return;
    }
    
    [self loadContent];
    [self hideEditor: nil];
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == _page) {
        [self configureButtons];
    }
}


#pragma mark - WEB VIEW


- (void) goToPageNamed: (NSString*)title {
    WikiPage* page = [_pageListController.wiki pageWithTitle: title];
    if (page)
        [_pageListController selectPage: page];
    else {
        _pendingTitle = title;
        NSString* message = [NSString stringWithFormat: @"There is no page named “%@”. "
                                                         "Do you want to create it?", title];
        UIAlertView* alert = [[UIAlertView alloc] initWithTitle: @"Create Page?"
                                                        message: message
                                                           delegate: self
                                                  cancelButtonTitle: @"Cancel"
                                                  otherButtonTitles: @"Create", nil];
        [alert show];
    }
}

- (void) goToExternalURL: (NSURL*)url {
    _pendingURL = url;
    NSString* message = @"This URL will open in another app. Do you want to open it?";
    UIAlertView* alert = [[UIAlertView alloc] initWithTitle: @"Open external URL?"
                                                    message: message
                                                   delegate: self
                                          cancelButtonTitle: @"Cancel"
                                          otherButtonTitles: @"Open", nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex <= 0)
        return;
    if (_pendingURL) {
        [[UIApplication sharedApplication] openURL: _pendingURL];
    } else {
        [_pageListController createPageWithTitle: _pendingTitle];
    }
    _pendingTitle = nil;
    _pendingURL = nil;
}


- (BOOL)webView:(UIWebView *)webView
        shouldStartLoadWithRequest:(NSURLRequest *)request
        navigationType:(UIWebViewNavigationType)navigationType
{
    if (navigationType != UIWebViewNavigationTypeLinkClicked)
        return YES;
    NSURL* url = request.URL;
    if ([url.scheme isEqualToString: @"wiki"]) {
        NSString* title = [url.resourceSpecifier stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
        NSLog(@"Link to '%@'", title);
        [self performSelector: @selector(goToPageNamed:) withObject: title afterDelay: 0.0];
    } else if ([[UIApplication sharedApplication] canOpenURL: url]) {
        [self performSelector: @selector(goToExternalURL:) withObject: url afterDelay: 0.0];
    }
    return NO;
}



#pragma mark - SPLIT VIEW


- (void)splitViewController:(UISplitViewController *)splitController
     willHideViewController:(UIViewController *)viewController
          withBarButtonItem:(UIBarButtonItem *)barButtonItem
       forPopoverController:(UIPopoverController *)popoverController
{
    (void)self.view; // ensure nib is loaded
    barButtonItem.title = NSLocalizedString(@"Pages", @"Pages");
    self.navigationItem.leftBarButtonItems = @[barButtonItem, _backButton, _fwdButton];
    _masterPopoverController = popoverController;
}

- (void)splitViewController:(UISplitViewController *)splitController
     willShowViewController:(UIViewController *)viewController
  invalidatingBarButtonItem:(UIBarButtonItem *)barButtonItem
{
    // Called when the view is shown again in the split view, invalidating the button and popover controller.
    (void)self.view; // ensure nib is loaded
    self.navigationItem.leftBarButtonItems = @[_backButton, _fwdButton];
    _masterPopoverController = nil;
}


@end