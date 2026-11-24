//
//  SpineLabelFilter.m — SpineLabel plugin for IsiX DICOM Viewer and Horos
//  Copyright (c) 2026 Artem Sobolev. BSD 3-Clause licence (see LICENSE).
//

#import "SpineLabelFilter.h"
#import "SpineLabelController.h"

@implementation SpineLabelFilter

- (void) initPlugin
{
    // Start listening for viewers that open a study with saved labels.
    [SpineLabelController sharedController];
}

- (long) filterImage:(NSString*) menuName
{
    [[SpineLabelController sharedController] showForViewer:viewerController];
    return 0;
}

@end
