//
// CSTLUTSelection.h
//
// Secure, copyable custom-parameter value shared by the FxPlug service and
// the optional organizer application. FxPlug's interpolation protocol uses
// an Objective-C isEqual: signature that cannot be expressed alongside
// NSObject.isEqual(_:) in Swift 5, so this narrow value type follows Apple's
// Objective-C FxCustomParameterInterpolation_v2 sample.
//

#import <Foundation/Foundation.h>

#if defined(CST_GRADE_XPC)
#import <FxPlug/FxPlugSDK.h>
#endif

NS_ASSUME_NONNULL_BEGIN

#if defined(CST_GRADE_XPC)
@interface CSTLUTSelection : NSObject <NSSecureCoding, NSCopying, FxCustomParameterInterpolation_v2>
#else
@interface CSTLUTSelection : NSObject <NSSecureCoding, NSCopying>
#endif

@property(nonatomic, readonly) uint64_t identifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *sourcePath;
@property(nonatomic, copy, readonly, nullable) NSData *bookmarkData;

+ (instancetype)none;

- (instancetype)initWithIdentifier:(uint64_t)identifier
                       displayName:(NSString *)displayName
                        sourcePath:(NSString *)sourcePath
                      bookmarkData:(nullable NSData *)bookmarkData NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
