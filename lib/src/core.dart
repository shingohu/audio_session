import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart' show experimental;

import 'android.dart';
import 'darwin.dart';

/// Manages a single audio session to be used across different audio plugins in
/// your app. [AudioSession] will configure your app by describing to the operating
/// system the nature of the audio that your app intends to play.
///
/// You obtain the singleton [instance] of this class, [configure] it during
/// your app's startup, and then use other plugins to play or record audio. An
/// app will typically not call [setActive] directly since individual audio
/// plugins will call this before they play or record audio.
class AudioSession {
  static AudioSession? _instance;

  /// The singleton instance across all Flutter engines.
  static AudioSession get instance {
    _instance ??= AudioSession._();
    return _instance!;
  }

  ///android default audio focus request gain type
  late AndroidAudioFocusGainType _defaultAndroidFocusGainType =
      AndroidAudioFocusGainType.gainTransient;

  ///ios default audio session de active options
  late AVAudioSessionSetActiveOptions _defaultAVAudioSessionSetActiveOptions =
      AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation;

  final audioManager = Platform.isAndroid ? AndroidAudioManager() : null;
  final avAudioSession = Platform.isIOS ? AVAudioSession() : null;

  final StreamController<AudioInterruptionEvent> _interruptionEventSubject =
      StreamController.broadcast();
  final StreamController<void> _becomingNoisyEventSubject =
      StreamController.broadcast();
  final StreamController<AudioDevicesChangedEvent> _devicesChangedEventSubject =
      StreamController.broadcast();
  final StreamController<List<AudioDevice>> _devicesSubject =
      StreamController.broadcast();

  AVAudioSessionRouteDescription? _previousAVAudioSessionRoute;

  ///全部音频设备
  List<AudioDevice> _audioDevices = [];

  ///获取全部音频设备
  List<AudioDevice> get audioDevices => _audioDevices.toList();

  ///输出音频设备(iOS上与category有关,并且会随着category的改变而改变)
  ///android上会把所有的可以输出音频的路由都返回
  List<AudioDevice> get outputDevices =>
      _audioDevices.where((element) => element.isOutput).toList();

  ///输入音频设备
  List<AudioDevice> get inputDevices =>
      _audioDevices.where((element) => element.isInput).toList();

  ///是否连接有蓝牙设备
  bool get isBluetoothPlugged {
    return _audioDevices.any((device) {
      return device.type == AudioDeviceType.bluetoothA2dp ||
          device.type == AudioDeviceType.bluetoothLe ||
          device.type == AudioDeviceType.bluetoothSco;
    });
  }

  ///是否连接有有线耳机(优先级最高)
  bool get isWirelessHeadsetPlugged {
    return _audioDevices.any((device) {
      return device.type == AudioDeviceType.wiredHeadset ||
          device.type == AudioDeviceType.wiredHeadphones;
    });
  }

