SpineLabel for Horos — version @VERSION@
======================================

Semi-automatic vertebra labelling, in the manner of the OsiriX MD "Spine Labeling" plugin.
You mark the discs once on a sagittal or coronal image; every series of the study then shows
the levels: vertebra labels beside the bodies on sagittal/coronal images, and the vertebra or
disc level on each axial slice.

Labels are an aid. Always confirm the count (transitional vertebrae, 11 or 13 rib-bearing
vertebrae, 4 or 6 lumbar vertebrae) before reporting a level.


REQUIREMENTS
------------
- macOS 11 (Big Sur) or later, Apple silicon or Intel.
- Horos 4.0.x (or 3.3.x, Intel).


INSTALL
-------
1. Quit Horos.
2. Double-click "Install SpineLabel.command". If macOS blocks it: System Settings >
   Privacy & Security > "Open Anyway", then double-click it again.
3. Open Horos. Plugins > Plugins Manager should list SpineLabel as loaded.

To remove it: delete ~/Library/Application Support/Horos/Plugins/SpineLabel.osirixplugin


HOW TO USE
----------
1. Open the study and a sagittal (or coronal) series in which the discs are visible.
2. Plugins > ROI Tools > Spine Labeling (or its toolbar button). The panel opens.
3. Choose one disc you can identify: "Lowest disc is" L5/S1 (default), or "Highest disc is"
   e.g. C2/C3.
4. Click "Place Disc Points": the open polygon tool is selected. Click the centre of each disc,
   top to bottom or bottom to top, and double-click the last disc to finish. The disc names
   appear next to the points as you click; the plugin works out the direction itself.
   (An open polygon already drawn on the image is used as it is.)
5. Check the names. Drag a point onto the centre of its disc if needed; you may add or delete
   points. The known disc stays fixed (the lowest or highest point).
6. Click "Apply Labels". All open series of the study are labelled:
   - sagittal/coronal images: C1 … S1 next to each vertebral body (within 2 cm of it);
   - axial images: the level at that slice, e.g. "L4", or "L4/L5" at a disc.
   Series of the study you open later are labelled automatically.

Options
- Thoracic vertebrae 11/12/13 and lumbar 4/5/6, for numbering variants.
- Show disc levels on axial images (otherwise only the vertebra).
- Label vertebrae on sagittal and coronal images.
- Label series of this study opened later.

Other buttons
- Edit Discs: puts the saved disc points back on the current image to correct them;
  then "Apply Labels" again.
- Label Open Series: labels all open series of the study again (e.g. after changing options).
- Remove Labels: removes the labels from the open series and forgets the study's discs.

The disc positions of each study are kept in ~/Library/Application Support/SpineLabel/.
Labels are ordinary text ROIs; the viewer saves them with the series like other ROIs.
Series are labelled only if they share the frame of reference of the series the discs were
marked on (the same scan session and patient position).
