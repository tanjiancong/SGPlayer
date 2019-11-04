//
//  SGVideoDecoder.m
//  SGPlayer iOS
//
//  Created by Single on 2018/8/16.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGVideoDecoder.h"
#import "SGFrame+Internal.h"
#import "SGPacket+Internal.h"
#import "SGDecodeContext.h"
#import "SGVideoFrame.h"

@interface SGVideoDecoder ()

{
    struct {
        BOOL needsKeyFrame;
        BOOL needsAlignment;
        NSUInteger outputCount;
    } _flags;
}

@property (nonatomic, strong, readonly) SGVideoFrame *lastFrame;
@property (nonatomic, strong, readonly) SGDecodeContext *codecContext;
@property (nonatomic, strong, readonly) SGCodecDescriptor *codecDescriptor;

@end

@implementation SGVideoDecoder

@synthesize options = _options;

- (instancetype)init
{
    if (self = [super init]) {
        self->_outputFromKeyFrame = YES;
    }
    return self;
}

- (void)dealloc
{
    [self destroy];
}

- (void)setup
{
    self->_flags.needsAlignment = YES;
    self->_codecContext = [[SGDecodeContext alloc] initWithTimebase:self->_codecDescriptor.timebase
                                                           codecpar:self->_codecDescriptor.codecpar
                                                         frameClass:[SGVideoFrame class]
                                                     frameReuseName:[SGVideoFrame commonReuseName]];
    self->_codecContext.options = self->_options;
    [self->_codecContext open];
}

- (void)destroy
{
    self->_flags.outputCount = 0;
    self->_flags.needsKeyFrame = YES;
    self->_flags.needsAlignment = YES;
    [self->_codecContext close];
    self->_codecContext = nil;
    [self->_lastFrame unlock];
    self->_lastFrame = nil;
}

#pragma mark - Control

- (void)flush
{
    self->_flags.outputCount = 0;
    self->_flags.needsKeyFrame = YES;
    self->_flags.needsAlignment = YES;
    [self->_codecContext flush];
    [self->_lastFrame unlock];
    self->_lastFrame = nil;
}

- (NSArray<__kindof SGFrame *> *)decode:(SGPacket *)packet
{
    NSMutableArray *ret = [NSMutableArray array];
    SGCodecDescriptor *cd = packet.codecDescriptor;
    NSAssert(cd, @"Invalid Codec Descriptor.");
    if (![cd isEqualCodecContextToDescriptor:self->_codecDescriptor]) {
        NSArray<SGFrame *> *objs = [self processPacket:nil];
        for (SGFrame *obj in objs) {
            [ret addObject:obj];
        }
        self->_codecDescriptor = [cd copy];
        [self destroy];
        [self setup];
    }
    [cd fillToDescriptor:self->_codecDescriptor];
    switch (packet.codecDescriptor.type) {
        case SGCodecTypeDecode: {
            NSArray<SGFrame *> *objs = [self processPacket:packet];
            for (SGFrame *obj in objs) {
                [ret addObject:obj];
            }
        }
            break;
        case SGCodecTypePadding: {
            
        }
            break;
    }
    self->_flags.outputCount += ret.count;
    return ret;
}

- (NSArray<__kindof SGFrame *> *)finish
{
    NSArray<SGFrame *> *objs = [self processPacket:nil];
    if (objs.count > 0) {
        [self->_lastFrame unlock];
    } else if (self->_lastFrame) {
        objs = @[self->_lastFrame];
    }
    self->_lastFrame = nil;
    self->_flags.outputCount += objs.count;
    return objs;
}

#pragma mark - Process

- (NSArray<__kindof SGFrame *> *)processPacket:(SGPacket *)packet
{
    if (!self->_codecContext || !self->_codecDescriptor) {
        return nil;
    }
    SGCodecDescriptor *cd = self->_codecDescriptor;
    NSArray *objs = [self->_codecContext decode:packet];
    objs = [self processFrames:objs done:!packet];
    objs = [self clipKeyFrames:objs];
    objs = [self clipFrames:objs timeRange:cd.timeRange];
    return objs;
}

- (NSArray<__kindof SGFrame *> *)processFrames:(NSArray<__kindof SGFrame *> *)frames done:(BOOL)done
{
    NSMutableArray *ret = [NSMutableArray array];
    for (SGAudioFrame *obj in frames) {
        [obj setCodecDescriptor:[self->_codecDescriptor copy]];
        [obj fill];
        [ret addObject:obj];
    }
    return ret;
}

- (NSArray<__kindof SGFrame *> *)clipKeyFrames:(NSArray<__kindof SGFrame *> *)frames
{
    if (self->_outputFromKeyFrame == NO ||
        self->_flags.needsKeyFrame == NO) {
        return frames;
    }
    NSMutableArray *ret = [NSMutableArray array];
    for (SGFrame *obj in frames) {
        if (self->_flags.needsKeyFrame == NO) {
            [ret addObject:obj];
        } else if (obj.core->key_frame) {
            [ret addObject:obj];
            self->_flags.needsKeyFrame = NO;
        } else {
            [obj unlock];
        }
    }
    return ret;
}

- (NSArray<__kindof SGFrame *> *)clipFrames:(NSArray<__kindof SGFrame *> *)frames timeRange:(CMTimeRange)timeRange
{
    if (frames.count <= 0) {
        return nil;
    }
    if (!SGCMTimeIsValid(timeRange.start, NO)) {
        return frames;
    }
    [self->_lastFrame unlock];
    self->_lastFrame = frames.lastObject;
    [self->_lastFrame lock];
    NSMutableArray *ret = [NSMutableArray array];
    for (SGFrame *obj in frames) {
        if (CMTimeCompare(obj.timeStamp, timeRange.start) < 0) {
            [obj unlock];
            continue;
        }
        if (SGCMTimeIsValid(timeRange.duration, NO) &&
            CMTimeCompare(obj.timeStamp, CMTimeRangeGetEnd(timeRange)) >= 0) {
            [obj unlock];
            continue;
        }
        if (self->_flags.needsAlignment) {
            self->_flags.needsAlignment = NO;
            CMTime start = timeRange.start;
            CMTime duration = CMTimeSubtract(CMTimeAdd(obj.timeStamp, obj.duration), start);
            if (CMTimeCompare(obj.timeStamp, start) > 0) {
                SGCodecDescriptor *cd = [[SGCodecDescriptor alloc] init];
                cd.track = obj.track;
                cd.metadata = obj.codecDescriptor.metadata;
                [obj setCodecDescriptor:cd];
                [obj fillWithTimeStamp:start decodeTimeStamp:start duration:duration];
            }
        }
        if (SGCMTimeIsValid(timeRange.duration, NO)) {
            CMTime start = obj.timeStamp;
            CMTime duration = CMTimeSubtract(CMTimeRangeGetEnd(timeRange), start);
            if (CMTimeCompare(obj.duration, duration) > 0) {
                SGCodecDescriptor *cd = [[SGCodecDescriptor alloc] init];
                cd.track = obj.track;
                cd.metadata = obj.codecDescriptor.metadata;
                [obj setCodecDescriptor:cd];
                [obj fillWithTimeStamp:start decodeTimeStamp:start duration:duration];
            }
        }
        [ret addObject:obj];
    }
    return ret;
}

@end
