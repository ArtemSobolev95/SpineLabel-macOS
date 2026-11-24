//
//  SpineLabelController.m — SpineLabel plugin for IsiX DICOM Viewer and Horos
//  Copyright (c) 2026 Artem Sobolev. BSD 3-Clause licence (see LICENSE).
//
//  Compiled with ARC.
//

#import "SpineLabelController.h"
#import "ViewerController.h"
#if __has_include("ViewerController+ROI.h")      // IsiX keeps the ROI methods in a category
#import "ViewerController+ROI.h"
#endif
#import "DCMPix.h"
#import "DCMView.h"
#import "ROI.h"
#import "MyPoint.h"
#import "Notifications.h"

// The plugin's own ROIs. A text ROI shows its comments as a second line, so they are not marked
// there: labels are locked text ROIs whose text is a spine level, previews are the green ones,
// and the disc polygon is an open polygon with this name.
static NSString *const SLTagLabel   = @"label";
static NSString *const SLTagDiscs   = @"discs";
static NSString *const SLTagPreview = @"preview";
static NSString *const SLDiscPolygonName = @"Spine discs";

static BOOL SLIsLevelName(NSString *s)
{
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[CTLS][0-9]{1,2}(/[CTLS][0-9]{1,2})?$" options:0 error:NULL];
    });
    return s && [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, [s length])] == 1;
}

// Which of the plugin's kinds an ROI is (nil: not the plugin's).
static NSString *SLKindOf(ROI *r)
{
    if ([r type] == tOPolygon && [[r name] isEqualToString:SLDiscPolygonName]) return SLTagDiscs;
    if ([r type] == tText && [r locked] && SLIsLevelName([r name])) {
        RGBColor c = [r rgbcolor];
        return (c.red == 0 && c.green == 65535 && c.blue == 0) ? SLTagPreview : SLTagLabel;
    }
    return nil;
}

static NSString *const SLKeyLabelDiscs = @"SpineLabelDiscLevelsOnAxial";
static NSString *const SLKeyLongitudinal = @"SpineLabelOnSagittalCoronal";
static NSString *const SLKeyAuto = @"SpineLabelAutoApply";
static NSString *const SLKeyThoracic = @"SpineLabelThoracicCount";
static NSString *const SLKeyLumbar = @"SpineLabelLumbarCount";
static NSString *const SLKeyAnchor = @"SpineLabelAnchorLowest";   // YES: the known disc is the lowest one

#pragma mark - Geometry

typedef struct { double x, y, z; } SLVec;

