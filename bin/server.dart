import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dbcrypt/dbcrypt.dart';

const String jwtSecret = 'SUPER_SECRET_KEY_BRILLIANT_GAME_2026';
final Map<String, String> userDatabase = {};

// Contador de usuarios activos conectados
int activeUsersCount = 0;

void printConectados() {
  print('========================================');
  print('--> Hay $activeUsersCount persona(s) conectada(s)');
  print('========================================');
}

void main() async {
  final app = Router();

  // Endpoint: Registro de Usuario
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

    if (userDatabase.containsKey(username)) {
      return Response(409,
        body: jsonEncode({'error': 'El usuario ya existe'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final hashedPassword = DBCrypt().hashpw(password, DBCrypt().gensalt());
    userDatabase[username] = hashedPassword;

    return Response.ok(
      jsonEncode({'message': 'Usuario registrado exitosamente'}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Endpoint: Inicio de Sesión (Login)
  app.post('/api/auth/login', (Request request) async {
    final payload = jsonDecode(await request.readAsString());
    final username = payload['username'] as String?;
    final password = payload['password'] as String?;

    if (username == null || password == null || !userDatabase.containsKey(username)) {
      return Response.unauthorized(
        jsonEncode({'error': 'Credenciales inválidas'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final storedHash = userDatabase[username]!;
    final isPasswordValid = DBCrypt().checkpw(password, storedHash);

    if (!isPasswordValid) {
      return Response.unauthorized(
        jsonEncode({'error': 'Credenciales inválidas'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Incrementar usuarios conectados e imprimir en consola
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

  // Endpoint: Cerrar Sesión (Logout)
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

      if (username != null && userDatabase.containsKey(username)) {
        userDatabase.remove(username);

        // Al borrar la cuenta también desconectamos al usuario
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

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(app.call);

  final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('Servidor corriendo en http://${server.address.host}:${server.port}');
  printConectados();
}