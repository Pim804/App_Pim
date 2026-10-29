import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:5044/api',
);

class OptiStockApi {
  OptiStockApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  String? token;
  Future<void> Function()? onUnauthorized;

  Uri _uri(String path) => Uri.parse('$apiBaseUrl/$path');
  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> get(String path) async {
    final response = await _client.get(_uri(path), headers: _headers);
    if (response.statusCode == 401) {
      token = null;
      await onUnauthorized?.call();
      throw const SessionExpiredException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('A consulta falhou (${response.statusCode}).');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getList(String path) async {
    final response = await _client.get(_uri(path), headers: _headers);
    if (response.statusCode == 401) {
      token = null;
      await onUnauthorized?.call();
      throw const SessionExpiredException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('A consulta falhou (${response.statusCode}).');
    }
    return (jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _client.post(
      _uri(path),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode == 401) {
      token = null;
      await onUnauthorized?.call();
      throw const SessionExpiredException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail =
          _tryDecode(utf8.decode(response.bodyBytes))?['title'] as String?;
      throw ApiException(
        detail ?? 'A operação falhou (${response.statusCode}).',
      );
    }
    return response.body.isEmpty
        ? {}
        : jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await _client.post(
      _uri('auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw ApiException('E-mail ou senha inválidos.');
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Map<String, dynamic>? _tryDecode(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SessionExpiredException implements Exception {
  const SessionExpiredException();
}

class AuthState extends ChangeNotifier {
  AuthState() {
    api.onUnauthorized = () async {
      if (!_revoking) await logout(revoke: false);
    };
    _restore();
  }
  static const _storage = FlutterSecureStorage();
  final api = OptiStockApi();
  bool loading = true;
  String? displayName;
  String? userId;
  List<String> roles = [];
  String? error;
  bool _revoking = false;

  Future<void> _restore() async {
    final token = await _storage.read(key: 'access_token');
    final expires = await _storage.read(key: 'expires_at');
    if (token != null &&
        expires != null &&
        DateTime.tryParse(expires)?.isAfter(DateTime.now()) == true) {
      api.token = token;
      displayName = await _storage.read(key: 'display_name');
      userId = await _storage.read(key: 'user_id');
      roles = (await _storage.read(key: 'roles') ?? '')
          .split('|')
          .where((role) => role.isNotEmpty)
          .toList();
    } else {
      await logout(notify: false);
    }
    loading = false;
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    error = null;
    try {
      final result = await api.login(email, password);
      api.token = result['accessToken'] as String;
      displayName = result['displayName'] as String? ?? email;
      userId = result['userId'] as String?;
      roles = (result['roles'] as List<dynamic>? ?? [])
          .map((role) => role.toString())
          .toList();
      await _storage.write(key: 'access_token', value: api.token);
      await _storage.write(
        key: 'expires_at',
        value: result['expiresAtUtc'] as String?,
      );
      await _storage.write(key: 'display_name', value: displayName);
      await _storage.write(key: 'user_id', value: userId);
      await _storage.write(key: 'roles', value: roles.join('|'));
      notifyListeners();
    } on ApiException catch (e) {
      error = e.message;
      notifyListeners();
      rethrow;
    } catch (_) {
      error =
          'Não foi possível conectar à API. Verifique a rede e tente novamente.';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> logout({bool notify = true, bool revoke = true}) async {
    if (revoke && api.token != null) {
      _revoking = true;
      try {
        await api.post('auth/logout', {});
      } catch (_) {}
      _revoking = false;
    }
    api.token = null;
    displayName = null;
    userId = null;
    roles = [];
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'expires_at');
    await _storage.delete(key: 'display_name');
    await _storage.delete(key: 'user_id');
    await _storage.delete(key: 'roles');
    if (notify) notifyListeners();
  }

  Future<void> expireSession() => logout();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AuthState(),
      child: const OptiStockApp(),
    ),
  );
}

class OptiStockApp extends StatelessWidget {
  const OptiStockApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OptiStock',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff0969da),
            brightness: Brightness.light,
          ).copyWith(
            primary: const Color(0xff0969da),
            secondary: const Color(0xff8250df),
            tertiary: const Color(0xff00b8d9),
            surface: const Color(0xffffffff),
            onSurface: const Color(0xff1f2328),
            error: const Color(0xffcf222e),
            outline: const Color(0xffd0d7de),
          ),
      scaffoldBackgroundColor: const Color(0xfff6f8fa),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xffffffff),
        foregroundColor: Color(0xff1f2328),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xffffffff),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xffd0d7de)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xffffffff),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        labelStyle: const TextStyle(color: Color(0xff57606a)),
        prefixIconColor: const Color(0xff57606a),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xffd0d7de)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xffd0d7de)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xff8250df), width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xff0969da),
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xffffffff),
        indicatorColor: Color(0xffddf4ff),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
    ),
    home: Consumer<AuthState>(
      builder: (context, auth, _) {
        if (auth.loading)
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        return auth.api.token == null ? const LoginScreen() : const HomeShell();
      },
    ),
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff6f8fa),
    body: Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.72, -0.82),
                radius: 1.35,
                colors: [
                  Color(0xfff6f8fa),
                  Color(0xfff6f8fa),
                  Color(0xfff3f0ff),
                ],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
        ),
        Positioned(
          top: -115,
          left: -105,
          child: _loginGlow(300, const Color(0x180969da)),
        ),
        Positioned(
          right: -135,
          bottom: -125,
          child: _loginGlow(340, const Color(0x188250df)),
        ),
        Positioned(
          top: MediaQuery.sizeOf(context).height * 0.29,
          right: -105,
          child: Transform.rotate(
            angle: -0.24,
            child: _loginShape(390, const Color(0x0a00b8d9)),
          ),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.build_rounded,
                      size: 38,
                      color: Color(0xff1f2328),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'OptiStock',
                      style: TextStyle(
                        color: Color(0xff1f2328),
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        shadows: [
                          Shadow(color: Color(0x190969da), blurRadius: 18),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    Card(
                      color: Colors.white,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: const BorderSide(color: Color(0xffd0d7de)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: _loginCard(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _loginCard() => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Acesse sua conta',
            style: TextStyle(
              color: Color(0xff1f2328),
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(height: 15),
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username],
          style: const TextStyle(color: Color(0xff1f2328), fontSize: 13),
          decoration: _loginInputDecoration(
            hint: 'Digite seu e-mail',
            icon: Icons.person_outline,
          ),
          validator: (v) =>
              v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)
              ? 'Informe um e-mail valido.'
              : null,
        ),
        const SizedBox(height: 11),
        TextFormField(
          controller: _password,
          obscureText: _obscurePassword,
          autofillHints: const [AutofillHints.password],
          style: const TextStyle(color: Color(0xff1f2328), fontSize: 13),
          decoration:
              _loginInputDecoration(
                hint: 'Digite sua senha',
                icon: Icons.lock_outline,
              ).copyWith(
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  color: const Color(0xff57606a),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
          validator: (v) => v == null || v.isEmpty ? 'Informe a senha.' : null,
        ),
        Consumer<AuthState>(
          builder: (context, auth, _) => auth.error == null
              ? const SizedBox(height: 10)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    auth.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xffcf222e),
                      fontSize: 12,
                    ),
                    semanticsLabel: auth.error,
                  ),
                ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff0969da),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 3,
          ),
          child: _busy
              ? const SizedBox(
                  height: 19,
                  width: 19,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'LOGIN',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                  ),
                ),
        ),
      ],
    ),
  );

  InputDecoration _loginInputDecoration({
    required String hint,
    required IconData icon,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xff6e7781), fontSize: 12),
    prefixIcon: Icon(icon, size: 17, color: const Color(0xff57606a)),
    filled: true,
    fillColor: const Color(0xfff6f8fa),
    contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffd0d7de)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffd0d7de)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xff8250df), width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffcf222e)),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffcf222e), width: 1.5),
    ),
  );

  Widget _loginGlow(double size, Color color) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: color, blurRadius: 70, spreadRadius: 18)],
    ),
  );

  Widget _loginShape(double size, Color color) => Container(
    width: size,
    height: size * 0.55,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(size),
    ),
  );

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().login(_email.text.trim(), _password.text);
    } on Object {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onSelect: (value) => setState(() => index = value)),
      const PartsScreen(),
      const MovementsScreen(),
      const AnnouncementsScreen(),
      const ProfileScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Início',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            label: 'Peças',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz),
            label: 'Movimentos',
          ),
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            label: 'Avisos',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Perfil',
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.onSelect, super.key});
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('OptiStock'),
      actions: [
        IconButton(
          onPressed: () => context.read<AuthState>().logout(),
          icon: const Icon(Icons.logout),
          tooltip: 'Sair',
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 30),
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xff101c33),
                    Color(0xff0969da),
                    Color(0xff7048e8),
                  ],
                  stops: [0, 0.56, 1],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x304f46e5),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0x25ffffff),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0x55ffffff)),
                    ),
                    child: const Icon(
                      Icons.build_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 15),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'OptiStock',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Peças, saldos e histórico em um só lugar.',
                          style: TextStyle(
                            color: Color(0xffe4eaff),
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _moduleTile(
              context,
              'Departamento Pessoal',
              Icons.person_outline,
              () => onSelect(3),
            ),
            _moduleTile(
              context,
              'Estoque',
              Icons.inventory_2_outlined,
              () => onSelect(1),
            ),
            _moduleTile(
              context,
              'Gerência',
              Icons.query_stats_outlined,
              () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const DashboardScreen(),
                ),
              ),
            ),
            if (context.read<AuthState>().roles.contains('Administrador'))
              _moduleTile(
                context,
                'Cadastrar Peça',
                Icons.add_box_outlined,
                () async {
                  final saved = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute<bool>(
                      builder: (_) => const CreatePartScreen(),
                    ),
                  );
                  if (saved == true && context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Peça cadastrada com sucesso.'),
                      ),
                    );
                },
              ),
            _moduleTile(
              context,
              'Movimentações',
              Icons.swap_horiz,
              () => onSelect(2),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _moduleTile(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 9),
    child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xff0969da),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xffd0d7de)),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xff0969da),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Color(0xff6e7781), size: 19),
          ],
        ),
      ),
    ),
  );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<Map<String, dynamic>> _future;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _future = context.read<AuthState>().api.get('dashboard');
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Gerência'),
      actions: [
        IconButton(
          onPressed: () => setState(_load),
          icon: const Icon(Icons.refresh),
          tooltip: 'Atualizar',
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return ErrorPanel(
            error: snapshot.error!,
            onRetry: () => setState(_load),
          );
        final totals = snapshot.data?['totals'] as Map<String, dynamic>? ?? {};
        return RefreshIndicator(
          onRefresh: () async => setState(_load),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth > 700 ? 4 : 2;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Resumo do estoque',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Indicadores atualizados pelo sistema.',
                    style: TextStyle(color: Color(0xff656d76)),
                  ),
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 2,
                    childAspectRatio: 1.55,
                    children: [
                      MetricCard(
                        label: 'Peças cadastradas',
                        value: '${totals['parts'] ?? 0}',
                        icon: Icons.category_outlined,
                      ),
                      MetricCard(
                        label: 'Unidades disponíveis',
                        value: '${totals['units'] ?? 0}',
                        icon: Icons.inventory_outlined,
                      ),
                      MetricCard(
                        label: 'Estoque baixo',
                        value: '${totals['low'] ?? 0}',
                        icon: Icons.warning_amber_outlined,
                      ),
                      MetricCard(
                        label: 'Sem estoque',
                        value: '${totals['empty'] ?? 0}',
                        icon: Icons.remove_shopping_cart_outlined,
                      ),
                    ],
                  ),
                  MetricCard(
                    label: 'Valor estimado do estoque',
                    value: 'R\$ ${totals['inventoryValue'] ?? 0}',
                    icon: Icons.payments_outlined,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Cálculo: quantidade disponível × preço unitário.',
                      style: TextStyle(color: Color(0xff656d76), fontSize: 12),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ),
  );
}