static inline SLVec SLMake(double x, double y, double z) { SLVec v = {x, y, z}; return v; }
static inline SLVec SLAdd(SLVec a, SLVec b) { return SLMake(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline SLVec SLSub(SLVec a, SLVec b) { return SLMake(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline SLVec SLScale(SLVec a, double s) { return SLMake(a.x * s, a.y * s, a.z * s); }
static inline double SLDot(SLVec a, SLVec b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline double SLNorm(SLVec a) { return sqrt(SLDot(a, a)); }
static inline SLVec SLLerp(SLVec a, SLVec b, double t) { return SLAdd(a, SLScale(SLSub(b, a), t)); }

// The plane and pixel grid of one image. ROI coordinates are pixels whose centres sit at +0.5.
typedef struct { SLVec origin, row, col, normal; double sx, sy; long w, h; } SLPlane;

static SLPlane SLPlaneOf(DCMPix *pix)
{
    SLPlane p;
    double o[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    [pix orientationDouble:o];
    p.origin = SLMake([pix originX], [pix originY], [pix originZ]);
    p.row = SLMake(o[0], o[1], o[2]);
    p.col = SLMake(o[3], o[4], o[5]);
    p.normal = SLMake(o[6], o[7], o[8]);
    p.sx = [pix pixelSpacingX] > 0 ? [pix pixelSpacingX] : 1.0;
    p.sy = [pix pixelSpacingY] > 0 ? [pix pixelSpacingY] : 1.0;
    p.w = [pix pwidth];
    p.h = [pix pheight];
    return p;
}

static SLVec SLPixelTo3D(SLPlane p, NSPoint pt)
{
    return SLAdd(p.origin, SLAdd(SLScale(p.row, (pt.x - 0.5) * p.sx), SLScale(p.col, (pt.y - 0.5) * p.sy)));
}

// Pixel position of a 3D point projected onto the image, and its signed distance from the plane.
static NSPoint SL3DToPixel(SLPlane p, SLVec v, double *distance)
{
    SLVec d = SLSub(v, p.origin);
    if (distance) *distance = SLDot(d, p.normal);
    return NSMakePoint(SLDot(d, p.row) / p.sx + 0.5, SLDot(d, p.col) / p.sy + 0.5);
}

static BOOL SLInside(SLPlane p, NSPoint pt)
{
    return pt.x >= 0 && pt.y >= 0 && pt.x < p.w && pt.y < p.h;
}

// A direction in the image plane, `mm` long, in which a label is moved away from the spine:
// anterior when that lies in the plane (sagittal, axial), otherwise to the patient's right.
static SLVec SLLabelOffset(SLPlane p, double mm)
{
    SLVec candidates[2] = {SLMake(0, -1, 0), SLMake(-1, 0, 0)};   // LPS: anterior, right
    for (int i = 0; i < 2; i++) {
        SLVec c = candidates[i];
        SLVec inPlane = SLSub(c, SLScale(p.normal, SLDot(c, p.normal)));
        double n = SLNorm(inPlane);
        if (n > 0.5) return SLScale(inPlane, mm / n);
    }
    return SLScale(p.row, mm);
}

static inline SLVec SLCross(SLVec a, SLVec b)
{
    return SLMake(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

// In-plane offset at right angles to the local spine direction (tangent), on the side of the
// usual offset (anterior, else patient right). A fixed anterior offset would slide the label
// along a tilted spine (kyphosis, lordosis) towards a disc.
static SLVec SLLabelOffsetAcross(SLPlane p, SLVec tangent, double mm)
{
    SLVec usual = SLLabelOffset(p, mm);
    SLVec t = SLSub(tangent, SLScale(p.normal, SLDot(tangent, p.normal)));   // tangent within the image
    if (SLNorm(t) < 1e-6) return usual;
    SLVec across = SLCross(p.normal, t);
    double n = SLNorm(across);
    if (n < 1e-6) return usual;
    across = SLScale(across, mm / n);
    return SLDot(across, usual) < 0 ? SLScale(across, -1) : across;
}

#pragma mark - Level names

// Vertebrae from C1 to S1, with the chosen numbers of thoracic and lumbar vertebrae.
static NSArray *SLVertebraNames(NSInteger thoracic, NSInteger lumbar)
{
    NSMutableArray *names = [NSMutableArray array];
    for (int i = 1; i <= 7; i++) [names addObject:[NSString stringWithFormat:@"C%d", i]];
    for (int i = 1; i <= thoracic; i++) [names addObject:[NSString stringWithFormat:@"T%d", i]];
    for (int i = 1; i <= lumbar; i++) [names addObject:[NSString stringWithFormat:@"L%d", i]];
    [names addObject:@"S1"];
    return names;
}

// Discs from C2/C3 to the lumbosacral disc: disc i lies between vertebrae i+1 and i+2 of the list above.
static NSArray *SLDiscNames(NSArray *vertebrae)
{
    NSMutableArray *discs = [NSMutableArray array];
    for (NSUInteger i = 1; i + 1 < [vertebrae count]; i++)
        [discs addObject:[NSString stringWithFormat:@"%@/%@", vertebrae[i], vertebrae[i + 1]]];
    return discs;
}

#pragma mark - Controller

@interface SpineLabelController ()
@property (strong) ViewerController *viewer;       // the viewer the panel works on
@property (strong) NSPanel *panel;
@property (strong) NSPopUpButton *anchorPopup, *discPopup, *thoracicPopup, *lumbarPopup;
@property (strong) NSButton *discLevelsBox, *longitudinalBox, *autoBox;
@property (strong) NSTextField *viewerLabel, *statusLabel;
@property (assign) BOOL updatingPreview, previewPending, waitingForPolygon;
@end

@implementation SpineLabelController

+ (SpineLabelController *)sharedController
{
    static SpineLabelController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[SpineLabelController alloc] init]; });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{SLKeyLabelDiscs: @YES, SLKeyLongitudinal: @YES,
                                                                 SLKeyAuto: @YES, SLKeyThoracic: @12, SLKeyLumbar: @5, SLKeyAnchor: @YES}];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(viewerLoaded:) name:OsirixViewerControllerDidLoadImagesNotification object:nil];
        [nc addObserver:self selector:@selector(viewerLoaded:) name:OsirixViewerDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(viewerClosed:) name:OsirixCloseViewerNotification object:nil];
        [nc addObserver:self selector:@selector(roiChanged:) name:OsirixROIChangeNotification object:nil];
        [nc addObserver:self selector:@selector(roiAdded:) name:OsirixAddROINotification object:nil];
    }
    return self;
}

#pragma mark Study identity and storage

- (NSString *)studyUIDOf:(ViewerController *)v
{
    @try {
        NSArray *files = [v fileList];
        if ([files count]) {
            id uid = [[files objectAtIndex:0] valueForKeyPath:@"series.study.studyInstanceUID"];
            if ([uid isKindOfClass:[NSString class]] && [uid length]) return uid;
        }
    } @catch (NSException *e) {}
    return nil;
}

- (NSString *)frameOfReferenceOf:(ViewerController *)v
{
    NSArray *pixList = [v pixList:0];
    return [pixList count] ? [[pixList objectAtIndex:0] frameofReferenceUID] : nil;
}

- (NSString *)storageFolder
{
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject]
                     stringByAppendingPathComponent:@"SpineLabel"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

- (NSString *)modelPathForStudy:(NSString *)uid
{
    if (!uid) return nil;
    NSString *safe = [[uid componentsSeparatedByCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]]
                      componentsJoinedByString:@"_"];
    return [[self storageFolder] stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"json"]];
}

- (NSDictionary *)modelForStudy:(NSString *)uid
{
    NSString *path = [self modelPathForStudy:uid];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) return nil;
    id model = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [model isKindOfClass:[NSDictionary class]] ? model : nil;
}

- (void)saveModel:(NSDictionary *)model forStudy:(NSString *)uid
{
    NSString *path = [self modelPathForStudy:uid];
    NSData *data = [NSJSONSerialization dataWithJSONObject:model options:NSJSONWritingPrettyPrinted error:NULL];
    if (path && data) [data writeToFile:path atomically:YES];
}

#pragma mark Panel

static NSTextField *SLLabel(NSString *s)
{
    NSTextField *f = [NSTextField wrappingLabelWithString:s];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return f;
}

