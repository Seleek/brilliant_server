import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dbcrypt/dbcrypt.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

const String jwtSecret = 'SUPER_SECRET_KEY_BRILLIANT_GAME_2026';
late final Database db;
int activeUsersCount = 0;
final _salas = <String, _Sala>{};
final _random = Random.secure();

const _caracteresCodigo = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _limiteInactividad = Duration(seconds: 60);
const _tiempoEsperaDesconexion = Duration(minutes: 5);

void printConectados() {
  print('========================================');
  print('--> Hay $activeUsersCount persona(s) conectada(s)');
  print('========================================');
}

void initDatabase() {
  db = sqlite3.open('usuarios.db');
  db.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL
    );
  ''');
  print('Base de datos SQLite inicializada (usuarios.db)');
}

class _JugadorSala {
  final String usuario;
  DateTime ultimaActividad;
  bool listo = false;
  bool envioRonda = false;
  bool eliminado = false;
  List<dynamic> tablero = List<dynamic>.filled(49, null);

  _JugadorSala(this.usuario, this.ultimaActividad);
}

class _FinalizacionZona {
  final String usuario;
  final String color;
  final String zonaId;

  const _FinalizacionZona(this.usuario, this.color, this.zonaId);
}

class _Sala {
  final String codigo;
  final int nivel;
  String anfitrion;
  String fase = 'preparacion';
  int ronda = 0;
  List<int> dados = const [];
  final Map<String, _JugadorSala> jugadores = {};
  final Map<String, List<_FinalizacionZona>> finalizacionesPorGrupo = {};
  String? jugadorDesconectado;
  DateTime? limitePausa;
  final Set<String> votosContinuar = {};
  String? ganador;

  _Sala({
    required this.codigo,
    required this.nivel,
    required this.anfitrion,
    required DateTime ahora,
  }) {
    jugadores[anfitrion] = _JugadorSala(anfitrion, ahora);
  }
}

class _Zona {
  final String color;
  final String caracter;
  final List<int> indices;
  final String id;

  _Zona(this.color, this.caracter, List<int> indices)
      : indices = List.unmodifiable([...indices]..sort()),
        id = ([...indices]..sort()).join(',');
}

const _tablerosPorNivel = <int, List<String>>{
  1: [
    'YVAMMMY',
    'VVAAMMV',
    'VRRAMVV',
    'VRMYVVV',
    'VRMMRRA',
    'RRMRRAA',
    'YMMRRAY',
  ],
  2: [
    'MMMGVVV',
    'MYAAAYV',
    'MRRAARV',
    'RRRYRRR',
    'VRAARRM',
    'VYAAAYM',
    'VVVGMMM',
  ],
  3: [
    'YYMGMYY',
    'GYMMMYG',
    'RRRMRRR',
    'RRRGRRR',
    'VAAAAAV',
    'VVVVVVV',
    'MMMGMMM',
  ],
  4: [
    'NNNNNNN',
    'YRAVARY',
    'RRMMMRR',
    'YVAMAVY',
    'RRMMMRR',
    'YRAVARY',
    'nnnnnnn',
  ],
};

String? _usuarioAutenticado(Request request) {
  final header = request.headers['authorization'];
  if (header == null || !header.startsWith('Bearer ')) return null;
  try {
    final jwt = JWT.verify(header.substring(7), SecretKey(jwtSecret));
    return jwt.payload['sub'] as String?;
  } on JWTExpiredException {
    return null;
  } on JWTException {
    return null;
  }
}

Response _jsonResponse(
  int status,
  Object body,
) =>
    Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

Future<Map<String, dynamic>?> _jsonBody(Request request) async {
  try {
    final decoded = jsonDecode(await request.readAsString());
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    return null;
  }
  return null;
}

String _nuevoCodigoSala() {
  for (var intento = 0; intento < 10; intento++) {
    final codigo = List.generate(
      6,
      (_) => _caracteresCodigo[_random.nextInt(_caracteresCodigo.length)],
    ).join();
    if (!_salas.containsKey(codigo)) return codigo;
  }
  throw StateError('No se pudo generar un código de sala único');
}

Map<String, dynamic> _salaJson(
  _Sala sala,
  String usuario, {
  required DateTime ahora,
}) {
  final jugadores = sala.jugadores.values
      .map((jugador) => {
            'username': jugador.usuario,
            'ready': jugador.listo,
            'submitted': jugador.envioRonda,
            'score': _puntajeJugador(sala, jugador.usuario),
            'connected': !jugador.eliminado &&
                ahora.difference(jugador.ultimaActividad) < _limiteInactividad,
            'eliminated': jugador.eliminado,
            'votedToContinue': sala.votosContinuar.contains(jugador.usuario),
          })
      .toList();
  return {
    'code': sala.codigo,
    'level': sala.nivel,
    'host': sala.anfitrion,
    'phase': sala.fase,
    'round': sala.ronda,
    'dice': sala.dados,
    'players': jugadores,
    'allReady': sala.jugadores.isNotEmpty &&
        sala.jugadores.values.every((jugador) => jugador.listo),
    'allSubmitted': _jugadoresActivos(sala).isNotEmpty &&
        _jugadoresActivos(sala).every((jugador) => jugador.envioRonda),
    'paused': sala.jugadorDesconectado != null,
    'disconnectedUsername': sala.jugadorDesconectado,
    'pauseDeadline': sala.limitePausa?.toIso8601String(),
    'winner': sala.ganador,
    'cells': sala.jugadores[usuario]?.tablero,
    'scores': {
      for (final jugador in sala.jugadores.values)
        jugador.usuario: _puntajeJugador(sala, jugador.usuario),
    },
  };
}

List<_JugadorSala> _jugadoresActivos(_Sala sala) =>
    sala.jugadores.values.where((jugador) => !jugador.eliminado).toList();

List<_JugadorSala> _votantesActivos(_Sala sala, DateTime ahora) =>
    sala.jugadores.values
        .where(
          (jugador) =>
              !jugador.eliminado &&
              jugador.usuario != sala.jugadorDesconectado &&
              ahora.difference(jugador.ultimaActividad) < _limiteInactividad,
        )
        .toList();

void _finalizarTurnoSiTodosEnviaron(_Sala sala) {
  final activos = _jugadoresActivos(sala);
  if (activos.isEmpty || !activos.every((jugador) => jugador.envioRonda)) {
    return;
  }
  sala.ronda++;
  sala.dados = _tirarDados();
  for (final jugador in activos) {
    jugador.envioRonda = false;
  }
}

void _continuarSinJugadorDesconectado(_Sala sala) {
  final desconectado = sala.jugadorDesconectado;
  if (desconectado == null) return;
  sala.jugadores[desconectado]!.eliminado = true;
  sala.jugadorDesconectado = null;
  sala.limitePausa = null;
  sala.votosContinuar.clear();

  final activos = _jugadoresActivos(sala);
  if (activos.length == 1) {
    sala.fase = 'finalizada';
    sala.ganador = activos.single.usuario;
    return;
  }
  _finalizarTurnoSiTodosEnviaron(sala);
}

void _verificarPresencia(
  _Sala sala,
  String usuario,
  DateTime ahora,
) {
  if (sala.limitePausa != null && !ahora.isBefore(sala.limitePausa!)) {
    _continuarSinJugadorDesconectado(sala);
  }

  final jugador = sala.jugadores[usuario];
  if (jugador != null && !jugador.eliminado) {
    jugador.ultimaActividad = ahora;
    if (sala.jugadorDesconectado == usuario) {
      sala.jugadorDesconectado = null;
      sala.limitePausa = null;
      sala.votosContinuar.clear();
    }
  }

  if (sala.fase != 'partida' || sala.jugadorDesconectado != null) return;
  for (final miembro in _jugadoresActivos(sala)) {
    if (ahora.difference(miembro.ultimaActividad) >= _limiteInactividad) {
      sala.jugadorDesconectado = miembro.usuario;
      sala.limitePausa = ahora.add(_tiempoEsperaDesconexion);
      sala.votosContinuar.clear();
      return;
    }
  }
}

int _puntajeJugador(_Sala sala, String usuario) {
  var total = 0;
  for (final entry in sala.finalizacionesPorGrupo.entries) {
    for (var index = 0; index < entry.value.length && index < 3; index++) {
      final finalizacion = entry.value[index];
      if (finalizacion.usuario == usuario) {
        total += _puntosDeZona(
          sala.nivel,
          finalizacion.color,
          index + 1,
        );
      }
    }
  }
  return total;
}

int _puntosDeZona(int nivel, String color, int puesto) {
  const rojo = [6, 4, 2];
  const morado = [6, 4, 2];
  const azul = [7, 5, 3];
  const azulNivel4 = [8, 6, 4];
  const amarilloNivel1 = [8, 6, 4];
  const amarilloNivel2 = [6, 4, 2];
  const amarilloNivel3 = [7, 5, 3];
  const verde = [4, 3, 2];
  const naranja = [6, 4, 3];

  final valores = switch (color) {
    'red' => rojo,
    'purple' => nivel <= 2 ? morado : [7, 5, 3],
    'blue' => nivel == 4 ? azulNivel4 : azul,
    'yellow' => nivel == 1 || nivel == 4
        ? amarilloNivel1
        : (nivel == 2 ? amarilloNivel2 : amarilloNivel3),
    'green' => nivel == 3 ? [6, 5, 4] : (nivel == 4 ? [3, 2, 1] : verde),
    'orange' => naranja,
    'gray' => nivel == 2 ? [3, 3, 1] : (nivel == 3 ? [8, 6, 4] : [0, 0, 0]),
    _ => const [0, 0, 0],
  };
  return valores[puesto - 1];
}

bool _esTableroValido(List<dynamic> tablero) =>
    tablero.length == 49 &&
    tablero.every(
        (valor) => valor == null || (valor is int && valor >= 1 && valor <= 6));

String _caracterDe(int nivel, int indice) =>
    _tablerosPorNivel[nivel]![indice ~/ 7][indice % 7];

String _colorDe(String caracter) => switch (caracter.toUpperCase()) {
      'V' => 'green',
      'A' => 'blue',
      'G' => 'gray',
      'R' => 'red',
      'Y' => 'yellow',
      'M' => 'purple',
      'N' => 'orange',
      _ => throw ArgumentError.value(caracter, 'caracter'),
    };

List<_Zona> _zonasDelNivel(int nivel) {
  final visitados = <int>{};
  final zonas = <_Zona>[];

  for (var inicio = 0; inicio < 49; inicio++) {
    if (visitados.contains(inicio)) continue;
    final caracter = _caracterDe(nivel, inicio);
    final x = inicio % 7;
    final colorUnificado = caracter == 'Y' ||
        (caracter == 'G' && (nivel == 2 || nivel == 3)) ||
        (caracter == 'A' && (nivel == 3 || nivel == 4));
    final indices = <int>{};

    if (colorUnificado) {
      for (var indice = 0; indice < 49; indice++) {
        if (_caracterDe(nivel, indice) == caracter) indices.add(indice);
      }
    } else if (caracter == 'R') {
      for (var indice = 0; indice < 49; indice++) {
        if (_caracterDe(nivel, indice) == caracter &&
            (indice % 7 <= 3) == (x <= 3)) {
          indices.add(indice);
        }
      }
    } else if (caracter == 'N' || caracter == 'n') {
      for (var indice = 0; indice < 49; indice++) {
        if (_caracterDe(nivel, indice) == caracter) indices.add(indice);
      }
    } else {
      final pendientes = <int>[inicio];
      visitados.add(inicio);
      while (pendientes.isNotEmpty) {
        final actual = pendientes.removeLast();
        indices.add(actual);
        final actualX = actual % 7;
        final actualY = actual ~/ 7;
        final vecinos = [
          if (actualX > 0) actual - 1,
          if (actualX < 6) actual + 1,
          if (actualY > 0) actual - 7,
          if (actualY < 6) actual + 7,
        ];
        for (final vecino in vecinos) {
          if (visitados.contains(vecino) ||
              _caracterDe(nivel, vecino) != caracter) {
            continue;
          }
          visitados.add(vecino);
          pendientes.add(vecino);
        }
      }
    }

    visitados.addAll(indices);
    zonas.add(_Zona(_colorDe(caracter), caracter, indices.toList()));
  }
  return zonas;
}

bool _reglaPermite(String caracter, List<int> existentes, int valor) {
  switch (caracter) {
    case 'A':
    case 'G':
      return existentes.isEmpty ||
          existentes.every((actual) => actual == valor);
    case 'R':
    case 'Y':
      return !existentes.contains(valor);
    case 'M':
      return {...existentes, valor}.length <= 2;
    case 'N':
      return valor >= 4 && valor <= 6;
    case 'n':
      return valor >= 1 && valor <= 3;
    default:
      return true;
  }
}

bool _zonaCompletaYValida(_Zona zona, List<dynamic> tablero) {
  if (zona.indices.any((indice) => tablero[indice] is! int)) return false;
  final valores = zona.indices.map((indice) => tablero[indice] as int).toList();
  final distintos = valores.toSet().length;
  switch (zona.caracter) {
    case 'A':
    case 'G':
      return distintos == 1;
    case 'R':
    case 'Y':
      return distintos == valores.length;
    case 'M':
      return distintos == 2;
    case 'N':
      return valores.every((valor) => valor >= 4 && valor <= 6);
    case 'n':
      return valores.every((valor) => valor >= 1 && valor <= 3);
    default:
      return true;
  }
}

Set<int> _indicesIniciales(int nivel) {
  const posicionesPorNivel = <int, List<(int, int)>>{
    1: [(2, 0), (5, 1), (1, 3), (4, 3), (2, 5), (4, 6)],
    2: [(4, 0), (0, 2), (2, 3), (5, 4), (1, 5), (4, 6)],
    3: [(2, 1), (5, 1), (3, 3), (1, 4), (6, 4), (2, 6)],
    4: [(4, 0), (2, 2), (5, 2), (0, 3), (4, 5), (1, 6)],
  };
  return {
    for (final (x, y) in posicionesPorNivel[nivel]!) y * 7 + x,
  };
}

bool _esTableroInicialValido(int nivel, List<dynamic> tablero) {
  if (!_esTableroValido(tablero)) return false;
  final indices = _indicesIniciales(nivel);
  final valores = <int>[];
  for (var index = 0; index < tablero.length; index++) {
    final valor = tablero[index];
    if (indices.contains(index)) {
      if (valor is! int) return false;
      valores.add(valor);
    } else if (valor != null) {
      return false;
    }
  }
  if (valores.toSet().length != indices.length) return false;
  final zonas = _zonasDelNivel(nivel);
  for (final indice in indices) {
    final zona = zonas.firstWhere((region) => region.indices.contains(indice));
    final existentes = [
      for (final otro in zona.indices)
        if (otro != indice && tablero[otro] is int) tablero[otro] as int,
    ];
    if (!_reglaPermite(zona.caracter, existentes, tablero[indice] as int)) {
      return false;
    }
  }
  return true;
}

void registerRoomRoutes(Router app, {DateTime Function()? clock}) {
  final ahora = clock ?? DateTime.now;

  app.post('/api/rooms/create', (Request request) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});

    final body = await _jsonBody(request);
    final nivel = body?['level'];
    if (nivel is! int || nivel < 1 || nivel > 4) {
      return _jsonResponse(400, {'error': 'Nivel inválido'});
    }

    final codigo = _nuevoCodigoSala();
    final sala =
        _Sala(codigo: codigo, nivel: nivel, anfitrion: usuario, ahora: ahora());
    _salas[codigo] = sala;
    return _jsonResponse(201, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.post('/api/rooms/join', (Request request) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final body = await _jsonBody(request);
    final codigo = (body?['code'] as String?)?.trim().toUpperCase();
    if (codigo == null || codigo.isEmpty) {
      return _jsonResponse(400, {'error': 'Ingresa un código de sala'});
    }

    final sala = _salas[codigo];
    if (sala == null)
      return _jsonResponse(404, {'error': 'Sala no encontrada'});
    if (sala.fase != 'preparacion') {
      return _jsonResponse(409, {'error': 'La partida ya comenzó'});
    }
    if (!sala.jugadores.containsKey(usuario) && sala.jugadores.length >= 4) {
      return _jsonResponse(409, {'error': 'La sala está completa'});
    }
    sala.jugadores.putIfAbsent(usuario, () => _JugadorSala(usuario, ahora()));
    _verificarPresencia(sala, usuario, ahora());
    return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.get('/api/rooms/<code>', (Request request, String code) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final sala = _salas[code.toUpperCase()];
    if (sala == null)
      return _jsonResponse(404, {'error': 'Sala no encontrada'});
    if (!sala.jugadores.containsKey(usuario)) {
      return _jsonResponse(403, {'error': 'No perteneces a esta sala'});
    }
    _verificarPresencia(sala, usuario, ahora());
    return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.post('/api/rooms/<code>/ready', (Request request, String code) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final sala = _salas[code.toUpperCase()];
    if (sala == null)
      return _jsonResponse(404, {'error': 'Sala no encontrada'});
    final jugador = sala.jugadores[usuario];
    if (jugador == null)
      return _jsonResponse(403, {'error': 'No perteneces a esta sala'});
    _verificarPresencia(sala, usuario, ahora());
    if (jugador.eliminado) {
      return _jsonResponse(403, {'error': 'Ya no participas en esta partida'});
    }
    if (sala.fase != 'preparacion') {
      return _jsonResponse(409, {'error': 'La preparación ya terminó'});
    }
    final rawCells = (await _jsonBody(request))?['cells'];
    if (rawCells is! List || !_esTableroInicialValido(sala.nivel, rawCells)) {
      return _jsonResponse(400, {
        'error': 'Completa las seis casillas iniciales con números distintos'
      });
    }
    jugador.tablero = List<dynamic>.from(rawCells);
    jugador.listo = true;
    return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.post('/api/rooms/<code>/start', (Request request, String code) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final sala = _salas[code.toUpperCase()];
    if (sala == null)
      return _jsonResponse(404, {'error': 'Sala no encontrada'});
    if (!sala.jugadores.containsKey(usuario)) {
      return _jsonResponse(403, {'error': 'No perteneces a esta sala'});
    }
    _verificarPresencia(sala, usuario, ahora());
    if (sala.anfitrion != usuario) {
      return _jsonResponse(403, {'error': 'Solo el anfitrión puede iniciar'});
    }
    if (sala.fase != 'preparacion' ||
        sala.jugadores.length < 2 ||
        !sala.jugadores.values.every((jugador) => jugador.listo)) {
      return _jsonResponse(
          409, {'error': 'Se requieren al menos dos jugadores listos'});
    }
    sala.fase = 'partida';
    sala.ronda = 1;
    sala.dados = _tirarDados();
    return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.post('/api/rooms/<code>/move', (Request request, String code) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final sala = _salas[code.toUpperCase()];
    if (sala == null)
      return _jsonResponse(404, {'error': 'Sala no encontrada'});
    final jugador = sala.jugadores[usuario];
    if (jugador == null)
      return _jsonResponse(403, {'error': 'No perteneces a esta sala'});
    _verificarPresencia(sala, usuario, ahora());
    if (jugador.eliminado) {
      return _jsonResponse(403, {'error': 'Ya no participas en esta partida'});
    }
    if (sala.jugadorDesconectado != null) {
      return _jsonResponse(409, {'error': 'La partida está pausada'});
    }
    if (sala.fase != 'partida') {
      return _jsonResponse(409, {'error': 'La partida no está activa'});
    }
    if (jugador.envioRonda) {
      return _jsonResponse(
          409, {'error': 'Ya enviaste tu jugada de esta ronda'});
    }

    final body = await _jsonBody(request);
    final cells = body?['cells'];
    final passed = body?['passed'] == true;
    final selectedDie = body?['selectedDie'];
    if (cells is! List || !_esTableroValido(cells)) {
      return _jsonResponse(400, {'error': 'Estado del tablero inválido'});
    }

    final cambios = <int>[];
    for (var i = 0; i < 49; i++) {
      if (jugador.tablero[i] != cells[i]) {
        if (jugador.tablero[i] != null || cells[i] == null) {
          return _jsonResponse(
              400, {'error': 'No se pueden cambiar casillas ya ocupadas'});
        }
        cambios.add(i);
      }
    }
    if (passed) {
      if (cambios.isNotEmpty) {
        return _jsonResponse(
            400, {'error': 'Pasar turno no puede cambiar el tablero'});
      }
    } else {
      if (cambios.length != 1 ||
          selectedDie is! int ||
          selectedDie < 0 ||
          selectedDie > 1 ||
          cells[cambios.single] != sala.dados[selectedDie]) {
        return _jsonResponse(400,
            {'error': 'La jugada no coincide con los dados de esta ronda'});
      }
      final index = cambios.single;
      final zona = _zonasDelNivel(sala.nivel)
          .firstWhere((region) => region.indices.contains(index));
      final valoresExistentes = [
        for (final otro in zona.indices)
          if (jugador.tablero[otro] is int) jugador.tablero[otro] as int,
      ];
      if (!_reglaPermite(
          zona.caracter, valoresExistentes, cells[index] as int)) {
        return _jsonResponse(
            400, {'error': 'La jugada no cumple la regla de la zona'});
      }

      final x = index % 7;
      final y = index ~/ 7;
      final valorVecino = sala.dados[selectedDie == 0 ? 1 : 0];
      final tieneVecino = [
        if (x > 0) index - 1,
        if (x < 6) index + 1,
        if (y > 0) index - 7,
        if (y < 6) index + 7,
      ].any((vecino) => jugador.tablero[vecino] == valorVecino);
      if (!tieneVecino) {
        return _jsonResponse(400,
            {'error': 'La casilla debe estar junto al valor del otro dado'});
      }
    }

    final tableroAnterior = jugador.tablero;
    jugador.tablero = List<dynamic>.from(cells);
    jugador.envioRonda = true;
    for (final zona in _zonasDelNivel(sala.nivel)) {
      final estabaCompleta =
          zona.indices.every((indice) => tableroAnterior[indice] is int);
      if (estabaCompleta || !_zonaCompletaYValida(zona, jugador.tablero)) {
        continue;
      }
      final grupo =
          zona.color == 'green' ? '${zona.color}:${zona.id}' : zona.color;
      final finalizaciones =
          sala.finalizacionesPorGrupo.putIfAbsent(grupo, () => []);
      final yaPuntuada = finalizaciones.any((finalizacion) =>
          finalizacion.usuario == usuario && finalizacion.zonaId == zona.id);
      if (finalizaciones.length < 3 && !yaPuntuada) {
        finalizaciones.add(
          _FinalizacionZona(usuario, zona.color, zona.id),
        );
      }
    }
    _finalizarTurnoSiTodosEnviaron(sala);
    return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
  });

  app.post(
    '/api/rooms/<code>/continue',
    (Request request, String code) async {
      final usuario = _usuarioAutenticado(request);
      if (usuario == null) {
        return _jsonResponse(401, {'error': 'No autenticado'});
      }
      final sala = _salas[code.toUpperCase()];
      if (sala == null) {
        return _jsonResponse(404, {'error': 'Sala no encontrada'});
      }
      final jugador = sala.jugadores[usuario];
      if (jugador == null) {
        return _jsonResponse(403, {'error': 'No perteneces a esta sala'});
      }
      final instante = ahora();
      _verificarPresencia(sala, usuario, instante);
      if (sala.jugadorDesconectado == null) {
        return _jsonResponse(409, {'error': 'La pausa ya terminó'});
      }
      if (jugador.eliminado || jugador.usuario == sala.jugadorDesconectado) {
        return _jsonResponse(
          403,
          {'error': 'No puedes votar para continuar esta partida'},
        );
      }
      sala.votosContinuar.add(usuario);
      final votantes = _votantesActivos(sala, instante);
      if (votantes.isNotEmpty &&
          votantes.every(
            (votante) => sala.votosContinuar.contains(votante.usuario),
          )) {
        _continuarSinJugadorDesconectado(sala);
      }
      return _jsonResponse(200, _salaJson(sala, usuario, ahora: ahora()));
    },
  );

  app.post('/api/rooms/<code>/leave', (Request request, String code) async {
    final usuario = _usuarioAutenticado(request);
    if (usuario == null) return _jsonResponse(401, {'error': 'No autenticado'});
    final sala = _salas[code.toUpperCase()];
    if (sala == null) return _jsonResponse(200, {'message': 'Sala cerrada'});
    if (sala.fase != 'preparacion') {
      return _jsonResponse(
          409, {'error': 'No puedes salir durante la partida'});
    }
    sala.jugadores.remove(usuario);
    if (sala.jugadores.isEmpty) {
      _salas.remove(sala.codigo);
    } else if (sala.anfitrion == usuario) {
      sala.anfitrion = sala.jugadores.keys.first;
    }
    return _jsonResponse(200, {'message': 'Saliste de la sala'});
  });
}

List<int> _tirarDados() => [
      1 + _random.nextInt(6),
      1 + _random.nextInt(6),
    ];

void main() async {
  initDatabase();

  final app = Router();

  // Endpoint: Registro
  app.post('/api/auth/register', (Request request) async {
    final payload = jsonDecode(await request.readAsString());
    final username = payload['username'] as String?;
    final password = payload['password'] as String?;

    if (username == null ||
        password == null ||
        username.isEmpty ||
        password.isEmpty) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Usuario y contraseña requeridos'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final ResultSet result = db.select(
      'SELECT username FROM users WHERE username = ?',
      [username],
    );

    if (result.isNotEmpty) {
      return Response(
        409,
        body: jsonEncode({'error': 'El usuario ya existe'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final hashedPassword = DBCrypt().hashpw(password, DBCrypt().gensalt());
    db.execute(
      'INSERT INTO users (username, password_hash) VALUES (?, ?)',
      [username, hashedPassword],
    );

    return Response.ok(
      jsonEncode({'message': 'Usuario registrado exitosamente'}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Endpoint: Login
  app.post('/api/auth/login', (Request request) async {
    final payload = jsonDecode(await request.readAsString());
    final username = payload['username'] as String?;
    final password = payload['password'] as String?;

    if (username == null || password == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Datos incompletos'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final ResultSet result = db.select(
      'SELECT password_hash FROM users WHERE username = ?',
      [username],
    );

    if (result.isEmpty) {
      return Response.unauthorized(
        jsonEncode({'error': 'Credenciales inválidas'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final storedHash = result.first['password_hash'] as String;
    final isPasswordValid = DBCrypt().checkpw(password, storedHash);

    if (!isPasswordValid) {
      return Response.unauthorized(
        jsonEncode({'error': 'Credenciales inválidas'}),
        headers: {'content-type': 'application/json'},
      );
    }

    activeUsersCount++;
    printConectados();

    final jwt = JWT({'sub': username, 'iss': 'brilliant_server'});
    final token = jwt.sign(
      SecretKey(jwtSecret),
      expiresIn: const Duration(hours: 24),
    );

    return Response.ok(
      jsonEncode({
        'token': token,
        'username': username,
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // Endpoint: Logout
  app.post('/api/auth/logout', (Request request) async {
    if (activeUsersCount > 0) {
      activeUsersCount--;
    }
    printConectados();

    return Response.ok(
      jsonEncode({'message': 'Sesión cerrada exitosamente'}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Endpoint: Borrar Cuenta
  app.delete('/api/auth/delete-account', (Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response.unauthorized(
        jsonEncode({'error': 'Token JWT no provisto'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final tokenStr = authHeader.substring(7);
    try {
      final jwt = JWT.verify(tokenStr, SecretKey(jwtSecret));
      final username = jwt.payload['sub'] as String?;

      if (username != null) {
        db.execute('DELETE FROM users WHERE username = ?', [username]);

        if (activeUsersCount > 0) {
          activeUsersCount--;
        }
        printConectados();

        return Response.ok(
          jsonEncode({'message': 'Cuenta eliminada exitosamente'}),
          headers: {'content-type': 'application/json'},
        );
      } else {
        return Response.notFound(
            jsonEncode({'error': 'Usuario no encontrado'}));
      }
    } catch (e) {
      return Response.unauthorized(
        jsonEncode({'error': 'Token inválido o expirado'}),
        headers: {'content-type': 'application/json'},
      );
    }
  });

  registerRoomRoutes(app);

  // Configuración de Pipeline agregando Middleware de CORS
  final handler = const Pipeline()
      .addMiddleware(corsHeaders()) // Soporte para peticiones OPTIONS y CORS
      .addMiddleware(logRequests())
      .addHandler(app.call);

  final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('Servidor corriendo en http://${server.address.host}:${server.port}');
  printConectados();
}
