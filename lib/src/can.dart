// Core CAN types. Pure Dart, no Flutter, no FFI — so everything here is testable.
import 'dart:typed_data';

enum FrameDirection { rx, tx }

/// Payload lengths a CAN FD frame can carry, indexed by DLC code (0-15).
const fdLengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64];

/// Payload length for a DLC code. Classic CAN caps codes 9-15 at 8 bytes.
int dlcToLength(int dlc, {bool fd = true}) {
  final d = dlc.clamp(0, 15);
  return fd ? fdLengths[d] : (d > 8 ? 8 : d);
}

/// Smallest DLC code whose length holds [length] bytes.
int lengthToDlc(int length) {
  for (var i = 0; i < fdLengths.length; i++) {
    if (fdLengths[i] >= length) return i;
  }
  return 15;
}

/// The FD length [length] bytes are padded to on the wire (e.g. 10 -> 12).
int fdPaddedLength(int length) => fdLengths[lengthToDlc(length)];

class CanFrame {
  /// 11-bit or 29-bit identifier (without flag bits).
  final int id;
  final bool extended;
  final bool rtr;
  final Uint8List data;

  /// Host-side arrival time. Hardware timestamps, where a driver gives us one,
  /// are exposed separately via [hwTimestamp].
  final DateTime timestamp;
  final Duration? hwTimestamp;
  final FrameDirection direction;

  /// Channel index this frame came from, for multi-channel devices.
  final int channel;

  /// Set when this is an error frame rather than bus traffic: the controller's
  /// description of what went wrong. [id] and [data] are meaningless then.
  final String? error;

  /// CAN FD frame (FDF/EDL bit): up to 64 data bytes, no remote frames.
  final bool fd;

  /// Bit rate switch: the data phase ran at the data bitrate. FD only.
  final bool brs;

  /// Error state indicator: the sender was error passive. FD only.
  final bool esi;

  CanFrame({
    required this.id,
    required this.data,
    this.extended = false,
    this.rtr = false,
    DateTime? timestamp,
    this.hwTimestamp,
    this.direction = FrameDirection.rx,
    this.channel = 0,
    this.error,
    this.fd = false,
    this.brs = false,
    this.esi = false,
  }) : timestamp = timestamp ?? DateTime.now();

  /// An error frame, as reported by the controller.
  CanFrame.error(String this.error, {DateTime? timestamp, this.channel = 0})
      : id = 0,
        extended = false,
        rtr = false,
        fd = false,
        brs = false,
        esi = false,
        data = _empty,
        hwTimestamp = null,
        direction = FrameDirection.rx,
        timestamp = timestamp ?? DateTime.now();

  static final _empty = Uint8List(0);

  bool get isError => error != null;

  /// The same frame tagged with the app-side bus it arrived on. Overrides the
  /// driver's own channel index, which is meaningless once two interfaces are
  /// traced side by side.
  CanFrame withChannel(int ch) => CanFrame(
        id: id,
        data: data,
        extended: extended,
        rtr: rtr,
        timestamp: timestamp,
        hwTimestamp: hwTimestamp,
        direction: direction,
        channel: ch,
        error: error,
        fd: fd,
        brs: brs,
        esi: esi,
      );

  /// The DLC code on the wire: the length for classic CAN, the FD code (0-15)
  /// for FD frames, whose payload is padded to the next valid length.
  int get dlc => fd ? lengthToDlc(data.length) : data.length;

  /// 'FD' or 'FD BRS' (plus ' ESI'), empty for classic frames.
  String get fdLabel =>
      fd ? 'FD${brs ? ' BRS' : ''}${esi ? ' ESI' : ''}' : '';

  String get idHex => extended
      ? id.toRadixString(16).toUpperCase().padLeft(8, '0')
      : id.toRadixString(16).toUpperCase().padLeft(3, '0');

  String get dataHex =>
      data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');

  @override
  String toString() =>
      error ??
      '${extended ? 'x' : ''}$idHex [${data.length}]${fd ? ' $fdLabel' : ''} $dataHex';
}

