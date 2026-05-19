#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C entry points for OpenCV (implemented in **STMOpenCVBridge.mm**). Consumed from Swift via **`OpenCVBridge`**.
@interface STMOpenCVBridge : NSObject

/// Perspective warp **`cgImage`** (full source quad TL→TR→BR→BL in pixel space) into **`outputWidth` × `outputHeight`** RGBA, PNG-encoded.
/// **`dstPts`** order matches source corner order: geographic corner index `i` → pixel in output plane (UIKit coords, origin top-left).
+ (nullable NSData *)perspectiveWarpPNGWithCGImage:(CGImageRef)cgImage
                                  destinationPoints:(const CGPoint *)dstPts
                                        outputWidth:(int)outputWidth
                                       outputHeight:(int)outputHeight
                                              error:(NSError *__autoreleasing  _Nullable *)error;

/// Resize RGBA PNG **`pngData`** to **`width`** × **`height`** using linear interpolation; returns PNG bytes or **`nil`** on failure.
+ (nullable NSData *)resizePNGData:(NSData *)pngData
                             width:(int)width
                            height:(int)height
                             error:(NSError *__autoreleasing  _Nullable *)error;

/// Single **`cv::pyrDown`** step on premultiplied **RGBA** (**`CGImage`**). Caller owns the returned **`CGImage`**.
+ (nullable CGImageRef)pyrDownCopyOfCGImage:(CGImageRef)cgImage
                                       error:(NSError *__autoreleasing  _Nullable *)error CF_RETURNS_RETAINED
    NS_SWIFT_NAME(pyrDown(_:));

@end

NS_ASSUME_NONNULL_END