static NSPopUpButton *SLPopup(id target, SEL action)
{
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [p setControlSize:NSControlSizeSmall];
    [p setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [p setTarget:target];
    [p setAction:action];
    return p;
}

static NSButton *SLButton(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    [b setControlSize:NSControlSizeSmall];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return b;
}

static NSButton *SLCheck(NSString *title, NSString *key, id target)
{
    NSButton *b = [NSButton checkboxWithTitle:title target:target action:@selector(optionChanged:)];
    [b setControlSize:NSControlSizeSmall];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [b setState:[[NSUserDefaults standardUserDefaults] boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff];
    return b;
}

static NSStackView *SLRow(NSArray *views)
{
    NSStackView *s = [NSStackView stackViewWithViews:views];
    [s setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [s setSpacing:6];
    return s;
}

- (void)buildPanel
{
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 400)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered defer:NO];
    [self.panel setTitle:@"Spine Labeling"];
    [self.panel setFloatingPanel:YES];
    [self.panel setLevel:NSFloatingWindowLevel];
    [self.panel setHidesOnDeactivate:NO];
    [self.panel setReleasedWhenClosed:NO];
    [self.panel setDelegate:self];

    self.viewerLabel = SLLabel(@"");
    [self.viewerLabel setFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];

    self.thoracicPopup = SLPopup(self, @selector(variantChanged:));
    [self.thoracicPopup addItemsWithTitles:@[@"11", @"12", @"13"]];
    [self.thoracicPopup selectItemWithTitle:[[[NSUserDefaults standardUserDefaults] objectForKey:SLKeyThoracic] description]];
    self.lumbarPopup = SLPopup(self, @selector(variantChanged:));
    [self.lumbarPopup addItemsWithTitles:@[@"4", @"5", @"6"]];
    [self.lumbarPopup selectItemWithTitle:[[[NSUserDefaults standardUserDefaults] objectForKey:SLKeyLumbar] description]];

    self.anchorPopup = SLPopup(self, @selector(anchorChanged:));
    [self.anchorPopup addItemsWithTitles:@[@"Highest disc is", @"Lowest disc is"]];
    [self.anchorPopup selectItemAtIndex:[[NSUserDefaults standardUserDefaults] boolForKey:SLKeyAnchor] ? 1 : 0];
    self.discPopup = SLPopup(self, @selector(levelsChanged:));
    [self fillDiscPopupsKeeping:NO];

    self.discLevelsBox = SLCheck(@"Show disc levels on axial images (e.g. L4/L5)", SLKeyLabelDiscs, self);
    self.longitudinalBox = SLCheck(@"Label vertebrae on sagittal and coronal images", SLKeyLongitudinal, self);
    self.autoBox = SLCheck(@"Label series of this study opened later", SLKeyAuto, self);

    self.statusLabel = SLLabel(@"");
    [self.statusLabel setTextColor:[NSColor secondaryLabelColor]];

    NSTextField *steps = SLLabel(@"1. Choose one disc you can identify (e.g. the lowest, L5/S1) below.\n"
                                 @"2. Click “Place Disc Points”, then on a sagittal (or coronal) image click the centre of each disc, "
                                 @"top to bottom or bottom to top. Double-click the last disc to finish.\n"
                                 @"3. Check the names next to the points; drag a point to correct it.\n"
                                 @"4. Click “Apply Labels”: every open series of the study is labelled.");
    [steps setPreferredMaxLayoutWidth:350];

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        self.viewerLabel,
        steps,
        SLRow(@[self.anchorPopup, self.discPopup]),
        SLRow(@[SLLabel(@"Thoracic vertebrae:"), self.thoracicPopup, SLLabel(@"Lumbar:"), self.lumbarPopup]),
        SLRow(@[SLButton(@"Place Disc Points", self, @selector(placeDiscPoints:)),
                SLButton(@"Apply Labels", self, @selector(applyLabels:))]),
        self.discLevelsBox, self.longitudinalBox, self.autoBox,
        SLRow(@[SLButton(@"Edit Discs", self, @selector(editDiscs:)),
                SLButton(@"Label Open Series", self, @selector(relabelOpenSeries:)),
                SLButton(@"Remove Labels", self, @selector(removeLabels:))]),
        self.statusLabel]];
    [stack setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [stack setAlignment:NSLayoutAttributeLeading];
    [stack setSpacing:8];
    [stack setEdgeInsets:NSEdgeInsetsMake(12, 14, 12, 14)];
    [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
    NSView *content = [self.panel contentView];
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [stack.widthAnchor constraintEqualToConstant:380]]];
}

- (NSArray *)vertebraNames
{
    return SLVertebraNames([[self.thoracicPopup titleOfSelectedItem] integerValue] ?: 12,
                           [[self.lumbarPopup titleOfSelectedItem] integerValue] ?: 5);
}

- (BOOL)anchorIsLowest
{
    return [self.anchorPopup indexOfSelectedItem] == 1;
}

- (void)fillDiscPopupsKeeping:(BOOL)keep
{
    NSString *current = keep ? [self.discPopup titleOfSelectedItem] : nil;
    NSArray *discs = SLDiscNames([self vertebraNames]);
    [self.discPopup removeAllItems];
    [self.discPopup addItemsWithTitles:discs];
    if (current && [self.discPopup itemWithTitle:current]) { [self.discPopup selectItemWithTitle:current]; return; }
    if ([self anchorIsLowest]) { [self.discPopup selectItemWithTitle:[discs lastObject]]; return; }   // L5/S1
    NSUInteger l1 = [discs indexOfObjectPassingTest:^BOOL(NSString *d, NSUInteger i, BOOL *stop) { return [d hasPrefix:@"L1/"]; }];
    if (l1 != NSNotFound && l1 > 0) [self.discPopup selectItemAtIndex:(NSInteger)l1 - 1];             // T12/L1
}

