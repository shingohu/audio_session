package com.shingo.audio_session;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * AudioSessionPlugin
 */
public class AudioSessionPlugin implements FlutterPlugin, MethodCallHandler {
    private AndroidAudioManager androidAudioManager;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        BinaryMessenger messenger = flutterPluginBinding.getBinaryMessenger();
        androidAudioManager = new AndroidAudioManager(flutterPluginBinding.getApplicationContext(), messenger);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        androidAudioManager.dispose();
        androidAudioManager = null;
    }

    @Override
    public void onMethodCall(@NonNull final MethodCall call, @NonNull final Result result) {
    }

}
