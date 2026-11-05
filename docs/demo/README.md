# Byakugan: 25-second demo

[Watch the finished video](../media/byakugan-25s.mp4) · [Poster](../media/demo-poster.jpg)

Made with [brag](https://github.com/latent-spaces/brag/tree/669ab9286aa28b6c3ee30e75f181ee74319d012a)
and Hyperframes 0.9.17. The editable HTML composition is in `composition/`;
the storyboard and visual direction are in [brag-plan.md](brag-plan.md) and
[composition-brief.md](composition-brief.md).

The film is 25 seconds, 1920×1080, 30 fps, with music and two quiet selection
sounds. It uses real app captures: synthetic demo data for exploration, and a
disposable file for cleanup confirmation. Confirmation was cancelled; no files
were recycled. The edited sequence does not measure scanning speed. The light
and dark README screenshots also use synthetic data.

## Re-render

Requires Node.js/npm, FFmpeg and a browser supported by Hyperframes. From this
directory, run these PowerShell commands:

```powershell
Set-Location composition
npm run check
npx --yes hyperframes@0.9.17 snapshot --at 1.5,4.5,9.5,12.5,15.5,19.5,23.5
npx --yes hyperframes@0.9.17 preview --background --no-open
npm run render -- --quality delivery --output ../brag.mp4
```

Inspect the snapshots and render. The settled hook at 1.5 seconds shows the
product and title together, so it is the poster. Replace only frame zero with
that poster, preserving the remaining 749 frames and copying the audio:

```powershell
Set-Location ..
ffmpeg -y -ss 1.5 -i brag.mp4 -frames:v 1 -q:v 2 ../media/demo-poster.jpg
ffmpeg -y -i brag.mp4 -i ../media/demo-poster.jpg -filter_complex "[0:v][1:v]overlay=0:0:enable='eq(n,0)'[v]" -map "[v]" -map "0:a?" -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -c:a copy -movflags +faststart ../media/byakugan-25s.mp4
ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,nb_frames -of json ../media/byakugan-25s.mp4
```

Expected video: H.264, 1920×1080, 30/1 fps, 750 frames, 25.000 seconds;
audio: AAC. The checked-in assets are local, including fonts and GSAP; the CLI
itself is fetched through npm. `audio-rms.js` contains the first 25 seconds of
precomputed music RMS at 30 fps for subtle logo opacity, with no runtime fetch.

## Credits and licenses

- **Music:** “Happy Beats / Business Moves Vol. 1” by Sascha Ende,
  [ende.app](https://ende.app/en), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  Source: brag's `skills/brag/assets/music/happy-beats-business-moves-vol-1-by-ende-dot-app.mp3`.
  The film uses the first 25 seconds, with reduced gain and fades. The source
  track is included as `composition/assets/music/bed.mp3`; the music is not
  covered by a software license for this repository.
- **Sound effect:** Kenney's `select_008.ogg`, supplied by brag's interface SFX
  collection, [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
  Included as `composition/assets/sfx/select.ogg`, with reduced gain in the mix.
- **Fonts:** Recursive Sans Linear by the Recursive Project Authors,
  [SIL Open Font License 1.1](composition/assets/fonts/LICENSE.txt).
  The font files are unchanged; `ByakuganSans` is only a CSS family alias.
- **Animation runtime:** GSAP 3.15.0, Copyright 2026 GreenSock,
  [Standard License](https://gsap.com/standard-license). The original notice is
  retained in `composition/assets/vendor/gsap.min.js`.
- **Product imagery:** Byakugan's Partition logo and actual application captures.
  UI screenshots have been scaled and edited into a sequence, without invented
  controls or a simulated successful deletion.

The composition uses a calm forest/cream palette, stationary headings after
their entrance, and brief motion on screen changes. [Share copy](share-copy.txt)
is ready to accompany the video.
