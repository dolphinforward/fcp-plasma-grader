//
// CSTLUTSelection.m
//

#import "CSTLUTSelection.h"

static NSString *const CSTIdentifierKey = @"identifier";
static NSString *const CSTDisplayNameKey = @"displayName";
static NSString *const CSTSourcePathKey = @"sourcePath";
static NSString *const CSTBookmarkDataKey = @"bookmarkData";

@implementation CSTLUTSelection

+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (instancetype)none
{
    return [[self alloc] initWithIdentifier:0
                               displayName:@"No LUT"
                                sourcePath:@""
                              bookmarkData:nil];
}

+ (NSSet<Class> *)allowedClasses
{
    return [NSSet setWithObject:self];
}

- (instancetype)initWithIdentifier:(uint64_t)identifier
                       displayName:(NSString *)displayName
                        sourcePath:(NSString *)sourcePath
                      bookmarkData:(NSData *)bookmarkData
{
    self = [super init];
    if (self != nil)
    {
        _identifier = identifier;
        _displayName = [displayName copy];
        _sourcePath = [sourcePath copy];
        _bookmarkData = [bookmarkData copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    uint64_t identifier = (uint64_t)[coder decodeInt64ForKey:CSTIdentifierKey];
    NSString *displayName = [coder decodeObjectOfClass:NSString.class forKey:CSTDisplayNameKey];
    NSString *sourcePath = [coder decodeObjectOfClass:NSString.class forKey:CSTSourcePathKey];
    NSData *bookmarkData = [coder decodeObjectOfClass:NSData.class forKey:CSTBookmarkDataKey];
    return [self initWithIdentifier:identifier
                       displayName:displayName ?: @"Missing LUT"
                        sourcePath:sourcePath ?: @""
                      bookmarkData:bookmarkData];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt64:(int64_t)self.identifier forKey:CSTIdentifierKey];
    [coder encodeObject:self.displayName forKey:CSTDisplayNameKey];
    [coder encodeObject:self.sourcePath forKey:CSTSourcePathKey];
    [coder encodeObject:self.bookmarkData forKey:CSTBookmarkDataKey];
}

- (instancetype)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithIdentifier:self.identifier
                                                    displayName:self.displayName
                                                     sourcePath:self.sourcePath
                                                   bookmarkData:self.bookmarkData];
}

#if defined(CST_GRADE_XPC)
- (NSObject<NSSecureCoding, NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue
                                                withWeight:(float)weight
{
    CSTLUTSelection *selectedValue = self;
    if (weight >= 1.0f && [rightValue isKindOfClass:CSTLUTSelection.class])
    {
        selectedValue = (CSTLUTSelection *)rightValue;
    }
    return [selectedValue copy];
}

- (BOOL)isEqual:(NSObject<NSSecureCoding, NSCopying> *)object
#else
- (BOOL)isEqual:(id)object
#endif
{
    if (object == self)
    {
        return YES;
    }
    if (![object isKindOfClass:CSTLUTSelection.class])
    {
        return NO;
    }
    CSTLUTSelection *rightValue = (CSTLUTSelection *)object;
    return self.identifier == rightValue.identifier
        && [self.displayName isEqualToString:rightValue.displayName]
        && [self.sourcePath isEqualToString:rightValue.sourcePath];
}

- (NSUInteger)hash
{
    return @(self.identifier).hash;
}

@end
