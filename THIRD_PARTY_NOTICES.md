# Third-party notices

These notices apply to dependencies, adapted code and bundled assets. They do
not replace the [MIT License](LICENSE) for Byakugan's original source and
documentation. That MIT grant does not relicense third-party material, including
the fonts, GSAP and demo audio listed below. The release ZIP includes the
complete dependency license texts under `third_party/licenses/`.

| Material | Copyright / source | License text |
| --- | --- | --- |
| nanoui, including the local Windows patch | 2026 Rach Pradhan; [pinned source](https://github.com/lsj5031/nanoui/tree/7d4424b1046f8bbab365b42f61d00f1934d4dcc8) | [MIT](third_party/licenses/nanoui-MIT.txt) |
| Native frame adapted from nanomon | 2026 Rach Pradhan; original notice also retained in `src/win_frame.zig` | [MIT](third_party/licenses/nanoui-MIT.txt) |
| mygo, through nanoui | 2026 MyGo contributors | [MIT](third_party/licenses/mygo-MIT.txt) |
| GPUI designs, through nanoui | 2022–2025 Zed Industries, Inc. | [Apache 2.0](third_party/licenses/GPUI-Apache-2.0.txt) |
| GPUI Kit designs, through nanoui | 2024–2026 Longbridge | [Apache 2.0](third_party/licenses/GPUI-Kit-Apache-2.0.txt) |
| gpui-motion, through nanoui | 2026 1keep contributors | [MIT](third_party/licenses/gpui-motion-MIT.txt) |
| Windows Terminal text correction, through nanoui | Microsoft Corporation | [MIT](third_party/licenses/Windows-Terminal-MIT.txt) |
| http-zig dependency | 2026 Rach Pradhan; revision `1f798e762f52ff81cc6c370b4f322c9e65064462` | [MIT](third_party/licenses/http-zig-MIT.txt) |
| Zig standard library and compiler runtime; TLS code used by http-zig | Zig contributors | [MIT](third_party/licenses/Zig-MIT.txt) |
| MinGW Windows runtime | mingw-w64 contributors | [Notices and ZPL](third_party/licenses/mingw-w64-COPYING.txt) |
| Embedded Recursive Sans Linear fonts | 2020 The Recursive Project Authors | [SIL OFL 1.1](third_party/licenses/Recursive-OFL.txt) |

nanoui's original [third-party notice](https://github.com/lsj5031/nanoui/blob/7d4424b1046f8bbab365b42f61d00f1934d4dcc8/THIRD_PARTY_NOTICES.md)
records its upstream revisions and design provenance. Our patch changes Windows
folder selection, reduced-motion handling and frame helpers; it does not change
the upstream license terms. Notices for optional nanoui components are retained
even where the linker omits those components from this app.

The exploration layout is inspired by [DiskTree](https://github.com/tobi/disktree).
The Partition mark is app-owned artwork.

The demo composition is separate from the executable package: Sascha Ende music
is CC BY 4.0, Kenney audio is CC0, and GSAP is under its own Standard License.
See [demo credits and source](docs/demo/README.md). Those assets retain their
own terms and are not included in the Windows binary ZIP.
