# Recursive Sans Linear

These are unmodified official static TrueType fonts from Recursive 1.085:

- `RecursiveSansLnrSt-Regular.ttf` — weight 400
- `RecursiveSansLnrSt-Med.ttf` — weight 500
- `RecursiveSansLnrSt-SemiBold.ttf` — weight 600

All three share typographic family `Recursive Sans Linear Static`. They are
proportional Sans, Linear, upright faces with real static outlines (no `fvar`
table), so nanoui does not need to instantiate variable axes.

Copyright 2020 The Recursive Project Authors
(https://github.com/arrowtype/recursive).
Licensed under SIL Open Font License 1.1; see the complete, verbatim
`LICENSE.txt` alongside the fonts. The font files retain their original
copyright, attribution and license metadata.

Design: Stephen Nixon, with Lisa Huang, Katja Schimmel and Rafał Buchner.
Font mastering: Ben Kiel.

## Provenance

- Project: https://www.recursive.design/
- Upstream: https://github.com/arrowtype/recursive
- Release: https://github.com/arrowtype/recursive/releases/tag/v1.085
- Archive: https://github.com/arrowtype/recursive/releases/download/v1.085/ArrowType-Recursive-1.085.zip
- Archive directory: `ArrowType-Recursive-1.085/Recursive_Desktop/separate_statics/TTF/`
- License source: `ArrowType-Recursive-1.085/LICENSE.txt`

Extract only the three named TTF files and the license. No font generation,
subsetting, renaming, installation or system font registration is required.
`typeface.zig` embeds their bytes and registers them with nanoui in process.

SHA-256 checksums:

```text
cbcbdf7a0e181d284a9235e09ed5f3873e527bc5dd1d977df71cdc1ff937da02  ArrowType-Recursive-1.085.zip
ca6aeb615fe2d1c2a97b101ee32c9cad19ffbdfaf3011f0935d6b210d365fb4e  RecursiveSansLnrSt-Regular.ttf
8e346dcabc066b68473487a085fd2b9d1c1c00a2a503ee5a1e876eca916fe1ca  RecursiveSansLnrSt-Med.ttf
afbbb94450ca02f92d38faa6d7f24ad12bc7bf1b689c9df9718d37e1794708f9  RecursiveSansLnrSt-SemiBold.ttf
f9f539cf7549bd417159dbdb9c400943a5b60a7366c2c6fbde9f095173d82479  LICENSE.txt
```
