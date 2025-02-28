import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart' show experimental;
import 'package:rxdart/rxdart.dart';

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

  final androidAudioManager = Platform.isAndroid ? AndroidAudioManager() : null;
  final iOSAudioSession = Platform.isIOS ? AVAudioSession() : null;
  final _interruptionEventSubject = PublishSubject<AudioInterruptionEvent>();
  final _becomingNoisyEventSubject = PublishSubject<void>();
  final _devicesChangedEventSubject =
      PublishSubject<AudioDevicesChangedEvent>();
  late final BehaviorSubject<Set<AudioDevice>> _devicesSubject;
  AVAudioSessionRouteDescription? _previousAVAudioSessionRoute;

  AudioSession._() {
    _devicesSubject = BehaviorSubject<Set<AudioDevice>>(
      onListen: () async {
        _devicesSubject.add(await getDevices());
      },
    );
    iOSAudioSession?.interruptionNotificationStream.listen((notification) {
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
    iOSAudioSession?.routeChangeStream
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
      final currentRoute = await iOSAudioSession!.currentRoute;
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

      if (_devicesSubject.hasListener) {
        _devicesSubject.add(await getDevices());
      }
    });
    androidAudioManager?.becomingNoisyEventStream
        .listen((event) => _becomingNoisyEventSubject.add(null));

    androidAudioManager?.setAudioDevicesAddedListener((devices) async {
      _devicesChangedEventSubject.add(AudioDevicesChangedEvent(
        devicesAdded: devices.map(_androidDevice2device).toSet(),
        devicesRemoved: {},
      ));
      if (_devicesSubject.hasListener) {
        _devicesSubject.add(await getDevices());
      }
    });
    androidAudioManager?.setAudioDevicesRemovedListener((devices) async {
      _devicesChangedEventSubject.add(AudioDevicesChangedEvent(
        devicesAdded: {},
        devicesRemoved: devices.map(_androidDevice2device).toSet(),
      ));
      if (_devicesSubject.hasListener) {
        _devicesSubject.add(await getDevices());
      }
    });
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
  Stream<Set<AudioDevice>> get devicesStream => _devicesSubject.stream;

  /// Completes with a list of available audio devices.
  Future<Set<AudioDevice>> getDevices(
      {bool includeInputs = true, bool includeOutputs = true}) async {
    final devices = <AudioDevice>{};
    if (androidAudioManager != null) {
      var flags = AndroidGetAudioDevicesFlags.none;
      if (includeInputs) flags |= AndroidGetAudioDevicesFlags.inputs;
      if (includeOutputs) flags |= AndroidGetAudioDevicesFlags.outputs;
      final androidDevices = await androidAudioManager!.getDevices(flags);
      devices.addAll(androidDevices.map(_androidDevice2device).toSet());
    } else if (iOSAudioSession != null) {
      final currentRoute = await iOSAudioSession!.currentRoute;
      if (includeInputs) {
        final darwinInputs = await iOSAudioSession!.availableInputs;
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
    return devices;
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
