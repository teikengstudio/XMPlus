import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../common/widgets/adaptive_text.dart';
import '../common/widgets/app_header.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/app_log.dart';
import '../services/media_processor.dart';
import '../storage/app_storage.dart';

class MediaSettingsPage extends StatefulWidget {
  const MediaSettingsPage({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<MediaSettingsPage> createState() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::MediaSettingsPage.createState",
    );
    return _MediaSettingsPageState();
  }
}

class _MediaSettingsPageState extends State<MediaSettingsPage> {
  static const _formats = {
    'original': '原格式',
    'mp3': 'MP3',
    'm4a': 'M4A',
    'm4b': 'M4B',
    'flac': 'FLAC',
  };
  static const _bitrates = [32, 64, 96, 128, 192];
  final _form = GlobalKey<FormState>();
  final _ffmpeg = TextEditingController();
  final _ffprobe = TextEditingController();
  String _format = 'original';
  int _bitrate = 64;
  bool _tags = true, _cover = false, _busy = false;
  String? _error, _status;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState.initState",
    );

    super.initState();
    _reload();
  }

  void _reload() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._reload",
    );

    final settings = widget.runtime.storage.state['settings'] as Map;
    final media = settings['media'] is Map
        ? settings['media'] as Map
        : const {};
    final tags = settings['tags'] is Map ? settings['tags'] as Map : const {};
    _format = _formats.containsKey(media['format'])
        ? media['format'] as String
        : 'original';
    _bitrate = _bitrates.contains(media['bitrateKbps'])
        ? media['bitrateKbps'] as int
        : 64;
    _tags = tags['enabled'] is bool ? tags['enabled'] as bool : true;
    _cover = tags['cover'] is bool ? tags['cover'] as bool : false;
    _ffmpeg.text = !Platform.isAndroid && media['ffmpegPath'] is String
        ? media['ffmpegPath'] as String
        : '';
    _ffprobe.text = !Platform.isAndroid && media['ffprobePath'] is String
        ? media['ffprobePath'] as String
        : '';
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState.dispose",
    );

    _ffmpeg.dispose();
    _ffprobe.dispose();
    super.dispose();
  }

  String? _pathError(String? text) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pathError",
    );

    final value = (text ?? '').trim();
    if (value.isEmpty) return null;
    if (!p.isAbsolute(value) || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return '请输入本地可执行文件的绝对路径';
    }
    return null;
  }

  Future<void> _validateFiles() async {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._validateFiles",
    );

    if (Platform.isAndroid) return;
    for (final entry in {
      'FFmpeg': _ffmpeg.text.trim(),
      'FFprobe': _ffprobe.text.trim(),
    }.entries) {
      final error = _pathError(entry.value);
      if (error != null) throw FormatException(error);
      if (entry.value.isNotEmpty && !await File(entry.value).exists()) {
        throw FormatException('${entry.key} 文件不存在');
      }
    }
  }

  Future<void> _pick(TextEditingController controller, String name) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _status = null;
      });
      try {
        final file = await FilePicker.pickFile(dialogTitle: '选择 $name');
        if (!mounted || file == null) return;
        if (file.path == null) throw const FormatException('请选择本地文件');
        controller.text = file.path!;
      } on FormatException catch (error) {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick.closure#1.closure#2",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Choosing media tool failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick.closure#1.closure#3",
            );
            _error = '无法选择文件，请手动填写路径';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._pick.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _checkTools() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1",
      );

      if (_busy || !_form.currentState!.validate()) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _status = null;
      });
      try {
        await _validateFiles();
        await MediaProcessor(
          ffmpegPath: _ffmpeg.text.trim().isEmpty ? null : _ffmpeg.text.trim(),
          ffprobePath: _ffprobe.text.trim().isEmpty
              ? null
              : _ffprobe.text.trim(),
        ).checkTools();
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#2",
            );
            _status = '工具版本检查通过';
          });
      } on FormatException catch (error) {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#3",
            );
            _error = error.message;
          });
      } on XmlyException catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'settings',
            'Checking media tools failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#4",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'settings',
            'Checking media tools failed',
            error: error,
            stackTrace: stack,
            promptUser: false,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#5",
            );
            _error = '工具检查失败，请检查路径和执行权限';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._checkTools.closure#1.closure#6",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _save() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1",
      );

      if (_busy || !_form.currentState!.validate()) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _status = null;
      });
      var writing = false;
      try {
        if (!_formats.containsKey(_format) || !_bitrates.contains(_bitrate)) {
          throw const FormatException('格式或码率无效');
        }
        await _validateFiles();
        writing = true;
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#2",
          );

          final settings = state['settings'] as Map;
          final media = settings.putIfAbsent('media', () {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#2.closure#1",
            );
            return <String, dynamic>{};
          }) as Map;
          media['format'] = _format;
          media['bitrateKbps'] = _bitrate;
          for (final entry in {
            'ffmpegPath': _ffmpeg.text.trim(),
            'ffprobePath': _ffprobe.text.trim(),
          }.entries) {
            if (Platform.isAndroid || entry.value.isEmpty) {
              media.remove(entry.key);
            } else {
              media[entry.key] = entry.value;
            }
          }
          final tags = settings.putIfAbsent('tags', () {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#2.closure#2",
            );
            return <String, dynamic>{};
          }) as Map;
          tags['enabled'] = _tags;
          tags['cover'] = _cover;
        });
        widget.runtime.changed();
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#3",
            );
            _status = '已保存';
          });
      } on FormatException catch (error) {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#4",
            );
            _error = error.message;
          });
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Saving media settings failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#5",
            );

            if (writing) _reload();
            _error = '设置保存失败，原值已保留';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_MediaSettingsPageState._save.closure#1.closure#6",
            );
            _busy = false;
          });
      }
    });
  }

  Widget _toolField(String name, TextEditingController controller) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._toolField",
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              key: ValueKey('${name.toLowerCase()}Path'),
              controller: controller,
              enabled: !_busy,
              minLines: 1,
              maxLines: 3,
              validator: _pathError,
              decoration: InputDecoration(
                labelText: '$name 路径',
                hintText: '留空使用随附工具',
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                AppLog.instance.trace(
                  "lib/pages/media_settings_page.dart::_MediaSettingsPageState._toolField.closure#1",
                );
                setState(() {
                  AppLog.instance.trace(
                    "lib/pages/media_settings_page.dart::_MediaSettingsPageState._toolField.closure#1.closure#1",
                  );

                  _error = null;
                  _status = null;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '选择 $name',
            onPressed: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/media_settings_page.dart::_MediaSettingsPageState._toolField.closure#2",
                    );
                    _pick(controller, name);
                  },
            icon: const Icon(Icons.folder_open),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build",
    );
    return Form(
      key: _form,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
            ),
            children: [
              AdaptiveText(
                '媒体处理',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('mediaError'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_status != null)
                Text(_status!, key: const ValueKey('mediaStatus')),
              DropdownButtonFormField<String>(
                key: ValueKey('format:$_format'),
                initialValue: _format,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '输出格式'),
                items: _formats.entries.map((entry) {
                  AppLog.instance.trace(
                    "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#1",
                  );
                  return DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  );
                }).toList(),
                onChanged: _busy
                    ? null
                    : (value) {
                        AppLog.instance.trace(
                          "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#2",
                        );

                        if (value != null)
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#2.closure#1",
                            );

                            _format = value;
                            _status = null;
                          });
                      },
              ),
              if (const {'mp3', 'm4a', 'm4b'}.contains(_format)) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: ValueKey('bitrate:$_bitrate'),
                  initialValue: _bitrate,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '码率'),
                  items: _bitrates.map((value) {
                    AppLog.instance.trace(
                      "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#3",
                    );
                    return DropdownMenuItem(
                      value: value,
                      child: Text('$value kbps'),
                    );
                  }).toList(),
                  onChanged: _busy
                      ? null
                      : (value) {
                          AppLog.instance.trace(
                            "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#4",
                          );

                          if (value != null)
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#4.closure#1",
                              );

                              _bitrate = value;
                              _status = null;
                            });
                        },
                ),
              ],
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('写入标签'),
                value: _tags,
                onChanged: _busy
                    ? null
                    : (value) {
                        AppLog.instance.trace(
                          "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#5",
                        );
                        setState(() {
                          AppLog.instance.trace(
                            "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#5.closure#1",
                          );

                          _tags = value;
                          _status = null;
                        });
                      },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('嵌入封面'),
                value: _cover,
                onChanged: _busy
                    ? null
                    : (value) {
                        AppLog.instance.trace(
                          "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#6",
                        );
                        setState(() {
                          AppLog.instance.trace(
                            "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#6.closure#1",
                          );

                          _cover = value;
                          _status = null;
                        });
                      },
              ),
              if (Platform.isAndroid)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('Android 使用安装包随附的 FFmpeg / FFprobe，无需设置桌面工具路径。'),
                )
              else ...[
                _toolField('FFmpeg', _ffmpeg),
                _toolField('FFprobe', _ffprobe),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const ValueKey('checkMediaTools'),
                  onPressed: _busy ? null : _checkTools,
                  child: const Text('检查工具版本'),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const ValueKey('saveMedia'),
                    onPressed: _busy ? null : _save,
                    child: const Text('保存'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#7",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/media_settings_page.dart::_MediaSettingsPageState.build.closure#7.closure#1",
                              );

                              _form.currentState!.reset();
                              _reload();
                              _error = null;
                              _status = null;
                            });
                          },
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AlbumTagsPage extends StatefulWidget {
  const AlbumTagsPage({
    required this.runtime,
    required this.albumId,
    required this.albumTitle,
    this.embedded = false,
    super.key,
  });
  final AppRuntime runtime;
  final String albumId, albumTitle;
  final bool embedded;

  @override
  State<AlbumTagsPage> createState() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::AlbumTagsPage.createState",
    );
    return _AlbumTagsPageState();
  }
}

