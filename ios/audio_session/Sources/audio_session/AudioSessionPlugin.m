#import "./include/audio_session/AudioSessionPlugin.h"
#import "./include/audio_session/DarwinAudioSession.h"


@implementation AudioSessionPlugin {
    DarwinAudioSession *_darwinAudioSession;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    AudioSessionPlugin *plugin = [[AudioSessionPlugin alloc] initWithRegistrar:registrar];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _darwinAudioSession = [[DarwinAudioSession alloc] initWithRegistrar:registrar];
    return self;
}



- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
   
}

@end
