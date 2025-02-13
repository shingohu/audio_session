#import <Flutter/Flutter.h>

@interface UUAudioSessionPlugin : NSObject<FlutterPlugin>

@property (readonly, nonatomic) FlutterMethodChannel *channel;

@end
