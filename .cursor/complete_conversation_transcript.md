
# Complete Conversation Transcript

## User
What's the best strategy to serve very high-resolution map images as custom overlays in mapkit (or alternative map frameworks for iOS)? mktileoverlay with custom tiles made with openCV pyrdown is slow.

## Assistant
For very high-resolution imagery overlays on iOS, the main bottleneck is usually not the map framework itself — it’s the tile generation + decoding + texture upload pipeline.

A good architecture depends on whether your imagery is:
1. static/offline,
2. dynamic/generated,
3. georeferenced raster imagery,
4. or scientific/engineering imagery.

### Core recommendations

- Pre-generate tiled pyramids offline
- Use 512px or 1024px tiles
- Store in MBTiles or XYZ tile layouts
- Prefer MapLibre GL / MapLibre Native over MKTileOverlay
- Use WebP/JPEG unless transparency is required
- Avoid runtime tile generation

### Why MKTileOverlay feels slow

Typical bottlenecks:
- runtime pyramid generation
- PNG decoding
- too many small tiles
- CPU-heavy rendering
- weak GPU scheduling

### Recommended architecture

Source GeoTIFF
→ offline pyramid generation
→ 512px raster tiles
→ MBTiles/XYZ
→ MapLibre Native raster source
→ GPU rendering via Metal

### Better frameworks

- MapLibre Native
- Mapbox Maps SDK
- ArcGIS Runtime SDK
- WhirlyGlobe-Maply

### Key insight

Decoding and texture upload are often more expensive than networking.

---

## User
Instead of JPG or WebP (no native WebP encoding on iOS), why not HEIF?

## Assistant
HEIF/HEIC is actually a very reasonable choice for iOS raster tiles — especially for iOS-only deployments.

### Advantages of HEIF

- Hardware-accelerated decoding on Apple Silicon
- Better compression efficiency than JPEG
- Native ImageIO support
- Excellent quality for aerial/scientific imagery

### Why people avoid it

- Weak tooling ecosystem
- Poor GIS pipeline support
- Weak CDN/browser support
- Less common in tile servers
- More awkward encoding workflows

### Important nuance

HEIF is a container.
Usually:
- HEVC is the codec inside HEIF
- AVIF is AV1 in a HEIF-like container

On Apple platforms:
HEVC-backed HEIF is heavily optimized.

### Important insight

Tile size often matters more than image format.

Moving from:
256px → 512px or 1024px

can outperform changing formats.

### Advanced alternative

For extreme performance:
- ASTC
- Basis Universal
- KTX2
- GPU-native compressed textures

can outperform conventional image formats.

---

## User
With a strict focus on modern ios hardware-optimisation and a very large source image (~500 megapixels): What's the most efficient technology/framework for each of these steps?

- Warping the rectangular source image (and keeping full resolution equivalent)
- Padding the warped high-res image back into a rectangle
- Batch-cropping the result into 1K or 1.5K square tiles
- Storing the tiles as HEIF

## Assistant
For a 500MP source image, the optimal stack is:

| Stage | Recommended Technology |
|---|---|
| Warp / reprojection | Metal + Core Image |
| Resampling | Lanczos via Core Image or custom Metal shader |
| Padding/compositing | Core Image |
| Tile extraction | Metal compute shaders |
| HEIF encoding | ImageIO |
| Maximum throughput encoding | VideoToolbox |
| Runtime rendering | MapLibre Native |

### Core architectural insight

Treat the pipeline as a GPU texture-processing problem rather than a traditional image-processing problem.

### Why not OpenCV?

OpenCV pipelines become:
- CPU-bound
- memory-bandwidth limited
- allocation-heavy

at 500MP scale.

### Recommended rendering model

Avoid:
warp giant image
→ create giant bitmap
→ crop tiles

Prefer:
for each tile:
- inverse-project tile bounds
- sample source directly
- render tile directly

This avoids:
- huge intermediate buffers
- giant RAM spikes
- unnecessary memory movement

### Tile sizing

Recommended:
- 1024×1024
- 1536×1536

Benefits:
- fewer texture uploads
- fewer draw calls
- better GPU occupancy

### Best frameworks

- Metal
- Core Image
- ImageIO
- VideoToolbox
- MapLibre Native

### Avoid

- OpenCV pyramids
- UIImage loops
- CoreGraphics tile loops
- PNG tiles
- MKTileOverlayRenderer

---

## User
I don't quite understand — ImageIO (best encoder path on Apple platforms) or VideoToolbox (for maximum throughput): What should I prioritise for my use case?

## Assistant
Recommendation:
Start with ImageIO.

### Why ImageIO

Advantages:
- simpler implementation
- excellent quality
- highly optimized internally by Apple
- integrates perfectly with Core Image
- usually “fast enough” on Apple Silicon

Recommended pipeline:

MTLTexture / CIImage
→ CGImage
→ CGImageDestination
→ HEIF file

### When VideoToolbox matters

Use VideoToolbox only if:
- HEIF encoding becomes the dominant bottleneck
- generation throughput is mission-critical
- you batch-generate enormous datasets repeatedly

Pipeline:

MTLTexture
→ CVPixelBuffer
→ VTCompressionSession
→ HEVC bitstream
→ HEIF container

### Important insight

The biggest performance wins usually come from:
- reducing memory movement
- direct tile rendering
- minimizing intermediate textures

rather than switching encoders.

### Final recommendation

Use:
- Metal + Core Image
- direct per-tile rendering
- 1024–1536 tiles
- ImageIO
- MapLibre Native

Only adopt VideoToolbox if profiling proves encoding is the bottleneck.

---
