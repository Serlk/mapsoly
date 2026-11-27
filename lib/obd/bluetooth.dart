/// Bluetooth for the car adapter, whichever platform carries it.
library;

import 'dart:io';

import 'android_rfcomm_transport.dart';
import 'rfcomm_transport.dart';
import 'transport.dart';

export 'android_rfcomm_transport.dart' show BluetoothPermissionDenied;
export 'rfcomm_transport.dart' show BluetoothDevice;

/// Devices to offer in the adapter picker: on Linux what BlueZ knows, on
/// Android the paired ones. Pairing itself is done in the system settings.
Future<List<BluetoothDevice>> bluetoothDevices() => Platform.isAndroid
    ? AndroidBluetooth.instance.devices()
    : listBluetoothDevices();

/// Opens a serial (SPP) link to the adapter at [address].
ObdConnector bluetoothConnector(String address) => Platform.isAndroid
    ? () => AndroidRfcommTransport.connect(address)
    : () => RfcommObdTransport.connect(address);
