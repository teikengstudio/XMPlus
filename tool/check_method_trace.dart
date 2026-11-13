import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

const traceExclusions = <String, String>{
  'lib/services/app_log.dart': 'logger internals: prevent trace recursion',
  'lib/services/error_reporting.dart':
      'Sentry transport: prevent trace recursion',
};

/// One source body, shared with the disposable AST instrumenter.
class TraceBody {
  final FunctionBody body;
  final String identity;
  final String? exemption;
  final List<MethodInvocation> entries;

  TraceBody(this.body, this.identity, this.exemption, this.entries);

  bool get covered {
    final node = body;
    if (node is! BlockFunctionBody) return false;
    final statements = node.block.statements.where((s) => s is! EmptyStatement);
    if (statements.isEmpty) return false;
    final first = statements.first;
    if (first is! ExpressionStatement ||
        first.expression is! MethodInvocation) {
      return false;
    }
    final call = first.expression as MethodInvocation;
    if (!_isTrace(call) ||
        call.isNullAware ||
        call.isCascaded ||
        call.target is PropertyAccess &&
            ((call.target as PropertyAccess).isNullAware ||
                (call.target as PropertyAccess).isCascaded) ||
        call.argumentList.arguments.length != 1 ||
        call.typeArguments != null)
      return false;
    final argument = call.argumentList.arguments.single;
    return argument is SimpleStringLiteral && argument.value == identity;
  }
}

class TraceScan {
  final List<TraceBody> bodies;
  final Map<String, int> exemptions;
  TraceScan(this.bodies, this.exemptions);
}