// Index (in the disc list) of the highest of n clicked discs, from the known disc.
- (NSInteger)topIndexForCount:(NSInteger)n
{
    NSInteger known = [self.discPopup indexOfSelectedItem];
    return [self anchorIsLowest] ? known - (n - 1) : known;
}

// Shows the known disc of a saved model in the popups.
- (void)selectDiscsOfModel:(NSArray *)names
{
    if (![names count]) return;
    [self.discPopup selectItemWithTitle:[self anchorIsLowest] ? [names lastObject] : [names firstObject]];
}

- (void)anchorChanged:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool:[self anchorIsLowest] forKey:SLKeyAnchor];
    [self updatePreview];
}

- (void)showForViewer:(ViewerController *)viewer
{
    if (!self.panel) [self buildPanel];
    self.viewer = viewer;
    NSString *uid = [self studyUIDOf:viewer];
    NSDictionary *model = [self modelForStudy:uid];
    if (model) {   // restore the study's variant and levels
        [self.thoracicPopup selectItemWithTitle:[model[@"thoracic"] description]];
        [self.lumbarPopup selectItemWithTitle:[model[@"lumbar"] description]];
        [self fillDiscPopupsKeeping:NO];
        [self selectDiscsOfModel:model[@"discNames"]];
    }
    [self.viewerLabel setStringValue:[NSString stringWithFormat:@"Viewer: %@", [[viewer window] title] ?: @"—"]];
    [self setStatus:model ? @"This study already has labels. “Edit Discs” puts its disc points back on the current image."
                          : @"Choose the known disc, then click “Place Disc Points”."];
    if (![self.panel isVisible]) {
        NSRect vf = [[viewer window] frame];
        [self.panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(vf) - NSWidth([self.panel frame]) - 20, NSMaxY(vf) - 60)];
    }
    [self.panel orderFront:nil];
}

- (void)setStatus:(NSString *)s
{
    [self.statusLabel setStringValue:s ?: @""];
}

- (void)optionChanged:(NSButton *)sender
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:[self.discLevelsBox state] == NSControlStateValueOn forKey:SLKeyLabelDiscs];
    [d setBool:[self.longitudinalBox state] == NSControlStateValueOn forKey:SLKeyLongitudinal];
    [d setBool:[self.autoBox state] == NSControlStateValueOn forKey:SLKeyAuto];
}

- (void)variantChanged:(id)sender
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:[[self.thoracicPopup titleOfSelectedItem] integerValue] forKey:SLKeyThoracic];
    [d setInteger:[[self.lumbarPopup titleOfSelectedItem] integerValue] forKey:SLKeyLumbar];
    [self fillDiscPopupsKeeping:YES];
    [self updatePreview];
}

- (void)levelsChanged:(id)sender
{
    [self updatePreview];
}

- (void)viewerClosed:(NSNotification *)note
{
    if ([note object] == self.viewer) {
        self.viewer = nil;
        [self.panel orderOut:nil];
    }
}

#pragma mark ROIs on the current image

- (NSMutableArray *)roisOfCurrentImage:(ViewerController *)v
{
    short movie = [v curMovieIndex];
    long slice = [[v imageView] curImage];
    NSArray *perSlice = [v roiList:movie];
    return (slice >= 0 && slice < (long)[perSlice count]) ? [perSlice objectAtIndex:slice] : nil;
}

- (DCMPix *)currentPix:(ViewerController *)v
{
    NSArray *pixList = [v pixList:[v curMovieIndex]];
    long slice = [[v imageView] curImage];
    return (slice >= 0 && slice < (long)[pixList count]) ? [pixList objectAtIndex:slice] : nil;
}

- (ROI *)discPolygonIn:(NSArray *)rois
{
    ROI *any = nil;
    for (ROI *r in rois) {
        if ([r type] != tOPolygon) continue;
        if (SLKindOf(r) == SLTagDiscs) return r;
        if (!any || [r ROImode] == ROI_selected || [r ROImode] == ROI_selectedModify) any = r;
    }
    return any;
}

- (ROI *)newROI:(ToolMode)type onPix:(DCMPix *)pix viewer:(ViewerController *)v
{
    ROI *roi = [[ROI alloc] initWithType:type :[pix pixelSpacingX] :[pix pixelSpacingY] :NSMakePoint([pix originX], [pix originY])];
    [roi setPix:pix];
    [roi setCurView:[v imageView]];
    return roi;
}

- (ROI *)newText:(NSString *)text at:(NSPoint)pt pix:(DCMPix *)pix viewer:(ViewerController *)v tag:(NSString *)tag color:(RGBColor)color
{
    ROI *roi = [self newROI:tText onPix:pix viewer:v];
    [roi setROIRect:NSMakeRect(pt.x, pt.y, 0, 0)];   // first: the name sets the text's frame size
    [roi setName:text];
    [roi setColor:color];
    [roi setLocked:YES];
    return roi;
}

// Removes ROIs from a slice's list without freeing them during the removal. IsiX frees an ROI as
// soon as the list lets go of it, and the freed ROI's notification makes the viewer walk that same
// list, still being changed: a crash. The ROIs are kept until the list change is complete and
// released on the next pass of the run loop.
static void SLRemoveFromList(NSMutableArray *rois, NSIndexSet *idx)
{
    if (![idx count]) return;
    NSArray *removed = [rois objectsAtIndexes:idx];
    [rois removeObjectsAtIndexes:idx];
    dispatch_async(dispatch_get_main_queue(), ^{ (void)[removed count]; });
}

