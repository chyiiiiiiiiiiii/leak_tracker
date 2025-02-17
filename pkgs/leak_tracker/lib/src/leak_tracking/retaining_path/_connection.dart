// Copyright 2023 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer';

import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _log = Logger('_connection.dart');

class Connection {
  Connection(this.service, this.isolates);

  final List<String> isolates;
  final VmService service;
}

Completer<Connection>? _completer;

void disconnect() => _completer = null;

Future<Connection> connect() async {
  if (_completer != null) {
    return await _completer!.future;
  }

  _log.info('Connecting to vm service protocol...');

  final completer = _completer = Completer<Connection>();

  final info = await Service.getInfo();

  final uri = info.serverWebSocketUri;
  if (uri == null) {
    throw StateError(
      'Leak troubleshooting is not available in release mode. Run your application or test with flag "--debug" '
      '(Not supported for Flutter yet: https://github.com/flutter/flutter/issues/127331).',
    );
  }

  final service = await _connectWithWebSocket(uri, (error) {
    throw error ?? Exception('Error connecting to service protocol');
  });
  await service.getVersion(); // Warming up and validating the connection.
  final isolates = await _getIdForTwoIsolates(service);

  final result = Connection(service, isolates);
  completer.complete(result);
  return result;
}

/// Tries to wait for two isolates to be available.
///
/// Depending on environment (command line / IDE, Flutter / Dart), isolates may have different names,
/// and there can be one or two. Sometimes the second one appears with latency.
/// And sometimes there are two isolates with name 'main'.
Future<List<String>> _getIdForTwoIsolates(VmService service) async {
  _log.info('Started loading isolates...');

  final result = <String>[];

  const isolatesToGet = 2;
  const watingTime = Duration(seconds: 2);
  final stopwatch = Stopwatch()..start();
  while (result.length < isolatesToGet && stopwatch.elapsed < watingTime) {
    result.clear();
    await _forEachIsolate(
      service,
      (IsolateRef r) async => result.add(r.id!),
    );
    if (result.length < isolatesToGet) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  if (result.isEmpty) {
    throw StateError('Could not connect to isolates.');
  }

  _log.info('Ended loading isolates.');
  return result;
}

Future<VmService> _connectWithWebSocket(
  Uri uri,
  void Function(Object? error) onError,
) async {
  final ws = WebSocketChannel.connect(uri);
  final stream = ws.stream.handleError(onError);
  final service = VmService(
    stream,
    (String message) {
      ws.sink.add(message);
    },
  );

  if (ws.closeCode != null) {
    onError(ws.closeReason);
    return service;
  }

  return service;
}

/// Executes `callback` for each isolate, and waiting for all callbacks to
/// finish before completing.
Future<void> _forEachIsolate(
  VmService service,
  Future<void> Function(IsolateRef) callback,
) async {
  final vm = await service.getVM();
  final futures = <Future>[];
  for (final isolate in vm.isolates ?? []) {
    futures.add(callback(isolate));
  }
  await Future.wait(futures);
}