  AudioSession._() {
    avAudioSession?.interruptionNotificationStream.listen((notification) {
      switch (notification.type) {
        case AVAudioSessionInterruptionType.began:
          if (notification.wasSuspended != true) {
            _interruptionEventSubject.add(
                AudioInterruptionEvent(true, AudioInterruptionType.unknown));
          }
          break;
        case AVAudioSessionInterruptionType.ended:
          _interruptionEventSubject.add(AudioInterruptionEvent(
              false,
              notification.options
                      .contains(AVAudioSessionInterruptionOptions.shouldResume)
                  ? AudioInterruptionType.pause
                  : AudioInterruptionType.unknown));
          break;
      }
    });
    avAudioSession?.routeChangeStream
        .where((routeChange) =>
            routeChange.reason ==
                AVAudioSessionRouteChangeReason.oldDeviceUnavailable ||
            routeChange.reason ==
                AVAudioSessionRouteChangeReason.newDeviceAvailable)
        .listen((routeChange) async {
      if (routeChange.reason ==
          AVAudioSessionRouteChangeReason.oldDeviceUnavailable) {
        // TODO: Check specifically if headphones were unplugged.
        _becomingNoisyEventSubject.add(null);
      }
      final currentRoute = await avAudioSession!.currentRoute;
      final previousRoute = _previousAVAudioSessionRoute ?? currentRoute;
      _previousAVAudioSessionRoute = currentRoute;
      final inputPortsAdded =
          currentRoute.inputs.difference(previousRoute.inputs);
      final outputPortsAdded =
          currentRoute.outputs.difference(previousRoute.outputs);
      final inputPortsRemoved =
          previousRoute.inputs.difference(currentRoute.inputs);
      final outputPortsRemoved =
          previousRoute.outputs.difference(currentRoute.outputs);
      final inputPorts = inputPortsAdded.union(inputPortsRemoved);
      final outputPorts = outputPortsAdded.union(outputPortsRemoved);

      final devicesAdded = inputPortsAdded
          .union(outputPortsAdded)
          .map((port) => _darwinPort2device(port,
              inputPorts: inputPorts, outputPorts: outputPorts))
          .toSet();
      final devicesRemoved = inputPortsRemoved
          .union(outputPortsRemoved)
          .map((port) => _darwinPort2device(port,
              inputPorts: inputPorts, outputPorts: outputPorts))
          .toSet();

      _devicesChangedEventSubject.add(AudioDevicesChangedEvent(
        devicesAdded: devicesAdded,
        devicesRemoved: devicesRemoved,
      ));

      _refreshAllDevices();
    });
    audioManager?.becomingNoisyEventStream
        .listen((event) => _becomingNoisyEventSubject.add(null));

    audioManager?.setAudioDevicesAddedListener((devices) async {
      _devicesChangedEventSubject.add(AudioDevicesChangedEvent(
        devicesAdded: devices.map(_androidDevice2device).toSet(),
        devicesRemoved: {},
      ));
      _refreshAllDevices();
    });
    audioManager?.setAudioDevicesRemovedListener((devices) async {
      _devicesChangedEventSubject.add(AudioDevicesChangedEvent(
        devicesAdded: {},
        devicesRemoved: devices.map(_androidDevice2device).toSet(),
      ));
      _refreshAllDevices();
    });
    _refreshAllDevices();
  }

  /// A stream of [AudioInterruptionEvent]s.
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      _interruptionEventSubject.stream;

  /// A stream of events that occur when audio becomes noisy (e.g. due to
  /// unplugging the headphones).
  Stream<void> get becomingNoisyEventStream =>
      _becomingNoisyEventSubject.stream;

  /// A stream emitting events whenever devices are added or removed to the set
  /// of available devices.
  Stream<AudioDevicesChangedEvent> get devicesChangedEventStream =>
      _devicesChangedEventSubject.stream;

  /// A stream emitting the set of connected devices whenever there is a change.
  Stream<List<AudioDevice>> get devicesStream => _devicesSubject.stream;

  /// Completes with a list of available audio devices.
  Future<List<AudioDevice>> getDevices(
      {bool includeInputs = true, bool includeOutputs = true}) async {
    final devices = <AudioDevice>{};
    if (audioManager != null) {
      var flags = AndroidGetAudioDevicesFlags.none;
      if (includeInputs) flags |= AndroidGetAudioDevicesFlags.inputs;
      if (includeOutputs) flags |= AndroidGetAudioDevicesFlags.outputs;
      final androidDevices = await audioManager!.getDevices(flags);
      devices.addAll(androidDevices.map(_androidDevice2device).toSet());
    } else if (avAudioSession != null) {
      final currentRoute = await avAudioSession!.currentRoute;
      if (includeInputs) {
        final darwinInputs = await avAudioSession!.availableInputs;
        devices.addAll(darwinInputs
            .map((port) => _darwinPort2device(
                  port,
                  inputPorts: darwinInputs,
                  outputPorts: currentRoute.outputs,
                ))
            .toSet());
        devices.addAll(currentRoute.inputs.map((port) => _darwinPort2device(
              port,
              inputPorts: currentRoute.inputs,
              outputPorts: currentRoute.outputs,
            )));
      }
      if (includeOutputs) {
        devices.addAll(currentRoute.outputs.map((port) => _darwinPort2device(
              port,
              inputPorts: currentRoute.inputs,
              outputPorts: currentRoute.outputs,
            )));
      }
    }
    if (includeInputs && includeOutputs) {
      _checkDifferentDevices(devices.toList());
    }
    return devices.toList();
  }

