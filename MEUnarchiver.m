//
//  MEUnarchiver.m
//
//  Created by Frank Illenberger on 13.03.15.

#import "MEUnarchiver.h"

@implementation MEUnarchiver
{
    NSUInteger              _pos;
    int                     _streamerVersion;
    BOOL                    _swap;
    NSMutableArray*         _sharedStrings;
    NSMutableDictionary*    _sharedObjects;
    NSUInteger              _sharedObjectCounter;
    NSMutableDictionary*    _classNameMapping;
    NSMutableDictionary*    _versionByClassName;
    NSMutableArray*         _buffers;
}

static signed char const Long2Label         = -127;     // 0x81
static signed char const Long4Label         = -126;     // 0x82
static signed char const RealLabel          = -125;     // 0x83
static signed char const NewLabel           = -124;     // 0x84    denotes the start of a new shared string
static signed char const NullLabel          = -123;     // 0x85
static signed char const EndOfObjectLabel   = -122;     // 0x86
static signed char const SmallestLabel      = -110;     // 0x92

#define BIAS(x) (x - SmallestLabel)

- (id)initForReadingWithData:(NSData*)data
{
    NSParameterAssert(data.length > 0);
    
    if(self = [super init])
    {
        _data = [data copy];
        _pos = 0;
        _sharedObjects = [[NSMutableDictionary alloc] init];
        _sharedStrings = [[NSMutableArray alloc] init];
        if(![self readHeader])
            return nil;
    }
    return self;
}

- (BOOL)isAtEnd
{
    return _pos >= _data.length;
}

- (void)decodeClassName:(NSString*)inArchiveName
            asClassName:(NSString*)trueName
{
    NSParameterAssert(inArchiveName);
    NSParameterAssert(trueName);
    
    if(!_classNameMapping)
        _classNameMapping = [[NSMutableDictionary alloc] init];
    _classNameMapping[inArchiveName] = [trueName copy];
}

- (Class)classForName:(NSString*)className
{
    NSParameterAssert(className);
    
    NSString* replacement = _classNameMapping[className];
    return NSClassFromString(replacement ? replacement : className);
}

- (BOOL)readHeader
{
    signed char streamerVersion;
    if(![self decodeChar:&streamerVersion])
        return NO;
    _streamerVersion = streamerVersion;
    NSAssert(streamerVersion == 4, nil);    // we currently only support v4
    
    NSString* header;
    if(![self decodeString:&header])
        return NO;
    
    BOOL isBig = (NSHostByteOrder() == NS_BigEndian);
    if([header isEqualToString:@"typedstream"])
        _swap = !isBig;
    else if([header isEqualToString:@"streamtyped"])
        _swap = isBig;
    else
        return NO;
    
    int systemVersion;
    if(![self decodeInt:&systemVersion])
        return NO;
    
    return YES;
}

- (BOOL)readObject:(id*)outObject
{
    NSString* string;
    if(![self decodeSharedString:&string])
        return NO;
    if(![string isEqualToString:@"@"])
        return NO;
    
    return [self _readObject:outObject];
}

- (NSNumber*)nextSharedObjectLabel
{
    return @(_sharedObjectCounter++);
}

- (BOOL)_readObject:(id*)outObject
{
    NSParameterAssert(outObject);
    
    signed char ch;
    if(![self decodeChar:&ch])
        return NO;
    
    switch(ch)
    {
        case NullLabel:
            *outObject = nil;
            return YES;
            
        case NewLabel:
        {
            NSNumber* label = [self nextSharedObjectLabel];
            Class objectClass;
            if(![self readClass:&objectClass])
                return NO;
            id object = [[objectClass alloc] initWithCoder:self];
            _sharedObjects[label] = object;
            id objectAfterAwake  = [object awakeAfterUsingCoder:self];
            if(objectAfterAwake && objectAfterAwake != object)
            {
                object = objectAfterAwake;
                _sharedObjects[label] = objectAfterAwake;
            }
            *outObject = object;
            
            signed char endMarker;
            if(![self decodeChar:&endMarker] || endMarker != EndOfObjectLabel)
                return NO;
            
            return YES;
        }
            
        default:
        {
            int label;
            if(![self finishDecodeInt:&label withChar:ch])
                return NO;
            label = BIAS(label);
            if(label >= _sharedObjects.count)
                return NO;
            *outObject = _sharedObjects[@(label)];
            return YES;
        }
    }
}

