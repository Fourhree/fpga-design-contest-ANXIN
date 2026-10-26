# Thumbnail and fullscreen display

The video path is:

`color_bar timing -> thumbnail_layout -> media_frame_reader -> HDMI`

`thumbnail_layout` maps 640x480 display coordinates to an image bank and
source coordinates. `media_frame_reader` converts those coordinates into
SDRAM word addresses and prefetches each display line.

The top-level wiring is in `src/user_source/hdl_source/top_tf_hdmi_audio.v`.
The layout receives frame-latched `focus_index`, `image_complete`, and each
bank's dimensions, and supplies `source_index`, `source_x`, and `source_y`.
The reader requests coordinates for the next display line so SDRAM data is
ready before that line becomes visible. Native fullscreen uses those same
display coordinates directly, bypassing the layout mapper.

## Controls

- Short KEY2 release: toggle autoplay.
- KEY1: next image.
- Hold KEY2 for one second: previous image.
- Short KEY3 release: toggle thumbnail and fitted fullscreen.

Mode changes and the selected image are committed at a frame boundary, so one
frame never mixes two layouts.

## Display modes

- Thumbnail: 2x2 cells, nearest-neighbor scaling, yellow focus border.
- Fitted fullscreen: selected image is scaled to 640x480.
- Native fullscreen: layout is bypassed; image pixel `(x,y)` maps directly to
  display pixel `(x,y)`. This renderer remains available internally, but KEY3
  uses the fitted fullscreen state for a direct two-way user toggle. Areas
  outside the image are black and images larger than the screen are cropped.

The current scaler stretches to the destination rectangle; it does not add
letterboxing to preserve aspect ratio.

## BMP and memory limits

- Uncompressed 24-bit BMP (`BI_RGB`) is supported.
- Width and height are read from the BMP header. Positive and negative BMP
  heights (bottom-up and top-down files) are both supported.
- BMP row padding to a 4-byte boundary is handled by the decoder.
- Width and height must each fit in 16 bits and be nonzero.
- Each decoded image must contain at most 307200 pixels, the size of one SDRAM
  image bank. Dimensions do not have to be 640x480.
- The FAT32 root directory supplies up to four BMP files, cached in four
  independent image banks. Larger images are rejected before loading starts.

Pixels are stored contiguously in each SDRAM bank. Bottom-up orientation is
kept as bank metadata and converted when source coordinates are generated.
The SDRAM adapter issues aligned four-word groups, matching the vendor
controller's native access contract.

## Verification

Run from `tests`:

```powershell
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_thumbnail_regression.do
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_thumbnail_full_frame.do
& 'F:\ModelSim\modelsim_ase\win32aloem\vsim.exe' -c -do run_sdram_address_contract.do
```

The first regression checks dynamic BMP geometry, row padding, both BMP
orientations, invalid headers, four-word write padding/masks, all three display
modes, incomplete images, line underrun behavior, 640x480 timing coordinates,
debounced keys, display-mode chords, and frame-boundary image selection. The second
checks all 614400 pixels of 640x480 thumbnail and fitted fullscreen frames with
125 MHz memory and 25 MHz video clocks. The third uses the encrypted vendor SDRAM controller to
check nonconsecutive aligned write/read groups and returned-word ordering.

The CDC FIFO registers decoded markers and payloads together before the loader,
preserving START/RGB/COMMIT order and separating its BRAM output timing from
the loader FIFO write-enable logic.
The loader also registers the final received/written count comparison; a bank
becomes complete only after all physical writes and their controller gap have
finished. Incomplete images are never marked ready for display.

## Latest build and hardware status

TD 6.2.168116 completed synthesis, placement, routing, and bit generation for
EG4S20BG256 from the current sources on 2026-10-10 at 13:48:22.
The output is `tests/td_build/player_fixed.bit` (629624 bytes), SHA256:

`752D1A90A5677A36DFAEBAFCEF6B294FEA9F51A3E30C0738D0E328DEF5DCA638`

The compact regression passed after the final loader change. The full-frame
and encrypted SDRAM controller regressions passed with the current reader and
layout; those modules were unchanged by the final loader change.

The routed report `tests/td_build/player_fixed_pr.timing` has global setup WNS
-5.773 ns and hold WNS +0.003 ns (no hold violations). Video-clock setup
passes (+1.535 ns including cross-domain paths); memory intradomain setup is
-2.000 ns. Remaining setup violations include the WAV/FAT stream path in the
SD domain, loader write logic in the memory domain, and cross-domain reset
recovery paths. SDRAM local clock routing warnings also remain. No blanket
false paths were added to hide these failures.

This is a successful build and functional simulation result, not timing
closure or board validation. The bitstream has not been downloaded or tested
on hardware; stable hardware operation still requires resolving the timing
violations and checking the board.

## Decoder location

There is no `bmp24_decoder.v` in this project. The active dynamic BMP decoder
is `src/user_source/hdl_source/SD/bmp_fat_reader.v`, instantiated by
`src/user_source/hdl_source/SD/sd_card_bmp.v`.
