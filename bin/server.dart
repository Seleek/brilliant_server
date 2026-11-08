import 'dart:convert';
import 'dart:io';
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

void main() async {
  initDatabase();

  final app = Router();

  // Endpoint: Registro
  app.post('/api/auth/register', (Request request) async {
    final payload = jsonDecode(await request.readAsString());
    final username = payload['username'] as String?;
    final password = payload['password'] as String?;

    if (username == null || password == null || username.isEmpty || password.isEmpty) {
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
      return Response(409,
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
        return Response.notFound(jsonEncode({'error': 'Usuario no encontrado'}));
      }
    } catch (e) {
      return Response.unauthorized(
        jsonEncode({'error': 'Token inválido o expirado'}),
        headers: {'content-type': 'application/json'},
      );
    }
  });

  // Configuración de Pipeline agregando Middleware de CORS
  final handler = const Pipeline()
      .addMiddleware(corsHeaders()) // Soporte para peticiones OPTIONS y CORS
      .addMiddleware(logRequests())
      .addHandler(app.call);

  final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('Servidor corriendo en http://${server.address.host}:${server.port}');
  printConectados();
}