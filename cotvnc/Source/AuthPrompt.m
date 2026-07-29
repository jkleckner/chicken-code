/* AuthPrompt.m
 * Copyright (C) 2011 Dustin Cartwright
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 */

#import <AuthPrompt.h>

@implementation AuthPrompt

- (id)initWithDelegate:(id<AuthPromptDelegate>)aDelegate
{
    if (self = [super init]) {
        delegate = aDelegate;
        NSArray *topLevel = nil;
        if (![[NSBundle mainBundle] loadNibNamed:@"AuthPrompt"
                                           owner:self
                                 topLevelObjects:&topLevel]) {
            NSLog(@"Could not load the AuthPrompt nib");
            [self release];
            return nil;
        }
        _nibTopLevelObjects = [topLevel retain];
    }
    return self;
}

- (void)dealloc
{
    [_nibTopLevelObjects release];
    [super dealloc];
}

- (void)runSheetOnWindow:(NSWindow *)window
{
    /* Balanced by the -autorelease in the handler: the prompt has to outlive
     * this method, and nothing else owns it while the sheet is up. */
    [self retain];
    [window beginSheet:panel completionHandler:^(NSModalResponse returnCode) {
        [panel orderOut:self];
        [self autorelease];
    }];
}

- (void)stopSheet
{
    [[panel sheetParent] endSheet:panel];
}

- (IBAction)enterPassword:(id)sender
{
    [delegate authPasswordEntered:[passwordField stringValue]];
    [[panel sheetParent] endSheet:panel];
}

- (IBAction)cancel:(id)sender
{
    [[panel sheetParent] endSheet:panel];
    [delegate authCancelled];
}

@end
