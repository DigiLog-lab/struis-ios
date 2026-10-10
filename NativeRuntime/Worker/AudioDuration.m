#import <AVFoundation/AVFoundation.h>
#import <math.h>

// Apple decodes the actual audio bytes; unavailable formats use Codex's existing
// size-based estimate rather than a fabricated duration.
double hyotan_audio_duration(const unsigned char *bytes, size_t length) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:bytes length:length];
        AVAudioPlayer *audio = [[AVAudioPlayer alloc] initWithData:data error:nil];
        double duration = audio ? audio.duration : NAN;
        return isfinite(duration) && duration >= 0 ? duration : NAN;
    }
}