  _Debouncer _debouncer = _Debouncer(delay: const Duration(milliseconds: 100));

  ///获取全部的音频设备
  void _refreshAllDevices() async {
    _debouncer.run(() async {
      List<AudioDevice> devices = (await getDevices());
      _checkDifferentDevices(devices);
    });
  }

  ///判断与已经缓存的是否一致
  void _checkDifferentDevices(List<AudioDevice> devices) async {
    bool different = false;
    if (devices.length == _audioDevices.length) {
      for (int i = 0; i < devices.length; i++) {
        if (devices.elementAt(i) != _audioDevices.elementAt(i)) {
          different = true;
          break;
        }
      }
    } else {
      different = true;
    }
    if (different) {
      _audioDevices = devices;
      _devicesSubject.add(_audioDevices);
    }
  }

  ///请求或者释放音频焦点
  Future<bool> setActive(bool active,
      {AndroidAudioFocusGainType? androidAudioFocusGainType,
      AndroidAudioAttributes? androidAudioAttributes,
      bool? androidWillPauseWhenDucked,
      AVAudioSessionSetActiveOptions? avOptions}) async {
    if (Platform.isAndroid) {
      if (!active) {
        return await audioManager!.abandonAudioFocus();
      } else {
        final pauseWhenDucked = androidWillPauseWhenDucked ?? false;
        var ducked = false;
        return await audioManager!.requestAudioFocus(
            new AndroidAudioFocusRequest(
                gainType:
                    androidAudioFocusGainType ?? _defaultAndroidFocusGainType,
                audioAttributes: androidAudioAttributes,
                willPauseWhenDucked: pauseWhenDucked,
                onAudioFocusChanged: (focus) {
                  switch (focus) {
                    case AndroidAudioFocus.gain:
                      _interruptionEventSubject.add(AudioInterruptionEvent(
                          false,
                          ducked
                              ? AudioInterruptionType.duck
                              : AudioInterruptionType.pause));
                      ducked = false;
                      break;
                    case AndroidAudioFocus.loss:
                      _interruptionEventSubject.add(AudioInterruptionEvent(
                          true, AudioInterruptionType.unknown));
                      ducked = false;
                      break;
                    case AndroidAudioFocus.lossTransient:
                      _interruptionEventSubject.add(AudioInterruptionEvent(
                          true, AudioInterruptionType.pause));
                      ducked = false;
                      break;
                    case AndroidAudioFocus.lossTransientCanDuck:
                      // We enforce the "will pause when ducked" configuration by
                      // sending the app a pause event instead of a duck event.
                      _interruptionEventSubject.add(AudioInterruptionEvent(
                          true,
                          pauseWhenDucked
                              ? AudioInterruptionType.pause
                              : AudioInterruptionType.duck));
                      if (!pauseWhenDucked) ducked = true;
                      break;
                  }
                }));
      }
    } else if (Platform.isIOS) {
      if (active) {
        return await avAudioSession!.setActive(active).catchError((error) {
          print(error);
          return false;
        });
      } else {
        return await avAudioSession!
            .setActive(active,
                avOptions: avOptions ?? _defaultAVAudioSessionSetActiveOptions)
            .catchError((error) {
          print(error);
          return false;
        });
      }
    }
    return true;
  }

