#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Joins a live stream's video part and its separate audio part into one MPEG-TS segment. The
// video is copied. The audio is encoded to AAC, which Cast devices play in TS, by one encoder
// that lives across segments: restarting it every second would be audible. Not thread safe.
@interface FFMpegCastMuxer : NSObject

// audioPath is nil when the audio part is missing, and silence takes its place.
- (bool)muxVideoPath:(NSString *)videoPath audioPath:(NSString * _Nullable)audioPath to:(NSString *)outPath index:(int)index offsetSeconds:(double)offsetSeconds;

@end

NS_ASSUME_NONNULL_END