/// Bitrates we offer in the UI. Every backend maps these to its own encoding.
const kStandardBitrates = [
  10000, 20000, 33333, 50000, 83333, 100000,
  125000, 250000, 500000, 800000, 1000000,
];

/// CAN FD data-phase bitrates offered in the UI.
const kFdDataBitrates = [1000000, 2000000, 4000000, 5000000, 8000000];

class CanDevice {
  /// Backend id, e.g. 'slcan', 'pcan', 'socketcan', 'vector', 'virtual'.
  final String backend;

  /// Opaque, backend-specific address (serial port path, channel handle, ifname).
  final String address;
  final String label;

  const CanDevice(this.backend, this.address, this.label);

  @override
  String toString() => label;

  @override
  bool operator ==(Object other) =>
      other is CanDevice && other.backend == backend && other.address == address;

  @override
  int get hashCode => Object.hash(backend, address);
}

class CanBusException implements Exception {
  final String message;
  CanBusException(this.message);
  @override
  String toString() => 'CanBusException: $message';
}

/// Throws unless [f] can go out on a channel in the given mode: FD frames
/// need an FD channel, cannot be remote frames and carry at most 64 bytes;
/// classic frames at most 8.
void checkSendable(CanFrame f, {required bool fdMode}) {
  if (f.fd) {
    if (!fdMode) {
      throw CanBusException('the channel is not in CAN FD mode — reconnect with an FD data bitrate');
    }
    if (f.rtr) throw CanBusException('CAN FD has no remote frames');
    if (f.data.length > 64) throw CanBusException('CAN FD frames carry at most 64 bytes');
  } else if (f.data.length > 8) {
    throw CanBusException('classic CAN frames carry at most 8 bytes — send it as CAN FD');
  }
}

/// Prescaler and segment lengths (in time quanta) for one bit phase.
typedef BitTiming = ({int brp, int tseg1, int tseg2, int sjw});

/// Bit timing for [bitrate] from a [clock] Hz controller clock, sample point
/// near 80 %, or null when no prescaler divides the clock exactly.
BitTiming? bitTiming(int clock, int bitrate,
    {required int maxTseg1, required int maxTseg2, required int maxSjw}) {
  for (var brp = 1; brp <= 1024; brp++) {
    if (clock % (brp * bitrate) != 0) continue;
    final tq = clock ~/ (brp * bitrate);
    if (tq < 5) return null; // fewer quanta than a usable bit needs
    if (tq > 1 + maxTseg1 + maxTseg2) continue;
    var tseg1 = (tq * 0.8).round() - 1;
    var tseg2 = tq - 1 - tseg1;
    if (tseg2 > maxTseg2) {
      tseg2 = maxTseg2;
      tseg1 = tq - 1 - tseg2;
    }
    if (tseg1 > maxTseg1 || tseg1 < 1 || tseg2 < 1) continue;
    return (brp: brp, tseg1: tseg1, tseg2: tseg2, sjw: tseg2 < maxSjw ? tseg2 : maxSjw);
  }
  return null;
}

/// What every hardware backend must provide. Keeping this surface tiny is what
/// makes adding a device family cheap and lets the UI stay backend-agnostic.
abstract class CanBus {
  Stream<CanFrame> get frames;

  /// Non-fatal driver notices (bus-off, error frames, rx overruns).
  Stream<String> get status;

  /// Opens the channel at [bitrate]. A non-null [dataBitrate] opens it in
  /// CAN FD mode with that data-phase bitrate; FD frames can only be sent and
  /// received then.
  Future<void> open(String address, int bitrate, {int? dataBitrate});
  Future<void> close();
  Future<void> send(CanFrame frame);
  bool get isOpen;
}

/// Backends advertise themselves here so the UI never hardcodes a device list.
abstract class CanBackend {
  String get id;
  String get name;

  /// True when the platform and driver library are actually present.
  bool get available;

  /// True when [CanBus.open] accepts a data bitrate (CAN FD).
  bool get supportsFd;

  /// Reason [available] is false — shown in the UI so a missing driver is
  /// diagnosable instead of the device list just being mysteriously empty.
  String get unavailableReason => '';

  Future<List<CanDevice>> discover();
  CanBus create();
}