  ///是否正在通话中
  Future<bool> isInCall() async {
    if (Platform.isAndroid) {
      return (await audioManager!.getMode()) == AndroidAudioHardwareMode.inCall;
    } else if (Platform.isIOS) {
      return await avAudioSession!.isTelephoneCalling;
    }
    return false;
  }

  ///set ios audio session category
  Future<void> setCategory(AVAudioSessionCategory? category,
      {AVAudioSessionCategoryOptions? options,
      AVAudioSessionMode mode = AVAudioSessionMode.defaultMode,
      AVAudioSessionRouteSharingPolicy policy =
          AVAudioSessionRouteSharingPolicy.defaultPolicy}) async {
    if (Platform.isIOS) {
      bool shouldSetCategory = true;
      AVAudioSessionCategory? previousCategory = await avAudioSession?.category;
      if (previousCategory == category) {
        AVAudioSessionMode? previousMode = await avAudioSession?.mode;
        if (previousMode == mode) {
          AVAudioSessionCategoryOptions? previousOptions =
              await avAudioSession?.categoryOptions;
          if (previousOptions == options) {
            AVAudioSessionRouteSharingPolicy? previousPolicy =
                await avAudioSession?.routeSharingPolicy;
            if (previousPolicy == policy) {
              shouldSetCategory = false;
            }
          }
        }
      }
      if (shouldSetCategory) {
        ///设置category会改变音频输入输出设备
        await avAudioSession!
            .setCategory(category, options, mode, policy)
            .catchError((error) {
          print(error);
        });
        _refreshAllDevices();
      }
    }
  }

  static AudioDeviceType _darwinPort2type(AVAudioSessionPort port,
      {Set<AVAudioSessionPortDescription> inputPorts = const {}}) {
    switch (port) {
      case AVAudioSessionPort.builtInMic:
        return AudioDeviceType.builtInMic;
      case AVAudioSessionPort.headsetMic:
        return AudioDeviceType.wiredHeadset;
      case AVAudioSessionPort.lineIn:
        return AudioDeviceType.dock;
      case AVAudioSessionPort.airPlay:
        return AudioDeviceType.airPlay;
      case AVAudioSessionPort.bluetoothA2dp:
        return AudioDeviceType.bluetoothA2dp;
      case AVAudioSessionPort.bluetoothLe:
        return AudioDeviceType.bluetoothLe;
      case AVAudioSessionPort.builtInReceiver:
        return AudioDeviceType.builtInEarpiece;
      case AVAudioSessionPort.builtInSpeaker:
        return AudioDeviceType.builtInSpeaker;
      case AVAudioSessionPort.hdmi:
        return AudioDeviceType.hdmi;
      case AVAudioSessionPort.headphones:
        return inputPorts
                .map((desc) => desc.portType)
                .contains(AVAudioSessionPort.headsetMic)
            ? AudioDeviceType.wiredHeadset
            : AudioDeviceType.wiredHeadphones;
      case AVAudioSessionPort.lineOut:
        return AudioDeviceType.dock;
      case AVAudioSessionPort.avb:
        return AudioDeviceType.avb;
      case AVAudioSessionPort.bluetoothHfp:
        return AudioDeviceType.bluetoothSco;
      case AVAudioSessionPort.displayPort:
        return AudioDeviceType.displayPort;
      case AVAudioSessionPort.carAudio:
        return AudioDeviceType.carAudio;
      case AVAudioSessionPort.fireWire:
        return AudioDeviceType.fireWire;
      case AVAudioSessionPort.pci:
        return AudioDeviceType.pci;
      case AVAudioSessionPort.thunderbolt:
        return AudioDeviceType.thunderbolt;
      case AVAudioSessionPort.usbAudio:
        return AudioDeviceType.usbAudio;
      case AVAudioSessionPort.virtual:
        return AudioDeviceType.virtual;
    }
  }