- (void)removeROIsTagged:(NSArray *)tags fromList:(NSMutableArray *)rois
{
    NSIndexSet *idx = [rois indexesOfObjectsPassingTest:^BOOL(ROI *r, NSUInteger i, BOOL *stop) {
        NSString *kind = SLKindOf(r);
        return kind && [tags containsObject:kind];
    }];
    SLRemoveFromList(rois, idx);
}

#pragma mark Step 2: points on the discs

- (void)placeDiscPoints:(id)sender
{
    ViewerController *v = self.viewer;
    NSMutableArray *rois = v ? [self roisOfCurrentImage:v] : nil;
    if (!rois) { [self setStatus:@"Open a series first."]; return; }

    // An open polygon already drawn on this image (not yet the plugin's) is used as it is.
    ROI *drawn = nil;
    for (ROI *r in rois)
        if ([r type] == tOPolygon && SLKindOf(r) != SLTagDiscs && [[r points] count] >= 2) drawn = r;
    if (drawn) { [self adoptPolygon:drawn]; return; }

    self.waitingForPolygon = YES;
    [v setROIToolTag:tOPolygon];
    [[v window] makeKeyAndOrderFront:nil];
    [self setStatus:@"Click the centre of each disc, top to bottom or bottom to top. Double-click the last disc to finish."];
}

// Makes a user-drawn open polygon the disc polygon. Not called from inside an ROI notification:
// the viewer may be walking the ROI list then.
- (void)adoptPolygon:(ROI *)poly
{
    ViewerController *v = self.viewer;
    self.waitingForPolygon = NO;
    if (!v || !poly) return;
    NSMutableArray *list = nil;
    for (NSMutableArray *rois in [v roiList:[v curMovieIndex]])
        if ([rois indexOfObjectIdenticalTo:poly] != NSNotFound) { list = rois; break; }
    if (!list) return;
    [self removeROIsTagged:@[SLTagDiscs, SLTagPreview] fromList:list];   // an earlier disc polygon on this image
    [poly setName:SLDiscPolygonName];
    RGBColor green = {0, 65535, 0};
    [poly setColor:green];
    [self updatePreview];
    [v needsDisplayUpdate];
    [self followDrawing:poly count:[[poly points] count]];
    [self setStatus:@"Check the disc names next to the points (drag a point to correct it), then click “Apply Labels”."];
}

// While the polygon is still being drawn, the names follow the new points (the viewer does not
// report every click).
- (void)followDrawing:(ROI *)poly count:(NSUInteger)lastCount
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (SLKindOf(poly) != SLTagDiscs || !self.viewer) return;
        BOOL present = NO;
        for (NSArray *rois in [self.viewer roiList:[self.viewer curMovieIndex]])
            if ([rois indexOfObjectIdenticalTo:poly] != NSNotFound) { present = YES; break; }
        if (!present) return;
        NSUInteger n = [[poly points] count];
        if (n != lastCount) [self updatePreview];
        if ([poly ROImode] == ROI_drawing) [self followDrawing:poly count:n];
        else [self updatePreview];
    });
}

- (void)roiAdded:(NSNotification *)note
{
    if (!self.waitingForPolygon) return;
    ROI *roi = [[note userInfo] objectForKey:@"ROI"];
    if (![roi isKindOfClass:[ROI class]]) roi = [note object];
    [self considerNewPolygon:roi];
}

- (void)considerNewPolygon:(ROI *)roi
{
    if (!self.waitingForPolygon || ![roi isKindOfClass:[ROI class]] || [roi type] != tOPolygon || SLKindOf(roi) == SLTagDiscs) return;
    if (self.viewer && [roi curView] && [roi curView] != [self.viewer imageView]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.waitingForPolygon) [self adoptPolygon:roi];
    });
}

// Disc names next to the polygon's points while it is edited.
- (void)updatePreview
{
    ViewerController *v = self.viewer;
    if (!v || self.updatingPreview) return;
    self.updatingPreview = YES;
    NSArray *perSlice = [v roiList:[v curMovieIndex]];
    NSArray *pixList = [v pixList:[v curMovieIndex]];
    NSArray *discNames = SLDiscNames([self vertebraNames]);
    RGBColor green = {0, 65535, 0};
    for (NSUInteger s = 0; s < [perSlice count] && s < [pixList count]; s++) {
        NSMutableArray *rois = [perSlice objectAtIndex:s];
        ROI *poly = nil;
        for (ROI *r in rois) if (SLKindOf(r) == SLTagDiscs) { poly = r; break; }
        NSMutableArray *previews = [NSMutableArray array];
        for (ROI *r in rois) if (SLKindOf(r) == SLTagPreview) [previews addObject:r];
        if (!poly && ![previews count]) continue;
        DCMPix *pix = [pixList objectAtIndex:s];
        NSArray *pts = poly ? [self orderedPoints:poly pix:pix] : @[];
        NSInteger top = [self topIndexForCount:(NSInteger)[pts count]];
        if ([pts count] && [pts count] == [previews count]) {
            // Same number of points: move the existing names. The slice's list is not changed,
            // so nothing the viewer may be walking (e.g. while a point is dragged) goes away.
            for (NSUInteger i = 0; i < [pts count]; i++) {
                NSInteger d = top + (NSInteger)i;
                NSString *name = (d >= 0 && d < (NSInteger)[discNames count]) ? discNames[d] : @"?";
                NSPoint p = [pts[i] pointValue];
                ROI *t = previews[i];
                [t setROIRect:NSMakeRect(p.x + 6.0 / pix.pixelSpacingX + 2, p.y, 0, 0)];
                if (![[t name] isEqualToString:name]) [t setName:name];
            }
            continue;
        }
        [self removeROIsTagged:@[SLTagPreview] fromList:rois];
        for (NSUInteger i = 0; i < [pts count]; i++) {
            NSInteger d = top + (NSInteger)i;
            NSString *name = (d >= 0 && d < (NSInteger)[discNames count]) ? discNames[d] : @"?";
            NSPoint p = [pts[i] pointValue];
            [rois addObject:[self newText:name at:NSMakePoint(p.x + 6.0 / pix.pixelSpacingX + 2, p.y) pix:pix viewer:v tag:SLTagPreview color:green]];
        }
    }
    [v needsDisplayUpdate];
    self.updatingPreview = NO;
}