- (BOOL)readClass:(Class*)outClass
{
    NSParameterAssert(outClass);
    
    signed char ch;
    if(![self decodeChar:&ch])
        return NO;
    
    switch(ch)
    {
        case NullLabel:
            *outClass = Nil;
            return YES;
            
        case NewLabel:
        {
            NSString* className;
            if(![self decodeSharedString:&className])
                return NO;
            int version;
            if(![self decodeInt:&version])
                return NO;
            
            if(!_versionByClassName)
                _versionByClassName = [[NSMutableDictionary alloc] init];
            _versionByClassName[className] = @(version);
            
            *outClass = [self classForName:className];
            if(!*outClass)
                return NO;
            
            _sharedObjects[[self nextSharedObjectLabel]] = *outClass;
            
            // We do not check the super-class
            Class superClass;
            if(![self readClass:&superClass])
                return NO;
            return YES;
        }
            
        default:
        {
            int label;
            if(![self finishDecodeInt:&label withChar:ch])
                return NO;
            label = BIAS(label);
            if(label >= _sharedObjects.count)
                return NO;
            *outClass = _sharedObjects[@(label)];
            return YES;
        }
    }
    
}

- (BOOL)readBytes:(void*)bytes length:(NSUInteger)length
{
    if(_pos + length > _data.length)
        return NO;
    [_data getBytes:bytes range:NSMakeRange(_pos, length)];
    _pos += length;
    return YES;
}

- (BOOL)decodeChar:(signed char*)outChar
{
    NSParameterAssert(outChar);
    return [self readBytes:outChar length:1];
}

- (BOOL)decodeFloat:(float*)outFloat
{
    NSParameterAssert(outFloat);
    
    signed char charValue;
    if(![self decodeChar:&charValue])
        return NO;
    if(charValue != RealLabel)
    {
        int intValue;
        if(![self finishDecodeInt:&intValue withChar:charValue])
            return NO;
        *outFloat = intValue;
        return YES;
    }
    NSSwappedFloat value;
    if(![self readBytes:&value length:sizeof(NSSwappedFloat)])
        return NO;
    
    *outFloat = [self swappedFloat:value];
    
    return YES;
}

- (BOOL)decodeDouble:(double*)outDouble
{
    NSParameterAssert(outDouble);
    
    signed char charValue;
    if(![self decodeChar:&charValue])
        return NO;
    if(charValue != RealLabel)
    {
        int intValue;
        if(![self finishDecodeInt:&intValue withChar:charValue])
            return NO;
        *outDouble = intValue;
        return YES;
    }
    NSSwappedDouble value;
    if(![self readBytes:&value length:sizeof(NSSwappedDouble)])
        return NO;
    
    *outDouble = [self swappedDouble:value];
    return YES;
}

- (BOOL)decodeString:(NSString**)outString
{
    NSParameterAssert(outString);
    
    signed char charValue;
    if(![self decodeChar:&charValue])
        return NO;
    
    if(charValue == NullLabel)
    {
        *outString = nil;
        return YES;
    }
    
    int length;
    if(![self finishDecodeInt:&length
                     withChar:charValue])
        return NO;
    if(length <= 0)
        return NO;
    
    char bytes[length];
    if(![self readBytes:bytes length:length])
        return NO;
    *outString = [[NSString alloc] initWithBytes:bytes
                                          length:length
                                        encoding:NSUTF8StringEncoding];
    return YES;
}

- (BOOL)decodeSharedString:(NSString**)outString
{
    signed char ch;
    if(![self decodeChar:&ch])
        return NO;
    if(ch == NullLabel)
    {
        *outString = nil;
        return YES;
    }
    if(ch == NewLabel)
    {
        if(![self decodeString:outString])
            return NO;
        [_sharedStrings addObject:*outString];
    }
    else
    {
        int stringIndex;
        if(![self finishDecodeInt:&stringIndex
                         withChar:ch])
            return NO;
        stringIndex = BIAS(stringIndex);
        if(stringIndex >= _sharedStrings.count)
            return NO;
        *outString = _sharedStrings[stringIndex];
    }
    return YES;
}

- (BOOL)decodeShort:(short*)outShort
{
    NSParameterAssert(outShort);
    
    signed char ch;
    if(![self decodeChar:&ch])
        return NO;
    
    if(ch != Long2Label)
    {
        *outShort = ch;
        return YES;
    }
    
    short value;
    if(![self readBytes:&value length:2])
        return NO;
    
    *outShort = [self swappedShort:value];
    
    return YES;
}

- (BOOL)decodeInt:(int*)outInt
{
    NSParameterAssert(outInt);
    signed char ch;
    if(![self decodeChar:&ch])
        return NO;
    return [self finishDecodeInt:outInt withChar:ch];
}

- (BOOL)finishDecodeInt:(int*)outInt
               withChar:(signed char)charValue
{
    NSParameterAssert(outInt);
    
    switch(charValue)
    {
        case Long2Label:
        {
            short value;
            if(![self readBytes:&value length:2])
                return NO;
            *outInt = [self swappedShort:value];
            break;
        }
            
        case Long4Label:
        {
            int value;
            if(![self readBytes:&value length:4])
                return NO;
            *outInt = [self swappedInt:value];
            break;
        }
            
        default:
            *outInt = charValue;
            break;
    }
    return YES;
}

