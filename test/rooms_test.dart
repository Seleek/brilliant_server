import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import '../bin/server.dart';

void main() {
  late HttpServer server;
  final client = HttpClient();
  DateTime? horaPrueba;

  setUpAll(() async {
    final router = Router();
    registerRoomRoutes(router, clock: () => horaPrueba ?? DateTime.now());
    server = await shelf_io.serve(router.call, InternetAddress.loopbackIPv4, 0);
  });

  tearDownAll(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  test('crea y sincroniza una sala de hasta cuatro jugadores', () async {
    final tokens = {
      for (final username in [
        'host',
        'player2',
        'player3',
        'player4',
        'player5'
      ])
        username: JWT({'sub': username}).sign(SecretKey(jwtSecret)),
    };

    final (createStatus, created) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/create',
      token: tokens['host'],
      body: {'level': 1},
    );
    expect(createStatus, 201);
    final code = created['code'] as String;

    for (final username in ['player2', 'player3', 'player4']) {
      final (status, _) = await _request(
        client,
        server,
        'POST',
        '/api/rooms/join',
        token: tokens[username],
        body: {'code': code},
      );
      expect(status, 200);
    }

    final (fullStatus, fullBody) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/join',
      token: tokens['player5'],
      body: {'code': code},
    );
    expect(fullStatus, 409);
    expect(fullBody['error'], 'La sala está completa');

    final (prematureStatus, _) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/start',
      token: tokens['host'],
    );
    expect(prematureStatus, 409);

    final (invalidBoardStatus, _) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/ready',
      token: tokens['host'],
      body: {'cells': List<int?>.filled(49, null)..[0] = 1},
    );
    expect(invalidBoardStatus, 400);

    for (final username in ['host', 'player2', 'player3', 'player4']) {
      final (status, _) = await _request(
        client,
        server,
        'POST',
        '/api/rooms/$code/ready',
        token: tokens[username],
        body: {'cells': _initialCells()},
      );
      expect(status, 200);
    }

    final (unauthorizedStatus, _) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/start',
      token: tokens['player2'],
    );
    expect(unauthorizedStatus, 403);

    final (startStatus, started) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/start',
      token: tokens['host'],
    );
    expect(startStatus, 200);
    expect(started['phase'], 'partida');
    expect(started['dice'], hasLength(2));

    final (noTokenStatus, _) = await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
    );
    expect(noTokenStatus, 401);

    final finishers = ['host', 'player2', 'player3'];
    for (final username in finishers) {
      final (status, response) = await _request(
        client,
        server,
        'POST',
        '/api/rooms/$code/move',
        token: tokens[username],
        body: {
          'cells': _initialCells(),
          'passed': true,
          'completedZones': [
            {'id': 'red-zone', 'color': 'red'},
            {'id': 'green-zone', 'color': 'green'},
          ],
        },
      );
      expect(status, 200);
      expect(response['round'], 1);
      expect(response['scores'][username], 0);
    }

    final (finalMoveStatus, finalMove) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/move',
      token: tokens['player4'],
      body: {
        'cells': _initialCells(),
        'passed': true,
        'completedZones': [],
      },
    );
    expect(finalMoveStatus, 200);
    expect(finalMove['round'], 2);
    expect(finalMove['dice'], hasLength(2));
    expect(finalMove['allSubmitted'], isFalse);
  });

  test('el servidor calcula los puestos de una zona verde válida', () async {
    final hostToken = JWT({'sub': 'score-host'}).sign(SecretKey(jwtSecret));
    final guestToken = JWT({'sub': 'score-guest'}).sign(SecretKey(jwtSecret));
    final (_, created) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/create',
      token: hostToken,
      body: {'level': 4},
    );
    final code = created['code'] as String;

    await _request(
      client,
      server,
      'POST',
      '/api/rooms/join',
      token: guestToken,
      body: {'code': code},
    );
    for (final token in [hostToken, guestToken]) {
      final (status, _) = await _request(
        client,
        server,
        'POST',
        '/api/rooms/$code/ready',
        token: token,
        body: {'cells': _initialCells(4)},
      );
      expect(status, 200);
    }

    final (startStatus, started) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/start',
      token: hostToken,
    );
    expect(startStatus, 200);
    var dice = List<int>.from(started['dice'] as List);
    var intento = 0;
    while (!dice.contains(1) && intento < 100) {
      for (final token in [hostToken, guestToken]) {
        final (status, response) = await _request(
          client,
          server,
          'POST',
          '/api/rooms/$code/move',
          token: token,
          body: {
            'cells': _initialCells(4),
            'passed': true,
          },
        );
        expect(status, 200);
        if (token == guestToken)
          dice = List<int>.from(response['dice'] as List);
      }
      intento++;
    }
    expect(dice.contains(1), isTrue);

    final selectedDie = dice[0] == 1 ? 1 : 0;
    final value = dice[selectedDie];
    final hostCells = _initialCells(4)..[26] = value;
    final (hostMoveStatus, hostMove) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/move',
      token: hostToken,
      body: {
        'cells': hostCells,
        'passed': false,
        'selectedDie': selectedDie,
      },
    );
    expect(hostMoveStatus, 200);
    expect(hostMove['scores']['score-host'], 3);

    final guestCells = _initialCells(4)..[26] = value;
    final (guestMoveStatus, guestMove) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/move',
      token: guestToken,
      body: {
        'cells': guestCells,
        'passed': false,
        'selectedDie': selectedDie,
      },
    );
    expect(guestMoveStatus, 200);
    expect(guestMove['scores']['score-host'], 3);
    expect(guestMove['scores']['score-guest'], 2);
  });

  test('la votación unánime termina la partida de dos jugadores', () async {
    horaPrueba = DateTime.utc(2026, 1, 1);
    addTearDown(() => horaPrueba = null);
    final (code, tokens) = await _crearPartida(
      client,
      server,
      const ['disconnect-host', 'disconnect-guest'],
    );

    horaPrueba = horaPrueba!.add(const Duration(seconds: 61));
    final (pauseStatus, pause) = await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['disconnect-host'],
    );
    expect(pauseStatus, 200);
    expect(pause['paused'], isTrue);
    expect(pause['disconnectedUsername'], 'disconnect-guest');

    final (moveWhilePausedStatus, _) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/move',
      token: tokens['disconnect-host'],
      body: {'cells': _initialCells(), 'passed': true},
    );
    expect(moveWhilePausedStatus, 409);

    final (voteStatus, result) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/continue',
      token: tokens['disconnect-host'],
      body: const {},
    );
    expect(voteStatus, 200);
    expect(result['phase'], 'finalizada');
    expect(result['winner'], 'disconnect-host');
    final guest = (result['players'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((player) => player['username'] == 'disconnect-guest');
    expect(guest['eliminated'], isTrue);
    expect(guest['score'], 0);

    final (moveStatus, _) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/move',
      token: tokens['disconnect-guest'],
      body: {'cells': _initialCells(), 'passed': true},
    );
    expect(moveStatus, 403);
  });

  test('todos los jugadores conectados deben votar para continuar', () async {
    horaPrueba = DateTime.utc(2026, 1, 15);
    addTearDown(() => horaPrueba = null);
    final (code, tokens) = await _crearPartida(
      client,
      server,
      const ['vote-host', 'vote-guest', 'vote-other'],
    );

    horaPrueba = horaPrueba!.add(const Duration(seconds: 59));
    await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['vote-other'],
    );
    horaPrueba = horaPrueba!.add(const Duration(seconds: 2));
    await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['vote-host'],
    );

    final (_, primerVoto) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/continue',
      token: tokens['vote-host'],
      body: const {},
    );
    expect(primerVoto['paused'], isTrue);
    expect(primerVoto['phase'], 'partida');

    final (segundoStatus, resultado) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/continue',
      token: tokens['vote-other'],
      body: const {},
    );
    expect(segundoStatus, 200);
    expect(resultado['paused'], isFalse);
    expect(resultado['phase'], 'partida');
    expect(resultado['winner'], isNull);
  });

  test('el jugador puede volver antes de los cinco minutos', () async {
    horaPrueba = DateTime.utc(2026, 2, 1);
    addTearDown(() => horaPrueba = null);
    final (code, tokens) = await _crearPartida(
      client,
      server,
      const ['reconnect-host', 'reconnect-guest', 'reconnect-other'],
    );

    horaPrueba = horaPrueba!.add(const Duration(seconds: 59));
    await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['reconnect-other'],
    );
    horaPrueba = horaPrueba!.add(const Duration(seconds: 2));
    await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['reconnect-host'],
    );
    final (_, voted) = await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/continue',
      token: tokens['reconnect-host'],
      body: const {},
    );
    expect(voted['paused'], isTrue);
    expect(voted['players'][0]['votedToContinue'], isTrue);

    final (resumeStatus, resumed) = await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['reconnect-guest'],
    );
    expect(resumeStatus, 200);
    expect(resumed['paused'], isFalse);
    expect(resumed['players'][0]['votedToContinue'], isFalse);
    expect(resumed['players'][1]['eliminated'], isFalse);
  });

  test('al vencer los cinco minutos continúa sin unanimidad', () async {
    horaPrueba = DateTime.utc(2026, 3, 1);
    addTearDown(() => horaPrueba = null);
    final (code, tokens) = await _crearPartida(
      client,
      server,
      const ['timeout-host', 'timeout-guest'],
    );

    horaPrueba = horaPrueba!.add(const Duration(seconds: 61));
    final (_, paused) = await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['timeout-host'],
    );
    expect(paused['paused'], isTrue);
    horaPrueba = horaPrueba!.add(const Duration(minutes: 5));

    final (timeoutStatus, result) = await _request(
      client,
      server,
      'GET',
      '/api/rooms/$code',
      token: tokens['timeout-host'],
    );
    expect(timeoutStatus, 200);
    expect(result['paused'], isFalse);
    expect(result['phase'], 'finalizada');
    expect(result['winner'], 'timeout-host');
  });
}