- (void)roiChanged:(NSNotification *)note
{
    ROI *roi = [note object];
    if (self.updatingPreview || ![roi isKindOfClass:[ROI class]]) return;
    if (self.waitingForPolygon) { [self considerNewPolygon:roi]; return; }
    if (SLKindOf(roi) != SLTagDiscs || self.previewPending) return;
    // Never change ROI lists inside the notification: it arrives while the viewer is walking its
    // ROI list (dragging a point), and changing that list then crashes IsiX. Update afterwards,
    // once per burst of changes.
    self.previewPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.previewPending = NO;
        [self updatePreview];
    });
}

// The polygon's points from the highest to the lowest (by patient z).
- (NSArray *)orderedPoints:(ROI *)poly pix:(DCMPix *)pix
{
    NSMutableArray *pts = [NSMutableArray array];
    // A double-click that ends the polygon can leave a second point on the last disc: points less
    // than 3 mm from the previous one are dropped.
    double sx = [pix pixelSpacingX] > 0 ? [pix pixelSpacingX] : 1, sy = [pix pixelSpacingY] > 0 ? [pix pixelSpacingY] : 1;
    for (MyPoint *p in [poly points]) {
        NSPoint q = [p point], last = [[pts lastObject] pointValue];
        if ([pts count] && hypot((q.x - last.x) * sx, (q.y - last.y) * sy) < 3.0) continue;
        [pts addObject:[NSValue valueWithPoint:q]];
    }
    if ([pts count] >= 2) {
        SLPlane plane = SLPlaneOf(pix);
        if (SLPixelTo3D(plane, [pts[0] pointValue]).z < SLPixelTo3D(plane, [[pts lastObject] pointValue]).z)
            pts = [[[pts reverseObjectEnumerator] allObjects] mutableCopy];
    }
    return pts;
}

#pragma mark Step 4: apply

- (void)applyLabels:(id)sender
{
    ViewerController *v = self.viewer;
    if (!v) { [self setStatus:@"Open a series first."]; return; }
    NSArray *perSlice = [v roiList:[v curMovieIndex]];
    NSArray *pixList = [v pixList:[v curMovieIndex]];

    // The disc polygon: on the current image, else anywhere in the series.
    ROI *poly = [self discPolygonIn:[self roisOfCurrentImage:v]];
    DCMPix *pix = poly ? [self currentPix:v] : nil;
    NSMutableArray *polyList = poly ? [self roisOfCurrentImage:v] : nil;
    for (NSUInteger s = 0; !poly && s < [perSlice count] && s < [pixList count]; s++) {
        ROI *r = [self discPolygonIn:[perSlice objectAtIndex:s]];
        if (r) { poly = r; pix = [pixList objectAtIndex:s]; polyList = [perSlice objectAtIndex:s]; }
    }
    if (!poly) { [self setStatus:@"No disc points yet: click “Place Disc Points” and click on the discs."]; NSBeep(); return; }

    NSArray *pts = [self orderedPoints:poly pix:pix];
    NSArray *allDiscs = SLDiscNames([self vertebraNames]);
    if ([pts count] < 2) { [self setStatus:@"At least two disc points are needed."]; NSBeep(); return; }
    NSInteger top = [self topIndexForCount:(NSInteger)[pts count]];
    if (top < 0 || top + (NSInteger)[pts count] > (NSInteger)[allDiscs count]) {
        [self setStatus:[NSString stringWithFormat:@"%lu points do not fit when the %@ disc is %@: check the known disc or remove points.",
                         (unsigned long)[pts count], [self anchorIsLowest] ? @"lowest" : @"highest", [self.discPopup titleOfSelectedItem]]];
        NSBeep(); return;
    }

    SLPlane plane = SLPlaneOf(pix);
    NSMutableArray *discs3D = [NSMutableArray array];
    for (NSValue *p in pts) {
        SLVec q = SLPixelTo3D(plane, [p pointValue]);
        [discs3D addObject:@[@(q.x), @(q.y), @(q.z)]];
    }
    NSArray *discNames = [allDiscs subarrayWithRange:NSMakeRange((NSUInteger)top, [pts count])];
    NSDictionary *model = @{@"version": @1,
                            @"studyInstanceUID": [self studyUIDOf:v] ?: @"",
                            @"frameOfReferenceUID": [self frameOfReferenceOf:v] ?: @"",
                            @"thoracic": @([[self.thoracicPopup titleOfSelectedItem] integerValue]),
                            @"lumbar": @([[self.lumbarPopup titleOfSelectedItem] integerValue]),
                            @"discNames": discNames,
                            @"discs": discs3D};
    NSString *uid = [self studyUIDOf:v];
    if (uid) [self saveModel:model forStudy:uid];

    [self removeROIsTagged:@[SLTagDiscs, SLTagPreview] fromList:polyList];
    for (NSMutableArray *rois in perSlice) [self removeROIsTagged:@[SLTagDiscs, SLTagPreview] fromList:rois];

    NSInteger labelled = [self applyModel:model toAllViewersLike:v];
    [self setStatus:[NSString stringWithFormat:@"Labelled %@ to %@ in %ld open series.%@",
                     [discNames firstObject], [discNames lastObject], (long)labelled,
                     uid ? @" Series of this study opened later are labelled too." : @" (No study identifier: labels are not kept for later series.)"]];
}