class _AlbumTagsPageState extends State<AlbumTagsPage> {
  static const _fields = {
    'titlePrefix': '标题前缀',
    'album': '专辑名',
    'artist': '主播',
    'genre': '类型',
    'description': '简介',
  };
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _overridden = <String>{};
  final _changed = <String>{};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_AlbumTagsPageState.initState",
    );

    super.initState();
    final settings = widget.runtime.storage.state['settings'] as Map;
    final albums = settings['albumTags'];
    final saved = albums is Map && albums[widget.albumId] is Map
        ? albums[widget.albumId] as Map
        : const {};
    for (final key in _fields.keys) {
      final value = saved[key];
      _controllers[key] = TextEditingController(
        text: value is String ? value : '',
      );
      if (value is String) _overridden.add(key);
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_AlbumTagsPageState.dispose",
    );

    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _reset(String key) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_AlbumTagsPageState._reset",
    );

    _controllers[key]!.clear();
    _overridden.remove(key);
    _changed.add(key);
  }

  Future<void> _save() {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1",
      );

      if (_saving || !_form.currentState!.validate()) return;
      if (widget.albumId.trim().isEmpty) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#1",
          );
          _error = '专辑标识无效';
        });
        return;
      }
      if (_changed.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#2",
        );

        _saving = true;
        _error = null;
      });
      try {
        await widget.runtime.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#3",
          );

          final settings = state['settings'] as Map;
          final albums = settings.putIfAbsent('albumTags', () {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#3.closure#1",
            );
            return <String, dynamic>{};
          }) as Map;
          final values = albums.putIfAbsent(widget.albumId, () {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#3.closure#2",
            );
            return <String, dynamic>{};
          }) as Map;
          for (final key in _changed) {
            if (_overridden.contains(key)) {
              values[key] = _controllers[key]!.text;
            } else {
              values.remove(key);
            }
          }
          if (values.isEmpty) albums.remove(widget.albumId);
        });
        widget.runtime.changed();
        if (mounted) Navigator.of(context).pop();
      } catch (error, stack) {
        if (!(error is StorageException &&
                const {'too_large', 'secret_in_state'}.contains(error.code)) &&
            !AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'settings',
            'Saving album tags failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#4",
            );
            _error = '标签保存失败，原值已保留';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/media_settings_page.dart::_AlbumTagsPageState._save.closure#1.closure#5",
            );
            _saving = false;
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build",
    );
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: widget.embedded
            ? null
            : AppHeader(title: AdaptiveText(widget.albumTitle)),
        body: Form(
          key: _form,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                ),
                children: [
                  if (_saving) const LinearProgressIndicator(),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  for (final entry in _fields.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: TextFormField(
                        key: ValueKey('albumTag:${entry.key}'),
                        controller: _controllers[entry.key],
                        enabled: !_saving,
                        minLines: 1,
                        maxLines: entry.key == 'description' ? 5 : 1,
                        decoration: InputDecoration(
                          labelText: entry.value,
                          helperText: _overridden.contains(entry.key)
                              ? '已覆盖'
                              : '使用原标签',
                          suffixIcon: IconButton(
                            tooltip: '重置${entry.value}',
                            onPressed: _saving
                                ? null
                                : () {
                                    AppLog.instance.trace(
                                      "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#1",
                                    );
                                    setState(() {
                                      AppLog.instance.trace(
                                        "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#1.closure#1",
                                      );
                                      _reset(entry.key);
                                    });
                                  },
                            icon: const Icon(Icons.restart_alt),
                          ),
                        ),
                        validator: (value) {
                          AppLog.instance.trace(
                            "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#2",
                          );
                          return (value ?? '').contains('\u0000')
                              ? '不能包含空字符'
                              : null;
                        },
                        onChanged: (_) {
                          AppLog.instance.trace(
                            "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#3",
                          );
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#3.closure#1",
                            );

                            _overridden.add(entry.key);
                            _changed.add(entry.key);
                          });
                        },
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        key: const ValueKey('saveAlbumTags'),
                        onPressed: _saving ? null : _save,
                        child: const Text('保存'),
                      ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () {
                                AppLog.instance.trace(
                                  "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#4",
                                );
                                Navigator.of(context).pop();
                              },
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () {
                                AppLog.instance.trace(
                                  "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#5",
                                );
                                setState(() {
                                  AppLog.instance.trace(
                                    "lib/pages/media_settings_page.dart::_AlbumTagsPageState.build.closure#5.closure#1",
                                  );

                                  for (final key in _fields.keys) {
                                    _reset(key);
                                  }
                                });
                              },
                        child: const Text('全部重置'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