Future<(String, Map<String, String>)> _crearPartida(
  HttpClient client,
  HttpServer server,
  List<String> usuarios,
) async {
  final tokens = {
    for (final usuario in usuarios)
      usuario: JWT({'sub': usuario}).sign(SecretKey(jwtSecret)),
  };
  final (_, creada) = await _request(
    client,
    server,
    'POST',
    '/api/rooms/create',
    token: tokens[usuarios.first],
    body: {'level': 1},
  );
  final code = creada['code'] as String;

  for (final usuario in usuarios.skip(1)) {
    await _request(
      client,
      server,
      'POST',
      '/api/rooms/join',
      token: tokens[usuario],
      body: {'code': code},
    );
  }
  for (final usuario in usuarios) {
    await _request(
      client,
      server,
      'POST',
      '/api/rooms/$code/ready',
      token: tokens[usuario],
      body: {'cells': _initialCells()},
    );
  }
  final (startStatus, _) = await _request(
    client,
    server,
    'POST',
    '/api/rooms/$code/start',
    token: tokens[usuarios.first],
  );
  expect(startStatus, 200);
  return (code, tokens);
}

List<int?> _initialCells([int level = 1]) {
  final cells = List<int?>.filled(49, null);
  const indicesPorNivel = {
    1: [2, 12, 22, 25, 37, 46],
    4: [4, 16, 19, 21, 39, 43],
  };
  const valoresPorNivel = {
    1: [1, 2, 3, 4, 5, 6],
    4: [4, 2, 1, 5, 6, 3],
  };
  final indices = indicesPorNivel[level]!;
  final valores = valoresPorNivel[level]!;
  for (var index = 0; index < indices.length; index++) {
    cells[indices[index]] = valores[index];
  }
  return cells;
}

Future<(int, Map<String, dynamic>)> _request(
  HttpClient client,
  HttpServer server,
  String method,
  String path, {
  String? token,
  Map<String, dynamic>? body,
}) async {
  final request = await client.openUrl(
    method,
    Uri.parse('http://127.0.0.1:${server.port}$path'),
  );
  request.headers.contentType = ContentType.json;
  if (token != null) request.headers.set('authorization', 'Bearer $token');
  if (body != null) request.write(jsonEncode(body));
  final response = await request.close();
  final decoded = jsonDecode(await response.transform(utf8.decoder).join());
  return (response.statusCode, Map<String, dynamic>.from(decoded as Map));
}