class CreatePartScreen extends StatefulWidget {
  const CreatePartScreen({super.key});
  @override
  State<CreatePartScreen> createState() => _CreatePartScreenState();
}

class _CreatePartScreenState extends State<CreatePartScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _quantity = TextEditingController(text: '0');
  final _minimum = TextEditingController(text: '0');
  final _price = TextEditingController(text: '0.00');
  final _location = TextEditingController();
  int? _categoryId;
  bool _busy = false;
  String? _error;
  late Future<List<Map<String, dynamic>>> _categories;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  void _loadCategories() =>
      _categories = context.read<AuthState>().api.getList('categorias');
  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _description.dispose();
    _quantity.dispose();
    _minimum.dispose();
    _price.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cadastrar Peça')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _categories,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return ErrorPanel(
            error: snapshot.error!,
            onRetry: () => setState(_loadCategories),
          );
        final categories = snapshot.data ?? [];
        if (categories.isEmpty)
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Cadastre uma categoria no site antes de cadastrar uma peça.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        return Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dados da peça',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Nome da peça',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Informe o nome.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _code,
                        decoration: const InputDecoration(labelText: 'Código'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Informe o código.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _categoryId,
                        decoration: const InputDecoration(
                          labelText: 'Categoria',
                        ),
                        items: categories
                            .map(
                              (c) => DropdownMenuItem<int>(
                                value: c['id'] as int,
                                child: Text('${c['name']}'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _categoryId = v),
                        validator: (v) =>
                            v == null ? 'Selecione uma categoria.' : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _quantity,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Quantidade inicial',
                              ),
                              validator: _positiveOrZero,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _minimum,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Estoque mínimo',
                              ),
                              validator: _positiveOrZero,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _price,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Preço unitário',
                          prefixText: 'R\$ ',
                        ),
                        validator: (v) =>
                            double.tryParse((v ?? '').replaceAll(',', '.')) ==
                                    null ||
                                double.parse((v ?? '0').replaceAll(',', '.')) <
                                    0
                            ? 'Informe um preço válido.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _location,
                        decoration: const InputDecoration(
                          labelText: 'Endereço no depósito',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _description,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Descrição',
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : () => _save(categories),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(),
                              )
                            : const Text('Salvar peça'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  String? _positiveOrZero(String? value) =>
      int.tryParse(value ?? '') == null || int.parse(value!) < 0
      ? 'Informe zero ou um inteiro positivo.'
      : null;

  Future<void> _save(List<Map<String, dynamic>> categories) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthState>().api.post('pecas', {
        'code': _code.text.trim(),
        'name': _name.text.trim(),
        'description': _description.text.trim(),
        'categoryId': _categoryId,
        'supplierId': null,
        'initialQuantity': int.parse(_quantity.text),
        'minimumStock': int.parse(_minimum.text),
        'unitPrice': double.parse(_price.text.replaceAll(',', '.')),
        'warehouseLocation': _location.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted)
        setState(
          () => _error = e is ApiException
              ? e.message
              : 'Não foi possível cadastrar a peça.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class PartsScreen extends StatefulWidget {
  const PartsScreen({super.key});
  @override
  State<PartsScreen> createState() => _PartsScreenState();
}

class _PartsScreenState extends State<PartsScreen> {
  final _search = TextEditingController();
  late Future<Map<String, dynamic>> _future;
  String query = '';
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _future = context.read<AuthState>().api.get(
    'pecas?pageSize=100&busca=${Uri.encodeQueryComponent(query)}',
  );
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Peças'),
      actions: [
        IconButton(
          onPressed: () => setState(_load),
          icon: const Icon(Icons.refresh),
          tooltip: 'Atualizar',
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Pesquisar nome ou código',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: 'Pesquisar',
                onPressed: () => setState(() {
                  query = _search.text;
                  _load();
                }),
              ),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => setState(() {
              query = v;
              _load();
            }),
          ),
        ),
        Expanded(
          child: FutureBuilder<Map<String, dynamic>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting)
                return const Center(child: CircularProgressIndicator());
              if (snapshot.hasError)
                return ErrorPanel(
                  error: snapshot.error!,
                  onRetry: () => setState(_load),
                );
              final items = (snapshot.data?['items'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
              if (items.isEmpty)
                return const Center(child: Text('Nenhuma peça encontrada.'));
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final p = items[i];
                  return ListTile(
                    title: Text('${p['name']}'),
                    subtitle: Text(
                      '${p['code']} · ${p['category']} · ${p['status']}',
                    ),
                    trailing: Text(
                      'Saldo\n${p['stockQuantity']}',
                      textAlign: TextAlign.end,
                    ),
                    leading: const Icon(Icons.inventory_2_outlined),
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${p['name']}',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text('Código: ${p['code']}'),
                            Text('Categoria: ${p['category']}'),
                            Text('Saldo: ${p['stockQuantity']}'),
                            Text(
                              'Endereço: ${p['warehouseLocation'] ?? 'Não informado'}',
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class MovementsScreen extends StatefulWidget {
  const MovementsScreen({super.key});
  @override
  State<MovementsScreen> createState() => _MovementsScreenState();
}

class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});
  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  late Future<Map<String, dynamic>> _future;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      _future = context.read<AuthState>().api.get('comunicados?pageSize=50');
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Departamento Pessoal'),
      actions: [
        IconButton(
          onPressed: () => setState(_load),
          icon: const Icon(Icons.refresh),
          tooltip: 'Atualizar',
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return ErrorPanel(
            error: snapshot.error!,
            onRetry: () => setState(_load),
          );
        final items = (snapshot.data?['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        return RefreshIndicator(
          onRefresh: () async => setState(_load),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Portal do Funcionário',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Text(
                'Acompanhe comunicados e informações importantes da equipe.',
                style: TextStyle(color: Color(0xff656d76)),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xffeef4ff),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.desktop_windows_outlined,
                          color: Color(0xff0969da),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'OptiStock',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Sistema de gestão de estoque para organizar peças, materiais e movimentações.',
                              style: TextStyle(
                                color: Color(0xff656d76),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Comunicados',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    'Nenhum comunicado publicado.',
                    style: TextStyle(color: Color(0xff656d76)),
                  ),
                ),
              ...items.map(
                (a) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${a['title']}',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${a['author']} · ${a['publishedAtUtc'] ?? a['createdAtUtc']}',
                          style: const TextStyle(
                            color: Color(0xff656d76),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text('${a['content']}'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _MovementsScreenState extends State<MovementsScreen> {
  late Future<Map<String, dynamic>> _future;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      _future = context.read<AuthState>().api.get('movimentacoes?pageSize=50');
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Movimentações'),
      actions: [
        IconButton(
          onPressed: () => setState(_load),
          icon: const Icon(Icons.refresh),
          tooltip: 'Atualizar',
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () async {
        final saved = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => const MovementFormScreen()),
        );
        if (saved == true && mounted) setState(_load);
      },
      icon: const Icon(Icons.add),
      label: const Text('Registrar'),
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return ErrorPanel(
            error: snapshot.error!,
            onRetry: () => setState(_load),
          );
        final items = (snapshot.data?['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        if (items.isEmpty)
          return const Center(child: Text('Nenhuma movimentação registrada.'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final m = items[i];
            final entry = m['type'] == 'entry';
            return ListTile(
              leading: Icon(
                entry ? Icons.south_west : Icons.north_east,
                color: entry ? Colors.green : Colors.deepOrange,
              ),
              title: Text('${m['partName']} · ${entry ? 'Entrada' : 'Saída'}'),
              subtitle: Text('${m['occurredAtUtc']} · ${m['notes'] ?? ''}'),
              trailing: Text(
                '${entry ? '+' : '−'}${m['quantity']}\n${m['previousBalance']} → ${m['newBalance']}',
                textAlign: TextAlign.end,
              ),
            );
          },
        );
      },
    ),
  );
}

class MovementFormScreen extends StatefulWidget {
  const MovementFormScreen({super.key});
  @override
  State<MovementFormScreen> createState() => _MovementFormScreenState();
}

class _MovementFormScreenState extends State<MovementFormScreen> {
  final _form = GlobalKey<FormState>();
  final _quantity = TextEditingController(text: '1');
  final _notes = TextEditingController();
  int? partId;
  String type = 'entry';
  bool busy = false;
  String? error;
  late Future<Map<String, dynamic>> parts;
  @override
  void initState() {
    super.initState();
    parts = context.read<AuthState>().api.get('pecas?pageSize=100');
  }

  @override
  void dispose() {
    _quantity.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nova movimentação')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: parts,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return ErrorPanel(
            error: snapshot.error!,
            onRetry: () => setState(
              () => parts = context.read<AuthState>().api.get(
                'pecas?pageSize=100',
              ),
            ),
          );
        final options = (snapshot.data?['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        return Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<int>(
                initialValue: partId,
                decoration: const InputDecoration(
                  labelText: 'Peça',
                  border: OutlineInputBorder(),
                ),
                items: options
                    .map(
                      (p) => DropdownMenuItem(
                        value: p['id'] as int,
                        child: Text(
                          '${p['code']} · ${p['name']} (${p['stockQuantity']})',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => partId = v),
                validator: (v) => v == null ? 'Selecione uma peça.' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(
                  labelText: 'Tipo',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'entry', child: Text('Entrada')),
                  DropdownMenuItem(value: 'exit', child: Text('Saída')),
                ],
                onChanged: (v) => setState(() => type = v ?? 'entry'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Quantidade',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    int.tryParse(v ?? '') == null || int.parse(v!) <= 0
                    ? 'Informe uma quantidade positiva.'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notes,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Observações',
                  border: OutlineInputBorder(),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy ? null : _save,
                child: busy
                    ? const CircularProgressIndicator()
                    : const Text('Registrar movimentação'),
              ),
            ],
          ),
        );
      },
    ),
  );
  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await context.read<AuthState>().api.post('movimentacoes', {
        'partId': partId,
        'type': type,
        'quantity': int.parse(_quantity.text),
        'notes': _notes.text,
      });
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted)
        setState(
          () => error = e is ApiException
              ? e.message
              : e is SessionExpiredException
              ? 'Sua sessão expirou. Entre novamente.'
              : 'Falha de conexão com a API.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context) => Consumer<AuthState>(
    builder: (context, auth, _) => Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const CircleAvatar(radius: 36, child: Icon(Icons.person, size: 36)),
          const SizedBox(height: 16),
          Center(
            child: Text(
              auth.displayName ?? 'Usuário',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (auth.userId != null) Center(child: Text(auth.userId!)),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: auth.logout,
            icon: const Icon(Icons.logout),
            label: const Text('Sair'),
          ),
        ],
      ),
    ),
  );
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    super.key,
  });
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 29,
            height: 29,
            decoration: BoxDecoration(
              color: const Color(0xffeef4ff),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(icon, size: 17, color: const Color(0xff0969da)),
          ),
          const SizedBox(height: 8),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xff656d76),
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({required this.error, required this.onRetry, super.key});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 40),
          const SizedBox(height: 12),
          Text(
            error is SessionExpiredException
                ? 'Sessão expirada. Faça login novamente.'
                : 'Não foi possível carregar os dados.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar novamente'),
          ),
        ],
      ),
    ),
  );
}