  static AudioDevice _darwinPort2device(
    AVAudioSessionPortDescription port, {
    Set<AVAudioSessionPortDescription> inputPorts = const {},
    Set<AVAudioSessionPortDescription> outputPorts = const {},
  }) {
    return AudioDevice(
      id: port.uid,
      name: port.portName,
      isInput: inputPorts.contains(port),
      isOutput: outputPorts.contains(port),
      type: _darwinPort2type(port.portType, inputPorts: inputPorts),
    );
  }

  static AudioDeviceType _androidType2type(AndroidAudioDeviceType type) {
    switch (type) {
      case AndroidAudioDeviceType.unknown:
        return AudioDeviceType.unknown;
      case AndroidAudioDeviceType.builtInEarpiece:
        return AudioDeviceType.builtInEarpiece;
      case AndroidAudioDeviceType.builtInSpeaker:
        return AudioDeviceType.builtInSpeaker;
      case AndroidAudioDeviceType.wiredHeadset:
        return AudioDeviceType.wiredHeadset;
      case AndroidAudioDeviceType.wiredHeadphones:
        return AudioDeviceType.wiredHeadphones;
      case AndroidAudioDeviceType.lineAnalog:
        return AudioDeviceType.lineAnalog;
      case AndroidAudioDeviceType.lineDigital:
        return AudioDeviceType.lineDigital;
      case AndroidAudioDeviceType.bluetoothSco:
        return AudioDeviceType.bluetoothSco;
      case AndroidAudioDeviceType.bluetoothA2dp:
        return AudioDeviceType.bluetoothA2dp;
      case AndroidAudioDeviceType.hdmi:
        return AudioDeviceType.hdmi;
      case AndroidAudioDeviceType.hdmiArc:
        return AudioDeviceType.hdmiArc;
      case AndroidAudioDeviceType.usbDevice:
        return AudioDeviceType.usbAudio;
      case AndroidAudioDeviceType.usbAccessory:
        return AudioDeviceType.usbAudio;
      case AndroidAudioDeviceType.dock:
        return AudioDeviceType.dock;
      case AndroidAudioDeviceType.fm:
        return AudioDeviceType.fm;
      case AndroidAudioDeviceType.builtInMic:
        return AudioDeviceType.builtInMic;
      case AndroidAudioDeviceType.fmTuner:
        return AudioDeviceType.fmTuner;
      case AndroidAudioDeviceType.tvTuner:
        return AudioDeviceType.tvTuner;
      case AndroidAudioDeviceType.telephony:
        return AudioDeviceType.telephony;
      case AndroidAudioDeviceType.auxLine:
        return AudioDeviceType.auxLine;
      case AndroidAudioDeviceType.ip:
        return AudioDeviceType.ip;
      case AndroidAudioDeviceType.bus:
        return AudioDeviceType.bus;
      case AndroidAudioDeviceType.usbHeadset:
        return AudioDeviceType.usbAudio;
      case AndroidAudioDeviceType.hearingAid:
        return AudioDeviceType.hearingAid;
      case AndroidAudioDeviceType.builtInSpeakerSafe:
        return AudioDeviceType.builtInSpeakerSafe;
      case AndroidAudioDeviceType.remoteSubmix:
        return AudioDeviceType.remoteSubmix;
      case AndroidAudioDeviceType.bleHeadset:
        return AudioDeviceType.bleHeadset;
      case AndroidAudioDeviceType.bleSpeaker:
        return AudioDeviceType.bleSpeaker;
    }
  }

  static AudioDevice _androidDevice2device(AndroidAudioDeviceInfo device) {
    return AudioDevice(
      id: device.id.toString(),
      name: device.productName,
      isInput: device.isSource,
      isOutput: device.isSink,
      type: _androidType2type(device.type),
    );
  }
}

class _Debouncer {
  final Duration delay;
  Timer? _timer;

  _Debouncer({required this.delay});

