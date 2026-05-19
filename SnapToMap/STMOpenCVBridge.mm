#import "STMOpenCVBridge.h"

#import <opencv2/calib3d.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/imgproc.hpp>

namespace {

NSString *const STMOpenCVErrorDomain = @"STMOpenCVBridge";

NSError *stmMakeError(NSString *msg, NSInteger code = 1) {
    return [NSError errorWithDomain:STMOpenCVErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

bool stmMatRGBAFromCGImage(CGImageRef cgImage, cv::Mat &outRGBA, NSError **error) {
    if (!cgImage) {
        if (error) *error = stmMakeError(@"Nil CGImage");
        return false;
    }
    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    if (w < 1 || h < 1) {
        if (error) *error = stmMakeError(@"CGImage has zero extent");
        return false;
    }

    outRGBA.create((int)h, (int)w, CV_8UC4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) {
        cs = CGColorSpaceCreateDeviceRGB();
    }
    CGBitmapInfo bi = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little);
    CGContextRef ctx = CGBitmapContextCreate(outRGBA.data, w, h, 8, outRGBA.step[0], cs, bi);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        if (error) *error = stmMakeError(@"CGBitmapContextCreate failed");
        return false;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);
    return true;
}

NSData *stmPNGFromMatRGBA(const cv::Mat &rgba) {
    std::vector<uchar> buf;
    std::vector<int> params = {cv::IMWRITE_PNG_COMPRESSION, 3};
    if (!cv::imencode(".png", rgba, buf, params)) {
        return nil;
    }
    return [NSData dataWithBytes:buf.data() length:buf.size()];
}

/// Copies row-major **RGBA** into **`NSMutableData`** so **`CGImage`** outlives **`cv::Mat`**.
static CGImageRef stmCreateCGImageRefCopyingMatRGBA(const cv::Mat &m, NSError **error) {
    if (m.empty() || m.type() != CV_8UC4) {
        if (error) *error = stmMakeError(@"Invalid RGBA mat");
        return nullptr;
    }
    const int w = m.cols;
    const int h = m.rows;
    if (w < 1 || h < 1) {
        if (error) *error = stmMakeError(@"Empty mat extent");
        return nullptr;
    }
    const size_t bytesPerRow = static_cast<size_t>(w) * 4u;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * static_cast<size_t>(h)];
    auto *dstBase = static_cast<uint8_t *>(data.mutableBytes);
    for (int y = 0; y < h; y++) {
        memcpy(dstBase + static_cast<size_t>(y) * bytesPerRow, m.ptr<uint8_t>(y), bytesPerRow);
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) {
        cs = CGColorSpaceCreateDeviceRGB();
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) {
        CGColorSpaceRelease(cs);
        if (error) *error = stmMakeError(@"CGDataProviderCreateWithCFData failed");
        return nullptr;
    }
    CGBitmapInfo bi = static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little);
    CGImageRef img = CGImageCreate(
        static_cast<size_t>(w),
        static_cast<size_t>(h),
        8,
        32,
        bytesPerRow,
        cs,
        bi,
        provider,
        nullptr,
        false,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!img && error) {
        *error = stmMakeError(@"CGImageCreate failed");
    }
    return img;
}

} // namespace

@implementation STMOpenCVBridge

+ (nullable NSData *)perspectiveWarpPNGWithCGImage:(CGImageRef)cgImage
                                  destinationPoints:(const CGPoint *)dstPts
                                        outputWidth:(int)outputWidth
                                       outputHeight:(int)outputHeight
                                              error:(NSError *__autoreleasing  _Nullable *)error {
    if (outputWidth < 1 || outputHeight < 1) {
        if (error) *error = stmMakeError(@"Invalid output size");
        return nil;
    }
    cv::Mat srcRGBA;
    if (!stmMatRGBAFromCGImage(cgImage, srcRGBA, error)) {
        return nil;
    }

    int sw = srcRGBA.cols;
    int sh = srcRGBA.rows;
    if (sw < 2 || sh < 2) {
        if (error) *error = stmMakeError(@"Source too small");
        return nil;
    }

    std::vector<cv::Point2f> srcPts = {
        {0.f, 0.f},
        {(float)(sw - 1), 0.f},
        {(float)(sw - 1), (float)(sh - 1)},
        {0.f, (float)(sh - 1)},
    };
    std::vector<cv::Point2f> dstPtsCV = {
        {static_cast<float>(dstPts[0].x), static_cast<float>(dstPts[0].y)},
        {static_cast<float>(dstPts[1].x), static_cast<float>(dstPts[1].y)},
        {static_cast<float>(dstPts[2].x), static_cast<float>(dstPts[2].y)},
        {static_cast<float>(dstPts[3].x), static_cast<float>(dstPts[3].y)},
    };

    cv::Mat H = cv::getPerspectiveTransform(srcPts, dstPtsCV, cv::DECOMP_LU);
    cv::Mat dstRGBA;
    cv::warpPerspective(
        srcRGBA,
        dstRGBA,
        H,
        cv::Size(outputWidth, outputHeight),
        cv::INTER_LINEAR,
        cv::BORDER_CONSTANT,
        cv::Scalar(0, 0, 0, 0));

    return stmPNGFromMatRGBA(dstRGBA);
}

+ (nullable NSData *)resizePNGData:(NSData *)pngData
                             width:(int)width
                            height:(int)height
                             error:(NSError *__autoreleasing  _Nullable *)error {
    if (width < 1 || height < 1) {
        if (error) *error = stmMakeError(@"Invalid resize size");
        return nil;
    }
    std::vector<uchar> bufIn(static_cast<size_t>(pngData.length));
    [pngData getBytes:bufIn.data() length:pngData.length];
    cv::Mat decoded = cv::imdecode(bufIn, cv::IMREAD_UNCHANGED);
    if (decoded.empty()) {
        if (error) *error = stmMakeError(@"imdecode failed");
        return nil;
    }
    cv::Mat srcRGBA;
    if (decoded.channels() == 4) {
        srcRGBA = decoded;
    } else if (decoded.channels() == 3) {
        cv::cvtColor(decoded, srcRGBA, cv::COLOR_BGR2BGRA);
    } else if (decoded.channels() == 1) {
        cv::cvtColor(decoded, srcRGBA, cv::COLOR_GRAY2BGRA);
    } else {
        if (error) *error = stmMakeError(@"Unsupported channel count");
        return nil;
    }
    cv::Mat resized;
    cv::resize(srcRGBA, resized, cv::Size(width, height), 0, 0, cv::INTER_LINEAR);
    return stmPNGFromMatRGBA(resized);
}

+ (nullable CGImageRef)pyrDownCopyOfCGImage:(CGImageRef)cgImage
                                      error:(NSError *__autoreleasing  _Nullable *)error {
    cv::Mat srcRGBA;
    if (!stmMatRGBAFromCGImage(cgImage, srcRGBA, error)) {
        return nullptr;
    }
    if (srcRGBA.cols < 2 || srcRGBA.rows < 2) {
        if (error) *error = stmMakeError(@"CGImage smaller than 2×2 — cannot pyrDown");
        return nullptr;
    }
    cv::Mat dst;
    cv::pyrDown(srcRGBA, dst);
    CGImageRef out = stmCreateCGImageRefCopyingMatRGBA(dst, error);
    return out;
}

@end
