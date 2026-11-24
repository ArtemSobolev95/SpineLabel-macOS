//
//  SpineLabelFilter.h — SpineLabel plugin for IsiX DICOM Viewer and Horos
//  Copyright (c) 2026 Artem Sobolev. BSD 3-Clause licence (see LICENSE).
//

#import <Foundation/Foundation.h>
#import "PluginFilter.h"

@interface SpineLabelFilter : PluginFilter
- (long) filterImage:(NSString*) menuName;
@end