- (unsigned short)swappedShort:(unsigned short)value
{
    return _swap ? NSSwapShort(value) : value;
}

- (unsigned int)swappedInt:(unsigned int)value
{
    return _swap ? NSSwapInt(value) : value;
}

- (unsigned long long)swappedLongLong:(unsigned long long)value
{
    return _swap ? NSSwapLongLong(value) : value;
}

- (float)swappedFloat:(NSSwappedFloat)value
{
    return _swap ? NSConvertSwappedFloatToHost(NSSwapFloat(value)) : NSConvertSwappedFloatToHost(value);
}

- (double)swappedDouble:(NSSwappedDouble)value
{
    return _swap ? NSConvertSwappedDoubleToHost(NSSwapDouble(value)) : NSConvertSwappedDoubleToHost(value);
}

- (BOOL)readType:(const char*)type data:(void*)data
{
    NSParameterAssert(type);
    NSParameterAssert(data);
    
    NSString* string;
    if(![self decodeSharedString:&string] || string.length == 0)
        return NO;
    
    const char* str = string.UTF8String;
    if(strcmp(str, type) != 0)
    {
        NSLog(@"wrong type in archive '%s', expected '%s'", str, type);
        return NO;
    }
    
    char ch = str[0];
    
    switch(ch)
    {
        case 'c':
        case 'C':
        {
            signed char value;
            if(![self decodeChar:&value])
                return NO;
            *((char*)data) = (char)value;
            break;
        }
            
        case 's':
        case 'S':
        {
            short value;
            if(![self decodeShort:&value])
                return NO;
            *((short*)data) = value;
            break;
        }
            
        case 'i':
        case 'I':
        case 'l':
        case 'L':
        {
            int value;
            if(![self decodeInt:&value])
                return NO;
            *((int*)data) = value;
            break;
        }
            
        case 'f':
        {
            float value;
            if(![self decodeFloat:&value])
                return NO;
            *((float*)data) = value;
            break;
        }
            
        case 'd':
        {
            double value;
            if(![self decodeDouble:&value])
                return NO;
            *((double*)data) = value;
            break;
        }
            
        case '@':
        {
            id obj;
            if(![self _readObject:&obj])
                return NO;
            *((__strong id*)data) = obj;
            break;
        }
            
        default:
            NSLog(@"unsupported archiving type %c", ch);
            return NO;
    }
    return YES;
}


#pragma mark - Convenience Methods

+ (id) compatibilityUnarchiveObjectWithData:(NSData*)data
                            decodeClassName:(NSString*)archiveClassName
                                asClassName:(NSString*)className
{
    NSParameterAssert(!archiveClassName || className);
    
    if(!data)
        return nil;
    
#if UXTARGET_IOS
    MEUnarchiver* unarchiver = [[MEUnarchiver alloc] initForReadingWithData:data];
    if(archiveClassName)
        [unarchiver decodeClassName:archiveClassName asClassName:className];
    return [unarchiver decodeObject];
#else
    NSUnarchiver* unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
    if(archiveClassName)
        [unarchiver decodeClassName:archiveClassName asClassName:className];
    return [unarchiver decodeObject];
#endif
}

#pragma mark - NSCoder methods

- (void)decodeValueOfObjCType:(const char*)type at:(void*)data
{
    NSParameterAssert(type);
    NSParameterAssert(data);
    
    // Make sure that even under iOS BOOLs are read with 'c' type.
    if(strcmp(type, @encode(BOOL)) == 0)
        type = "c";
    
    [self readType:type data:data];
}

- (void*)decodeBytesWithReturnedLength:(NSUInteger*)outLength
{
    NSParameterAssert(outLength);
    
    *outLength = 0;
    NSString* string;
    if(![self decodeSharedString:&string])
        return NULL;
    if(![string isEqualToString:@"+"])
        return NULL;
    
    int length;
    if(![self decodeInt:&length])
        return NULL;
    
    void* bytes = malloc(length);
    if(!bytes)
        return NULL;
    
    if(![self readBytes:bytes length:length])
    {
        free(bytes);
        return NULL;
    }
    
    // The spec requires that we return the data in a buffer which lives until the autorelease pool pops.
    // To achieve this perfectly, it would require me to add non-ARC code.
    // I currently do not want to do this and fake this by freeing the buffer together with the archiver.
    // This approach is not very efficient but I doubt that this will cause any harm.
    NSData* data = [[NSData alloc] initWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    if(!_buffers)
        _buffers = [[NSMutableArray alloc] init];
    [_buffers addObject:data];
    
    *outLength = length;
    return bytes;
}

- (id)decodeObject
{
    id obj;
    [self readObject:&obj];
    return obj;
}

- (NSInteger)versionForClassName:(NSString *)className
{
    NSParameterAssert(className);
    return ((NSNumber*)_versionByClassName[className]).integerValue;
}

@end