- (NSInteger)applyModel:(NSDictionary *)model toAllViewersLike:(ViewerController *)reference
{
    NSString *uid = [self studyUIDOf:reference];
    NSInteger n = 0;
    for (ViewerController *v in [ViewerController getDisplayed2DViewers]) {
        if (v != reference && (!uid || ![[self studyUIDOf:v] isEqualToString:uid])) continue;
        if ([self applyModel:model toViewer:v]) n++;
    }
    return n;
}

// Labels one viewer (all its time points / frames). NO when the series cannot be related to
// the disc positions (another frame of reference).
- (BOOL)applyModel:(NSDictionary *)model toViewer:(ViewerController *)v
{
    NSString *modelFoR = model[@"frameOfReferenceUID"], *viewerFoR = [self frameOfReferenceOf:v];
    if ([modelFoR length] && [viewerFoR length] && ![modelFoR isEqualToString:viewerFoR]) return NO;

    NSArray *raw = model[@"discs"], *discNames = model[@"discNames"];
    NSUInteger nd = MIN([raw count], [discNames count]);
    if (nd < 2) return NO;
    SLVec *D = (SLVec *)calloc(nd, sizeof(SLVec));
    for (NSUInteger i = 0; i < nd; i++) D[i] = SLMake([raw[i][0] doubleValue], [raw[i][1] doubleValue], [raw[i][2] doubleValue]);

    // Vertebrae: one above the highest disc, one between each pair, one below the lowest.
    NSMutableArray *vertNames = [NSMutableArray array];
    NSUInteger nv = nd + 1;
    SLVec *V = (SLVec *)calloc(nv, sizeof(SLVec));
    V[0] = SLAdd(D[0], SLScale(SLSub(D[0], D[1]), 0.5));
    [vertNames addObject:[[discNames[0] componentsSeparatedByString:@"/"] firstObject]];
    for (NSUInteger i = 0; i + 1 < nd; i++) {
        V[i + 1] = SLLerp(D[i], D[i + 1], 0.5);
        [vertNames addObject:[[discNames[i] componentsSeparatedByString:@"/"] lastObject]];
    }
    V[nd] = SLAdd(D[nd - 1], SLScale(SLSub(D[nd - 1], D[nd - 2]), 0.5));
    [vertNames addObject:[[discNames[nd - 1] componentsSeparatedByString:@"/"] lastObject]];

    // The spine's path, extended one level beyond each end disc.
    NSUInteger nc = nd + 2;
    SLVec *C = (SLVec *)calloc(nc, sizeof(SLVec));
    C[0] = SLAdd(D[0], SLSub(D[0], D[1]));
    for (NSUInteger i = 0; i < nd; i++) C[i + 1] = D[i];
    C[nc - 1] = SLAdd(D[nd - 1], SLSub(D[nd - 1], D[nd - 2]));
    SLVec axis = SLSub(D[0], D[nd - 1]);
    double axisLength = SLNorm(axis);
    if (axisLength > 0) axis = SLScale(axis, 1.0 / axisLength);

    BOOL discLevels = [[NSUserDefaults standardUserDefaults] boolForKey:SLKeyLabelDiscs];
    BOOL longitudinalLabels = [[NSUserDefaults standardUserDefaults] boolForKey:SLKeyLongitudinal];
    const double discHalf = 0.12;          // fraction of a level counted as disc on axial images
    RGBColor yellow = {65535, 65535, 0};

    for (short m = 0; m < MAX(1, [v maxMovieIndex]); m++) {
        NSArray *pixList = [v pixList:m], *perSlice = [v roiList:m];
        for (NSUInteger s = 0; s < [pixList count] && s < [perSlice count]; s++) {
            DCMPix *pix = [pixList objectAtIndex:s];
            NSMutableArray *rois = [perSlice objectAtIndex:s];
            [self removeROIsTagged:@[SLTagLabel] fromList:rois];
            SLPlane plane = SLPlaneOf(pix);
            BOOL transverse = fabs(SLDot(plane.normal, axis)) > 0.6;
            SLVec offset = SLLabelOffset(plane, transverse ? 35.0 : 25.0);

            if (transverse) {
                // Where the spine crosses this image, and at which level.
                for (NSUInteger j = 0; j + 1 < nc; j++) {
                    double d0, d1;
                    SL3DToPixel(plane, C[j], &d0);
                    SL3DToPixel(plane, C[j + 1], &d1);
                    if ((d0 > 0 && d1 > 0) || (d0 < 0 && d1 < 0) || d0 == d1) continue;
                    double f = d0 / (d0 - d1);
                    SLVec hit = SLLerp(C[j], C[j + 1], f);
                    NSString *label;
                    if (j == 0) label = (discLevels && f > 1 - discHalf) ? discNames[0] : vertNames[0];
                    else if (j == nc - 2) label = (discLevels && f < discHalf) ? discNames[nd - 1] : vertNames[nd];
                    else if (discLevels && f < discHalf) label = discNames[j - 1];
                    else if (discLevels && f > 1 - discHalf) label = discNames[j];
                    else label = vertNames[j];
                    NSPoint pt = SL3DToPixel(plane, SLAdd(hit, offset), NULL);
                    if (!SLInside(plane, pt)) pt = SL3DToPixel(plane, hit, NULL);
                    if (SLInside(plane, pt))
                        [rois addObject:[self newText:label at:pt pix:pix viewer:v tag:SLTagLabel color:yellow]];
                    break;
                }
            } else if (longitudinalLabels) {
                // Sagittal / coronal: the vertebrae near this image, beside their bodies.
                for (NSUInteger k = 0; k < nv; k++) {
                    double dist;
                    SL3DToPixel(plane, V[k], &dist);
                    if (fabs(dist) > 20.0) continue;
                    // Local direction of the spine at this vertebra: between its two discs
                    // (the end vertebrae use the nearest pair).
                    SLVec tangent = (k == 0) ? SLSub(D[0], D[1])
                                  : (k == nd) ? SLSub(D[nd - 2], D[nd - 1])
                                  : SLSub(D[k - 1], D[k]);
                    SLVec across = SLLabelOffsetAcross(plane, tangent, 25.0);
                    NSPoint pt = SL3DToPixel(plane, SLAdd(V[k], across), NULL);
                    if (!SLInside(plane, pt)) pt = SL3DToPixel(plane, V[k], NULL);
                    if (SLInside(plane, pt))
                        [rois addObject:[self newText:vertNames[k] at:pt pix:pix viewer:v tag:SLTagLabel color:yellow]];
                }
            }
        }
    }
    free(D); free(V); free(C);
    [v needsDisplayUpdate];
    return YES;
}

