// Image loading follows Flutter's painting/_network_image_io.dart.
// Copyright 2014 The Flutter Authors; BSD-3-Clause licensed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../services/http_log_attempt.dart';
import "../../services/app_log.dart";

@immutable
class LoggedNetworkImage extends ImageProvider<LoggedNetworkImage> {
  const LoggedNetworkImage(this.url, {this.scale = 1.0, this.headers});

  final String url;
  final double scale;
  final Map<String, String>? headers;

  static final HttpClient _httpClient = HttpClient()..autoUncompress = false;

  @override
  Future<LoggedNetworkImage> obtainKey(ImageConfiguration configuration) {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.obtainKey",
    );
    return SynchronousFuture<LoggedNetworkImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    LoggedNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.loadImage",
    );

    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () {
        AppLog.instance.trace(
          "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.loadImage.closure#1",
        );
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<LoggedNetworkImage>('Image key', key),
        ];
      },
    );
  }

  Future<ui.Codec> _loadAsync(
    LoggedNetworkImage key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync",
    );

    Map<String, dynamic> visibleHeaders =
        key.headers ?? const <String, String>{};
    HttpLogAttempt begin(String url) {
      AppLog.instance.trace(
        "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.begin",
      );
      return HttpLogAttempt(account: 'image', method: 'GET', url: url)
        ..requestHeaders = visibleHeaders
        ..requestHeaderAvailability = '显式图片请求头；底层 HTTP 库补充的请求头不可见'
        ..responseIsBinary = true;
    }

    var attempt = begin(key.url);
    try {
      final initialUri = Uri.base.resolve(key.url);
      var resolved = initialUri;
      attempt.url = resolved.toString();
      attempt.started();
      final request = await _httpClient.getUrl(resolved);
      key.headers?.forEach(request.headers.add);
      // Keep native header/authentication forwarding while observing each hop.
      request.followRedirects = false;
      final maxRedirects = request.maxRedirects;
      var response = await request.close();
      while (true) {
        attempt.status = response.statusCode;
        response.headers.forEach((name, values) {
          AppLog.instance.trace(
            "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#1",
          );

          attempt.responseHeaders[name] = values;
        });
        attempt.completeness = '响应体接收中';
        if (response.isRedirect) {
          attempt.responseByteCount = 0;
          await response.fold<int>(0, (count, chunk) {
            AppLog.instance.trace(
              "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#2",
            );

            final total = count + chunk.length;
            attempt.responseByteCount = total;
            return total;
          });
          attempt.completeness = '完整响应体；仅记录媒体类型和字节数';
          if (response.redirects.length >= maxRedirects) {
            throw RedirectException(
              'Redirect limit exceeded',
              response.redirects,
            );
          }
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw RedirectException(
              'Server response has no Location header for redirect',
              response.redirects,
            );
          }
          final redirect = Uri.parse(location);
          if (response.redirects.any((entry) {
            AppLog.instance.trace(
              "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#3",
            );
            return entry.location == redirect;
          })) {
            throw RedirectException(
              'Redirect loop detected',
              response.redirects,
            );
          }
          final next = resolved.resolveUri(redirect);
          attempt.succeeded();
          if (next.scheme != resolved.scheme ||
              next.host != resolved.host ||
              next.port != resolved.port) {
            // Match dart:io's same-origin forwarding in the observation too.
            visibleHeaders = Map<String, dynamic>.from(visibleHeaders)
              ..removeWhere((name, _) {
                AppLog.instance.trace(
                  "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#4",
                );
                return const {
                  'authorization',
                  'www-authenticate',
                  'proxy-authorization',
                  'proxy-authenticate',
                  'cookie',
                  'cookie2',
                }.contains(name.toLowerCase());
              });
          }
          resolved = next;
          attempt = begin(resolved.toString());
          attempt.started();
          response = await response.redirect();
          continue;
        }
        final contentTypes = response.headers[HttpHeaders.contentTypeHeader];
        final contentType = contentTypes == null || contentTypes.isEmpty
            ? ''
            : contentTypes.first.split(';').first.trim().toLowerCase();
        attempt.responseIsBinary =
            !(contentType.startsWith('text/') ||
                contentType == 'application/json' ||
                contentType.endsWith('+json') ||
                contentType == 'application/xml' ||
                contentType.endsWith('+xml') ||
                contentType == 'application/x-www-form-urlencoded');
        if (response.statusCode != HttpStatus.ok) {
          attempt.responseByteCount = 0;
          if (!attempt.responseIsBinary) {
            final bytes = await consolidateHttpClientResponseBytes(
              response,
              onBytesReceived: (count, total) {
                AppLog.instance.trace(
                  "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#5",
                );

                attempt.responseByteCount = count;
              },
            );
            attempt.responseByteCount = bytes.lengthInBytes;
            attempt.responseBytes = () {
              AppLog.instance.trace(
                "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#6",
              );
              return bytes;
            };
          } else {
            final captured = BytesBuilder(copy: false);
            attempt.responseBytes = captured.toBytes;
            await for (final chunk in response) {
              attempt.responseByteCount =
                  attempt.responseByteCount! + chunk.length;
              final room = 64 * 1024 - captured.length;
              if (chunk.length <= room) {
                captured.add(chunk);
              } else if (room > 0) {
                captured.add(chunk.sublist(0, room));
              }
            }
          }
          attempt.completeness = attempt.responseIsBinary
              ? '完整响应体；失败时最多保留前 64 KiB'
              : '完整响应体';
          throw NetworkImageLoadException(
            statusCode: response.statusCode,
            uri: initialUri,
          );
        }
        final bytes = await consolidateHttpClientResponseBytes(
          response,
          onBytesReceived: (cumulative, total) {
            AppLog.instance.trace(
              "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#7",
            );

            attempt.responseByteCount = cumulative;
            chunkEvents.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: cumulative,
                expectedTotalBytes: total,
              ),
            );
          },
        );
        attempt
          ..responseByteCount = bytes.lengthInBytes
          ..completeness = attempt.responseIsBinary
              ? '完整响应体；失败时最多保留前 64 KiB'
              : '完整响应体'
          ..responseBytes = () {
            AppLog.instance.trace(
              "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#8",
            );
            return Uint8List.sublistView(
              bytes,
              0,
              !attempt.responseIsBinary || bytes.lengthInBytes < 64 * 1024
                  ? bytes.lengthInBytes
                  : 64 * 1024,
            );
          };
        if (bytes.lengthInBytes == 0) {
          throw Exception('NetworkImage is an empty file: $initialUri');
        }
        final codec = await decode(
          await ui.ImmutableBuffer.fromUint8List(bytes),
        );
        attempt
          ..responseIsBinary = true
          ..succeeded();
        return codec;
      }
    } catch (error, stackTrace) {
      await attempt.fail(error, stackTrace);
      // Give the cache time to register the key before evicting, as Flutter does.
      scheduleMicrotask(() {
        AppLog.instance.trace(
          "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#9",
        );

        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(
        chunkEvents.close().catchError((Object error, StackTrace stack) {
          AppLog.instance.trace(
            "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage._loadAsync.closure#10",
          );

          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'painting library',
              context: ErrorDescription(
                'while closing chunkEvents stream in LoggedNetworkImage.loadImage',
              ),
            ),
          );
        }),
      );
    }
  }

  @override
  bool operator ==(Object other) {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.operator==",
    );
    return other.runtimeType == runtimeType &&
        other is LoggedNetworkImage &&
        other.url == url &&
        other.scale == scale &&
        mapEquals(other.headers, headers);
  }

  @override
  int get hashCode {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.hashCode.get",
    );

    var headersHash = 0;
    final values = headers;
    if (values != null) {
      for (final name in values.keys) {
        headersHash ^= Object.hash(name, values[name]);
      }
    }
    return Object.hash(url, scale, headersHash);
  }

  @override
  String toString() {
    AppLog.instance.trace(
      "lib/common/widgets/logged_network_image.dart::LoggedNetworkImage.toString",
    );
    return '${objectRuntimeType(this, 'LoggedNetworkImage')}("$url", scale: ${scale.toStringAsFixed(1)}, headers: $headers)';
  }
}