/// Accepts parsed or resolved units; identities depend only on source structure.
TraceScan scanMethodTrace(CompilationUnit unit, String path) {
  final collector = _BodyCollector();
  unit.accept(collector);
  final identities = _Identities();
  // Source order, not AST wrapper visitation order, defines closure numbering.
  collector.closures.sort((a, b) => a.offset.compareTo(b.offset));
  for (final closure in collector.closures) {
    final owner = identities.parentOwner(closure);
    final number = (identities.closureCounts[owner] ?? 0) + 1;
    identities.closureCounts[owner] = number;
    identities.closureNumbers[closure] = number;
  }
  final exemptions = <String, int>{};
  final bodies = <TraceBody>[];
  final seen = <FunctionBody>{};
  for (final body in collector.bodies) {
    if (!seen.add(body)) continue;
    final reason = _exemption(body);
    if (reason != null)
      exemptions.update(reason, (n) => n + 1, ifAbsent: () => 1);
    final entries = _TraceEntries(body);
    body.accept(entries);
    bodies.add(
      TraceBody(
        body,
        '$path::${identities.symbol(body.parent!)}',
        reason,
        entries.entries,
      ),
    );
  }
  for (final type in collector.classes) {
    // Implicit constructors have no source body and must not be synthesized.
    final hasConstructor = collector.constructors.any(
      (c) => c.parent == type.body,
    );
    if (!hasConstructor && type.namePart is! PrimaryConstructorDeclaration) {
      exemptions.update(
        'implicit source-less constructor',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
  }
  return TraceScan(bodies, exemptions);
}

bool _isTrace(MethodInvocation node) =>
    node.methodName.name == 'trace' &&
        node.target is PropertyAccess &&
        (node.target as PropertyAccess).target is SimpleIdentifier &&
        ((node.target as PropertyAccess).target as SimpleIdentifier).name ==
            'AppLog' &&
        (node.target as PropertyAccess).propertyName.name == 'instance' ||
    node.methodName.name == 'trace' &&
        node.target is PrefixedIdentifier &&
        (node.target as PrefixedIdentifier).prefix.name == 'AppLog' &&
        (node.target as PrefixedIdentifier).identifier.name == 'instance';

String? _exemption(FunctionBody body) {
  var owner = body.parent!;
  if (owner is FunctionExpression && owner.parent is FunctionDeclaration) {
    owner = owner.parent!;
  }
  if (owner is ConstructorDeclaration) {
    if (owner.redirectedConstructor != null ||
        owner.initializers.any((i) => i is RedirectingConstructorInvocation)) {
      return 'redirecting constructor';
    }
    if (owner.constKeyword != null) return 'const constructor';
    if (owner.externalKeyword != null) return 'external declaration';
    // A non-const generative `C();` is executable, not abstract.
    return null;
  }
  if (owner is PrimaryConstructorBody) {
    if (owner.initializers.any((i) => i is RedirectingConstructorInvocation)) {
      return 'redirecting constructor';
    }
    if (owner.declaration?.constKeyword != null) return 'const constructor';
    return null;
  }
  if (owner is MethodDeclaration && owner.externalKeyword != null ||
      owner is FunctionDeclaration && owner.externalKeyword != null ||
      body is NativeFunctionBody)
    return 'external declaration';
  if (body is EmptyFunctionBody) return 'abstract declaration';
  return null;
}

class _BodyCollector extends RecursiveAstVisitor<void> {
  final bodies = <FunctionBody>[];
  final closures = <FunctionExpression>[];
  final classes = <ClassDeclaration>[];
  final constructors = <ConstructorDeclaration>[];

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    classes.add(node);
    super.visitClassDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    constructors.add(node);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (node.parent is! FunctionDeclaration) closures.add(node);
    super.visitFunctionExpression(node);
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    bodies.add(node);
    super.visitBlockFunctionBody(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    bodies.add(node);
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitEmptyFunctionBody(EmptyFunctionBody node) {
    bodies.add(node);
    super.visitEmptyFunctionBody(node);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    bodies.add(node);
    super.visitNativeFunctionBody(node);
  }
}

class _TraceEntries extends RecursiveAstVisitor<void> {
  final FunctionBody root;
  final entries = <MethodInvocation>[];
  _TraceEntries(this.root);

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_isTrace(node)) entries.add(node);
    super.visitMethodInvocation(node);
  }
}

class _Identities {
  final closureCounts = <AstNode?, int>{};
  final closureNumbers = <FunctionExpression, int>{};
  final anonymousExtensions = <ExtensionDeclaration, int>{};

  bool _isOwner(AstNode n) =>
      n is FunctionDeclaration ||
      n is MethodDeclaration ||
      n is ConstructorDeclaration ||
      n is PrimaryConstructorBody ||
      n is ClassDeclaration ||
      n is EnumDeclaration ||
      n is MixinDeclaration ||
      n is ExtensionDeclaration ||
      n is ExtensionTypeDeclaration ||
      n is VariableDeclaration ||
      n is FunctionExpression && n.parent is! FunctionDeclaration;

  AstNode? parentOwner(AstNode node) {
    for (var parent = node.parent; parent != null; parent = parent.parent) {
      if (parent is VariableDeclaration) {
        // A local variable is not an executable owner. Field/top-level
        // initializer callbacks use the field name; local callbacks use the
        // enclosing function, independent of local variable spelling.
        var enclosing = parent.parent;
        var local = false;
        while (enclosing != null) {
          if (enclosing is FunctionBody ||
              enclosing is ConstructorDeclaration) {
            local = true;
            break;
          }
          enclosing = enclosing.parent;
        }
        if (local) continue;
      }
      if (_isOwner(parent)) return parent;
    }
    return null;
  }

  String symbol(AstNode node) {
    if (node is FunctionExpression && node.parent is FunctionDeclaration) {
      return symbol(node.parent!);
    }
    if (!_isOwner(node)) {
      final parent = parentOwner(node);
      if (parent == null) throw StateError('Unknown executable owner: $node');
      return symbol(parent);
    }
    final owner = parentOwner(node);
    final prefix = owner == null ? '' : '${symbol(owner)}.';
    if (node is FunctionExpression) {
      return '${prefix}closure#${closureNumbers[node]}';
    }
    if (node is FunctionDeclaration) {
      final suffix = node.isGetter
          ? '.get'
          : node.isSetter
          ? '.set'
          : '';
      return '$prefix${node.name.lexeme}$suffix';
    }
    if (node is MethodDeclaration) {
      final name = node.isOperator
          ? 'operator${node.name.lexeme}'
          : node.name.lexeme;
      final suffix = node.isGetter
          ? '.get'
          : node.isSetter
          ? '.set'
          : '';
      return '$prefix$name$suffix';
    }
    if (node is ConstructorDeclaration) {
      final name = node.name?.lexeme ?? 'new';
      return '$prefix${node.factoryKeyword == null ? name : 'factory:$name'}';
    }
    if (node is PrimaryConstructorBody) {
      return '$prefix${node.declaration?.constructorName?.name.lexeme ?? 'new'}';
    }
    if (node is ClassDeclaration)
      return '$prefix${node.namePart.typeName.lexeme}';
    if (node is EnumDeclaration)
      return '$prefix${node.namePart.typeName.lexeme}';
    if (node is MixinDeclaration) return '$prefix${node.name.lexeme}';
    if (node is ExtensionTypeDeclaration)
      return '$prefix${node.namePart.typeName.lexeme}';
    if (node is ExtensionDeclaration) {
      final number = anonymousExtensions.putIfAbsent(
        node,
        () => anonymousExtensions.length + 1,
      );
      return '$prefix${node.name?.lexeme ?? 'extension#$number'}';
    }
    return '$prefix${(node as VariableDeclaration).name.lexeme}';
  }
}

/// Shared deterministic file discovery. Never follows directory or file links.
List<File> methodTraceFiles(List<String> paths) {
  final files = <String, File>{};
  for (final input in paths) {
    final path = p.normalize(p.absolute(input));
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file && path.endsWith('.dart')) {
      files[path] = File(path);
    } else if (type == FileSystemEntityType.directory) {
      for (final entry in Directory(
        path,
      ).listSync(recursive: true, followLinks: false)) {
        if (entry is File && entry.path.endsWith('.dart')) {
          files[p.normalize(p.absolute(entry.path))] = entry;
        }
      }
    } else {
      throw ArgumentError('Not a Dart file or directory: $input');
    }
  }
  final result = files.values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return result;
}