#pragma mark Other actions

- (void)editDiscs:(id)sender
{
    ViewerController *v = self.viewer;
    NSDictionary *model = v ? [self modelForStudy:[self studyUIDOf:v]] : nil;
    DCMPix *pix = v ? [self currentPix:v] : nil;
    NSMutableArray *rois = v ? [self roisOfCurrentImage:v] : nil;
    if (!model || !pix || !rois) { [self setStatus:@"No saved discs for this study."]; NSBeep(); return; }
    SLPlane plane = SLPlaneOf(pix);
    NSMutableArray *points = [NSMutableArray array];
    for (NSArray *q in model[@"discs"])
        [points addObject:[MyPoint point:SL3DToPixel(plane, SLMake([q[0] doubleValue], [q[1] doubleValue], [q[2] doubleValue]), NULL)]];
    [self removeROIsTagged:@[SLTagDiscs, SLTagPreview] fromList:rois];
    ROI *poly = [self newROI:tOPolygon onPix:pix viewer:v];
    [poly setPoints:points];
    [poly setName:SLDiscPolygonName];
    RGBColor green = {0, 65535, 0};
    [poly setColor:green];
    [rois addObject:poly];
    [self selectDiscsOfModel:model[@"discNames"]];
    [self updatePreview];
    [v needsDisplayUpdate];
    [self setStatus:@"Disc points restored on this image (projected if it is another slice). Adjust them, then “Apply Labels”."];
}

- (void)relabelOpenSeries:(id)sender
{
    ViewerController *v = self.viewer;
    NSDictionary *model = v ? [self modelForStudy:[self studyUIDOf:v]] : nil;
    if (!model) { [self setStatus:@"No saved discs for this study yet."]; NSBeep(); return; }
    NSInteger n = [self applyModel:model toAllViewersLike:v];
    [self setStatus:[NSString stringWithFormat:@"Labelled %ld open series.", (long)n]];
}

- (void)removeLabels:(id)sender
{
    ViewerController *ref = self.viewer;
    if (!ref) return;
    NSString *uid = [self studyUIDOf:ref];
    NSInteger n = 0;
    for (ViewerController *v in [ViewerController getDisplayed2DViewers]) {
        if (v != ref && (!uid || ![[self studyUIDOf:v] isEqualToString:uid])) continue;
        for (short m = 0; m < MAX(1, [v maxMovieIndex]); m++)
            for (NSMutableArray *rois in [v roiList:m])
                [self removeROIsTagged:@[SLTagLabel, SLTagDiscs, SLTagPreview] fromList:rois];
        [v needsDisplayUpdate];
        n++;
    }
    NSString *path = [self modelPathForStudy:uid];
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [self setStatus:[NSString stringWithFormat:@"Labels removed from %ld open series; the study's disc positions were deleted.", (long)n]];
}

#pragma mark Series opened later

- (void)viewerLoaded:(NSNotification *)note
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:SLKeyAuto]) return;
    ViewerController *v = [note object];
    if (![v isKindOfClass:[ViewerController class]]) return;
    // Let the viewer finish loading its own ROIs first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![[ViewerController getDisplayed2DViewers] containsObject:v]) return;
        NSDictionary *model = [self modelForStudy:[self studyUIDOf:v]];
        if (model) [self applyModel:model toViewer:v];
    });
}

- (void)windowWillClose:(NSNotification *)note
{
    // Keep the labels; only drop an unfinished disc polygon's name previews.
    ViewerController *v = self.viewer;
    if (!v) return;
    for (NSMutableArray *rois in [v roiList:[v curMovieIndex]])
        [self removeROIsTagged:@[SLTagPreview] fromList:rois];
    [v needsDisplayUpdate];
}

@end
