# SpineLabel for IsiX and Horos (macOS)

Semi-automatic vertebra labelling for the **IsiX DICOM Viewer** and **Horos**, in the manner of
the OsiriX MD "Spine Labeling" plugin. You click the discs once on a sagittal or coronal image;
every series of the study then shows the levels: vertebra labels beside the bodies on
sagittal/coronal images, and the vertebra or disc level on each axial slice.

> Labels are an aid, not a diagnosis. Always confirm the count (transitional vertebrae,
> 11 or 13 rib-bearing vertebrae, 4 or 6 lumbar vertebrae) before reporting a level.

## Download

Current version: **1.4**. Click the package for your viewer:

| Viewer | Download | macOS | Mac |
|---|---|---|---|
| IsiX DICOM Viewer 6+ (GitHub build) | [**SpineLabel-IsiX-1.4.zip**](https://github.com/ArtemSobolev95/SpineLabel-macOS/raw/main/downloads/SpineLabel-IsiX-1.4.zip) | 15 or later | Apple silicon and Intel |
| Horos 4.0.x (3.3.x untested) | [**SpineLabel-Horos-1.4.zip**](https://github.com/ArtemSobolev95/SpineLabel-macOS/raw/main/downloads/SpineLabel-Horos-1.4.zip) | 11 or later | Apple silicon and Intel |

The App Store version of IsiX loads no plugins; use the
[GitHub build of IsiX](https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases).

### Install

1. Quit the viewer.
2. Unzip the package and double-click **Install SpineLabel.command**.
   If macOS says the developer cannot be verified: System Settings › Privacy & Security ›
   *Open Anyway*, then double-click it again.
3. Open the viewer. *Plugins › Plugins Manager* should list SpineLabel as loaded.

Toolbar button: right-click the viewer toolbar › *Customize Toolbar…* and drag **Spine Labeling** onto it.

## How to use

1. Open the study and a sagittal (or coronal) series in which the discs are visible.
2. *Plugins › ROI Tools › Spine Labeling* (or the toolbar button). The panel opens.
3. Choose one disc you can identify: "Lowest disc is" L5/S1 (default), or "Highest disc is", e.g. C2/C3.
4. Click **Place Disc Points**: the open polygon tool is selected. Click the centre of each disc,
   top to bottom or bottom to top, and double-click the last disc. The disc names appear next
   to the points; the plugin works out the direction itself.
5. Check the names. Drag a point onto the centre of its disc if needed; you may add or delete points.
6. Click **Apply Labels**. All open series of the study are labelled:
   - sagittal/coronal images: C1 … S1 beside each vertebral body, placed across the local
     direction of the spine (so they stay level with the bodies in kyphosis and lordosis);
   - axial images: the level at that slice, e.g. "L4", or "L4/L5" at a disc.

   Series of the study opened later are labelled automatically.

Options: 11/12/13 thoracic and 4/5/6 lumbar vertebrae; disc levels on axial images; labels on
sagittal/coronal images; automatic labelling of series opened later. Other buttons: **Edit Discs**
(puts the saved disc points back to correct them), **Label Open Series**, **Remove Labels**.

The disc positions of each study are kept in `~/Library/Application Support/SpineLabel/`.
Labels are ordinary text ROIs. Series are labelled only if they share the frame of reference of
the series the discs were marked on.

## Build from source

Needs the Xcode command line tools.

    ./build.sh install                 # IsiX build, installed in ~/Library/Application Support/IsiX/Plugins
    TARGET=horos ./build.sh install    # Horos build
    TARGET=isix ./package.sh; TARGET=horos ./package.sh   # → dist/*.zip

## Licence

SpineLabel: BSD 3-Clause, © 2026 Artem Sobolev (see [LICENSE](LICENSE)).
`third_party/` holds viewer headers under the LGPL v3 (see `third_party/COPYING.LESSER`).
