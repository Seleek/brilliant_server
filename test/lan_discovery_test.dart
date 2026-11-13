import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bin/server.dart';

void main() {
  late RawDatagramSocket server;

  setUp(() async {
    server = await startLanDiscovery(
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
  });

  tearDown(() {
    server.close();
  });

  test('answers discovery requests with the Brilliant server marker', () async {
    final client =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(client.close);
    final response = Completer<Datagram>();
    final subscription = client.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = client.receive();
      if (datagram != null && !response.isCompleted) {
        response.complete(datagram);
      }
    });
    addTearDown(subscription.cancel);

    client.send(
      utf8.encode('BRILLIANT_DISCOVER_V1'),
      InternetAddress.loopbackIPv4,
      server.port,
    );

    final datagram = await response.future.timeout(const Duration(seconds: 1));
    expect(utf8.decode(datagram.data), 'BRILLIANT_SERVER_V1');
  });
}
