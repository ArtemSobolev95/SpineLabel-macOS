//
//  SpineLabelController.h — SpineLabel plugin for IsiX DICOM Viewer and Horos
//
//  Semi-automatic vertebra labelling, in the manner of the OsiriX MD "Spine Labeling" plugin:
//  draw a line from the highest to the lowest disc of the region on a sagittal (or coronal)
//  image, adjust the points the plugin puts on it so each sits on a disc, and apply. Every
//  open series of the study then shows the levels: vertebral labels beside the bodies on
//  sagittal and coronal images, and the vertebra or disc level on each axial slice. The disc
//  positions are kept per study, so series opened later are labelled too.
//
//  Copyright (c) 2026 Artem Sobolev. BSD 3-Clause licence (see LICENSE).
//

#import <Cocoa/Cocoa.h>

@class ViewerController;

@interface SpineLabelController : NSObject <NSWindowDelegate>

+ (SpineLabelController *)sharedController;
- (void)showForViewer:(ViewerController *)viewer;

@end