String methodTracePath(String path) => p
    .relative(p.absolute(path), from: Directory.current.path)
    .replaceAll('\\', '/');

void main(List<String> arguments) {
  var expected = 0;
  var covered = 0;
  var missing = 0;
  var duplicate = 0;
  var parseError = 0;
  var excluded = 0;
  final exemptions = <String, int>{};
  for (final file in methodTraceFiles(
    arguments.isEmpty ? ['lib'] : arguments,
  )) {
    final path = methodTracePath(file.path);
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );
    for (final error in parsed.errors) {
      parseError++;
      stderr.writeln(
        'parseError $path:${parsed.lineInfo.getLocation(error.offset)} ${error.message}',
      );
    }
    final exclusion = traceExclusions[path];
    if (exclusion != null) {
      excluded++;
      stdout.writeln('excluded $path: $exclusion');
      continue;
    }
    if (parsed.errors.isNotEmpty) continue;
    final scan = scanMethodTrace(parsed.unit, path);
    for (final entry in scan.exemptions.entries) {
      exemptions.update(
        entry.key,
        (n) => n + entry.value,
        ifAbsent: () => entry.value,
      );
    }
    for (final method in scan.bodies) {
      if (method.exemption != null) continue;
      expected++;
      if (method.covered) {
        covered++;
      } else {
        missing++;
        stderr.writeln(
          'missing ${method.identity}:${parsed.lineInfo.getLocation(method.body.offset)}',
        );
      }
      if (method.entries.length > 1) {
        duplicate += method.entries.length - 1;
        stderr.writeln(
          'duplicate ${method.identity}: ${method.entries.length} same-body entries',
        );
      }
    }
  }
  for (final reason in exemptions.keys.toList()..sort()) {
    stdout.writeln('exempt ${exemptions[reason]}: $reason');
  }
  stdout.writeln(
    'methodTrace expected=$expected covered=$covered missing=$missing '
    'duplicate=$duplicate parseError=$parseError excludedFiles=$excluded',
  );
  if (missing != 0 || duplicate != 0 || parseError != 0) exitCode = 1;
}