  void run(void Function() action) {
    _timer?.cancel(); // 取消之前的计时器
    _timer = Timer(delay, () {
      action();
      _timer = null; // 计时器完成后将其设置为null
    }); // 启动新的计时器
  }
}

/// An audio interruption event.
class AudioInterruptionEvent {
  /// Whether the interruption is beginning or ending.
  final bool begin;

  /// The type of interruption.
  final AudioInterruptionType type;

  AudioInterruptionEvent(this.begin, this.type);
}

/// The type of audio interruption.
enum AudioInterruptionType {
  /// Audio should be paused during the interruption.
  pause,

  /// Audio should be ducked during the interruption.
  duck,

  /// Audio should be paused, possibly indefinitely.
  unknown
}

/// An event capturing the addition or removal of connected devices.
class AudioDevicesChangedEvent {
  /// The audio devices just made available.
  final Set<AudioDevice> devicesAdded;

  /// The audio devices just made unavailable.
  final Set<AudioDevice> devicesRemoved;

  AudioDevicesChangedEvent({
    this.devicesAdded = const {},
    this.devicesRemoved = const {},
  });
}

/// Information about an audio device. If you require platform specific device
/// details, use [AVAudioSession] and [AndroidAudioManager] directly.
class AudioDevice {
  /// The unique ID of the device.
  final String id;

  /// The name of the device.
  final String name;

  /// Whether this device is an input.
  final bool isInput;

  /// Whether this device is an output.
  final bool isOutput;

  /// The type of this device.
  final AudioDeviceType type;

  AudioDevice({
    required this.id,
    required this.name,
    required this.isInput,
    required this.isOutput,
    required this.type,
  });

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(Object other) => other is AudioDevice && id == other.id;

  @override
  String toString() =>
      'AudioDevice(id:$id,name:$name,isInput:$isInput,isOutput:$isOutput,type:$type)';
}

/// An enumeration of the different audio device types.
@experimental
enum AudioDeviceType {
  /// Unknown type.
  unknown,

  /// The phone earpiece used for listening to calls.
  builtInEarpiece,

  /// The built-in speaker.
  builtInSpeaker,

  /// A wired headset with both microphone and earphones.
  wiredHeadset,

  /// Wired headphones.
  wiredHeadphones,

  /// The microphone on a headset.
  headsetMic,

  /// An analog line connection.
  lineAnalog,

  /// A digital line connection.
  lineDigital,

  /// A bluetooth device typically used for telephony.
  bluetoothSco,

  /// A bluetooth device supporting the A2DP profile.
  bluetoothA2dp,

  /// An HDMI connection.
  hdmi,

  /// The audio return channel of an HDMI connection.
  hdmiArc,

  /// A USB audio device.
  usbAudio,

  /// A device associated with a dock.
  dock,

  /// An FM transmission device.
  fm,

  /// The built-in microphone.
  builtInMic,

  /// An FM receiver device.
  fmTuner,

  /// A TV receiver device.
  tvTuner,

  /// A transmitter for the telephony network.
  telephony,

  /// An auxiliary line connector.
  auxLine,

  /// A device connected over IP.
  ip,

  /// A device used to communicate with external audio systems.
  bus,

  /// A hearing aid.
  hearingAid,

  /// An AirPlay device.
  airPlay,

  /// A Bluetooth LE device.
  bluetoothLe,

  /// An Audio Video Bridging device.
  avb,

  /// A DisplayPort device.
  displayPort,

  /// A Car Audio connection.
  carAudio,

  /// A FireWire device.
  fireWire,

  /// A PCI device.
  pci,

  /// A Thunderbolt device.
  thunderbolt,

  /// A connection not corresponding to a physical device.
  virtual,

  /// A built-in speaker used for outputting sounds like notifications and
  /// alarms.
  builtInSpeakerSafe,

  /// Android internal
  remoteSubmix,

  ///Android ble audio device
  bleHeadset,

  ///Android ble audio device
  bleSpeaker,
}
