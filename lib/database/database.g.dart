// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $PlaylistsTable extends Playlists
    with TableInfo<$PlaylistsTable, Playlist> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbnailUrlMeta = const VerificationMeta(
    'thumbnailUrl',
  );
  @override
  late final GeneratedColumn<String> thumbnailUrl = GeneratedColumn<String>(
    'thumbnail_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbnailPathMeta = const VerificationMeta(
    'thumbnailPath',
  );
  @override
  late final GeneratedColumn<String> thumbnailPath = GeneratedColumn<String>(
    'thumbnail_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioOnlyMeta = const VerificationMeta(
    'audioOnly',
  );
  @override
  late final GeneratedColumn<bool> audioOnly = GeneratedColumn<bool>(
    'audio_only',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("audio_only" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _autoUpdateMeta = const VerificationMeta(
    'autoUpdate',
  );
  @override
  late final GeneratedColumn<bool> autoUpdate = GeneratedColumn<bool>(
    'auto_update',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_update" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _updateFrequencyHoursMeta =
      const VerificationMeta('updateFrequencyHours');
  @override
  late final GeneratedColumn<int> updateFrequencyHours = GeneratedColumn<int>(
    'update_frequency_hours',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(24),
  );
  static const VerificationMeta _includeThumbnailsMeta = const VerificationMeta(
    'includeThumbnails',
  );
  @override
  late final GeneratedColumn<bool> includeThumbnails = GeneratedColumn<bool>(
    'include_thumbnails',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("include_thumbnails" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _sponsorBlockEnabledMeta =
      const VerificationMeta('sponsorBlockEnabled');
  @override
  late final GeneratedColumn<bool> sponsorBlockEnabled = GeneratedColumn<bool>(
    'sponsor_block_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sponsor_block_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _sponsorBlockCategoriesMeta =
      const VerificationMeta('sponsorBlockCategories');
  @override
  late final GeneratedColumn<String> sponsorBlockCategories =
      GeneratedColumn<String>(
        'sponsor_block_categories',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(
          '["sponsor","selfpromo","music_offtopic"]',
        ),
      );
  static const VerificationMeta _sponsorBlockCategoryActionsMeta =
      const VerificationMeta('sponsorBlockCategoryActions');
  @override
  late final GeneratedColumn<String> sponsorBlockCategoryActions =
      GeneratedColumn<String>(
        'sponsor_block_category_actions',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(defaultSponsorBlockCategoryActionsJson),
      );
  static const VerificationMeta _lastUpdatedMeta = const VerificationMeta(
    'lastUpdated',
  );
  @override
  late final GeneratedColumn<DateTime> lastUpdated = GeneratedColumn<DateTime>(
    'last_updated',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outputPathMeta = const VerificationMeta(
    'outputPath',
  );
  @override
  late final GeneratedColumn<String> outputPath = GeneratedColumn<String>(
    'output_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    url,
    name,
    thumbnailUrl,
    thumbnailPath,
    audioOnly,
    autoUpdate,
    updateFrequencyHours,
    includeThumbnails,
    sponsorBlockEnabled,
    sponsorBlockCategories,
    sponsorBlockCategoryActions,
    lastUpdated,
    createdAt,
    outputPath,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playlists';
  @override
  VerificationContext validateIntegrity(
    Insertable<Playlist> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('thumbnail_url')) {
      context.handle(
        _thumbnailUrlMeta,
        thumbnailUrl.isAcceptableOrUnknown(
          data['thumbnail_url']!,
          _thumbnailUrlMeta,
        ),
      );
    }
    if (data.containsKey('thumbnail_path')) {
      context.handle(
        _thumbnailPathMeta,
        thumbnailPath.isAcceptableOrUnknown(
          data['thumbnail_path']!,
          _thumbnailPathMeta,
        ),
      );
    }
    if (data.containsKey('audio_only')) {
      context.handle(
        _audioOnlyMeta,
        audioOnly.isAcceptableOrUnknown(data['audio_only']!, _audioOnlyMeta),
      );
    }
    if (data.containsKey('auto_update')) {
      context.handle(
        _autoUpdateMeta,
        autoUpdate.isAcceptableOrUnknown(data['auto_update']!, _autoUpdateMeta),
      );
    }
    if (data.containsKey('update_frequency_hours')) {
      context.handle(
        _updateFrequencyHoursMeta,
        updateFrequencyHours.isAcceptableOrUnknown(
          data['update_frequency_hours']!,
          _updateFrequencyHoursMeta,
        ),
      );
    }
    if (data.containsKey('include_thumbnails')) {
      context.handle(
        _includeThumbnailsMeta,
        includeThumbnails.isAcceptableOrUnknown(
          data['include_thumbnails']!,
          _includeThumbnailsMeta,
        ),
      );
    }
    if (data.containsKey('sponsor_block_enabled')) {
      context.handle(
        _sponsorBlockEnabledMeta,
        sponsorBlockEnabled.isAcceptableOrUnknown(
          data['sponsor_block_enabled']!,
          _sponsorBlockEnabledMeta,
        ),
      );
    }
    if (data.containsKey('sponsor_block_categories')) {
      context.handle(
        _sponsorBlockCategoriesMeta,
        sponsorBlockCategories.isAcceptableOrUnknown(
          data['sponsor_block_categories']!,
          _sponsorBlockCategoriesMeta,
        ),
      );
    }
    if (data.containsKey('sponsor_block_category_actions')) {
      context.handle(
        _sponsorBlockCategoryActionsMeta,
        sponsorBlockCategoryActions.isAcceptableOrUnknown(
          data['sponsor_block_category_actions']!,
          _sponsorBlockCategoryActionsMeta,
        ),
      );
    }
    if (data.containsKey('last_updated')) {
      context.handle(
        _lastUpdatedMeta,
        lastUpdated.isAcceptableOrUnknown(
          data['last_updated']!,
          _lastUpdatedMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('output_path')) {
      context.handle(
        _outputPathMeta,
        outputPath.isAcceptableOrUnknown(data['output_path']!, _outputPathMeta),
      );
    } else if (isInserting) {
      context.missing(_outputPathMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Playlist map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Playlist(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}id'],
          )!,
      url:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}url'],
          )!,
      name:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}name'],
          )!,
      thumbnailUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_url'],
      ),
      thumbnailPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_path'],
      ),
      audioOnly:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}audio_only'],
          )!,
      autoUpdate:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}auto_update'],
          )!,
      updateFrequencyHours:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}update_frequency_hours'],
          )!,
      includeThumbnails:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}include_thumbnails'],
          )!,
      sponsorBlockEnabled:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}sponsor_block_enabled'],
          )!,
      sponsorBlockCategories:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}sponsor_block_categories'],
          )!,
      sponsorBlockCategoryActions:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}sponsor_block_category_actions'],
          )!,
      lastUpdated: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_updated'],
      ),
      createdAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}created_at'],
          )!,
      outputPath:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}output_path'],
          )!,
    );
  }

  @override
  $PlaylistsTable createAlias(String alias) {
    return $PlaylistsTable(attachedDatabase, alias);
  }
}

class Playlist extends DataClass implements Insertable<Playlist> {
  final int id;
  final String url;
  final String name;
  final String? thumbnailUrl;
  final String? thumbnailPath;
  final bool audioOnly;
  final bool autoUpdate;
  final int updateFrequencyHours;
  final bool includeThumbnails;
  final bool sponsorBlockEnabled;
  final String sponsorBlockCategories;
  final String sponsorBlockCategoryActions;
  final DateTime? lastUpdated;
  final DateTime createdAt;
  final String outputPath;
  const Playlist({
    required this.id,
    required this.url,
    required this.name,
    this.thumbnailUrl,
    this.thumbnailPath,
    required this.audioOnly,
    required this.autoUpdate,
    required this.updateFrequencyHours,
    required this.includeThumbnails,
    required this.sponsorBlockEnabled,
    required this.sponsorBlockCategories,
    required this.sponsorBlockCategoryActions,
    this.lastUpdated,
    required this.createdAt,
    required this.outputPath,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['url'] = Variable<String>(url);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || thumbnailUrl != null) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl);
    }
    if (!nullToAbsent || thumbnailPath != null) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath);
    }
    map['audio_only'] = Variable<bool>(audioOnly);
    map['auto_update'] = Variable<bool>(autoUpdate);
    map['update_frequency_hours'] = Variable<int>(updateFrequencyHours);
    map['include_thumbnails'] = Variable<bool>(includeThumbnails);
    map['sponsor_block_enabled'] = Variable<bool>(sponsorBlockEnabled);
    map['sponsor_block_categories'] = Variable<String>(sponsorBlockCategories);
    map['sponsor_block_category_actions'] = Variable<String>(
      sponsorBlockCategoryActions,
    );
    if (!nullToAbsent || lastUpdated != null) {
      map['last_updated'] = Variable<DateTime>(lastUpdated);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['output_path'] = Variable<String>(outputPath);
    return map;
  }

  PlaylistsCompanion toCompanion(bool nullToAbsent) {
    return PlaylistsCompanion(
      id: Value(id),
      url: Value(url),
      name: Value(name),
      thumbnailUrl:
          thumbnailUrl == null && nullToAbsent
              ? const Value.absent()
              : Value(thumbnailUrl),
      thumbnailPath:
          thumbnailPath == null && nullToAbsent
              ? const Value.absent()
              : Value(thumbnailPath),
      audioOnly: Value(audioOnly),
      autoUpdate: Value(autoUpdate),
      updateFrequencyHours: Value(updateFrequencyHours),
      includeThumbnails: Value(includeThumbnails),
      sponsorBlockEnabled: Value(sponsorBlockEnabled),
      sponsorBlockCategories: Value(sponsorBlockCategories),
      sponsorBlockCategoryActions: Value(sponsorBlockCategoryActions),
      lastUpdated:
          lastUpdated == null && nullToAbsent
              ? const Value.absent()
              : Value(lastUpdated),
      createdAt: Value(createdAt),
      outputPath: Value(outputPath),
    );
  }

  factory Playlist.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Playlist(
      id: serializer.fromJson<int>(json['id']),
      url: serializer.fromJson<String>(json['url']),
      name: serializer.fromJson<String>(json['name']),
      thumbnailUrl: serializer.fromJson<String?>(json['thumbnailUrl']),
      thumbnailPath: serializer.fromJson<String?>(json['thumbnailPath']),
      audioOnly: serializer.fromJson<bool>(json['audioOnly']),
      autoUpdate: serializer.fromJson<bool>(json['autoUpdate']),
      updateFrequencyHours: serializer.fromJson<int>(
        json['updateFrequencyHours'],
      ),
      includeThumbnails: serializer.fromJson<bool>(json['includeThumbnails']),
      sponsorBlockEnabled: serializer.fromJson<bool>(
        json['sponsorBlockEnabled'],
      ),
      sponsorBlockCategories: serializer.fromJson<String>(
        json['sponsorBlockCategories'],
      ),
      sponsorBlockCategoryActions: serializer.fromJson<String>(
        json['sponsorBlockCategoryActions'],
      ),
      lastUpdated: serializer.fromJson<DateTime?>(json['lastUpdated']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      outputPath: serializer.fromJson<String>(json['outputPath']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'url': serializer.toJson<String>(url),
      'name': serializer.toJson<String>(name),
      'thumbnailUrl': serializer.toJson<String?>(thumbnailUrl),
      'thumbnailPath': serializer.toJson<String?>(thumbnailPath),
      'audioOnly': serializer.toJson<bool>(audioOnly),
      'autoUpdate': serializer.toJson<bool>(autoUpdate),
      'updateFrequencyHours': serializer.toJson<int>(updateFrequencyHours),
      'includeThumbnails': serializer.toJson<bool>(includeThumbnails),
      'sponsorBlockEnabled': serializer.toJson<bool>(sponsorBlockEnabled),
      'sponsorBlockCategories': serializer.toJson<String>(
        sponsorBlockCategories,
      ),
      'sponsorBlockCategoryActions': serializer.toJson<String>(
        sponsorBlockCategoryActions,
      ),
      'lastUpdated': serializer.toJson<DateTime?>(lastUpdated),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'outputPath': serializer.toJson<String>(outputPath),
    };
  }

  Playlist copyWith({
    int? id,
    String? url,
    String? name,
    Value<String?> thumbnailUrl = const Value.absent(),
    Value<String?> thumbnailPath = const Value.absent(),
    bool? audioOnly,
    bool? autoUpdate,
    int? updateFrequencyHours,
    bool? includeThumbnails,
    bool? sponsorBlockEnabled,
    String? sponsorBlockCategories,
    String? sponsorBlockCategoryActions,
    Value<DateTime?> lastUpdated = const Value.absent(),
    DateTime? createdAt,
    String? outputPath,
  }) => Playlist(
    id: id ?? this.id,
    url: url ?? this.url,
    name: name ?? this.name,
    thumbnailUrl: thumbnailUrl.present ? thumbnailUrl.value : this.thumbnailUrl,
    thumbnailPath:
        thumbnailPath.present ? thumbnailPath.value : this.thumbnailPath,
    audioOnly: audioOnly ?? this.audioOnly,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    updateFrequencyHours: updateFrequencyHours ?? this.updateFrequencyHours,
    includeThumbnails: includeThumbnails ?? this.includeThumbnails,
    sponsorBlockEnabled: sponsorBlockEnabled ?? this.sponsorBlockEnabled,
    sponsorBlockCategories:
        sponsorBlockCategories ?? this.sponsorBlockCategories,
    sponsorBlockCategoryActions:
        sponsorBlockCategoryActions ?? this.sponsorBlockCategoryActions,
    lastUpdated: lastUpdated.present ? lastUpdated.value : this.lastUpdated,
    createdAt: createdAt ?? this.createdAt,
    outputPath: outputPath ?? this.outputPath,
  );
  Playlist copyWithCompanion(PlaylistsCompanion data) {
    return Playlist(
      id: data.id.present ? data.id.value : this.id,
      url: data.url.present ? data.url.value : this.url,
      name: data.name.present ? data.name.value : this.name,
      thumbnailUrl:
          data.thumbnailUrl.present
              ? data.thumbnailUrl.value
              : this.thumbnailUrl,
      thumbnailPath:
          data.thumbnailPath.present
              ? data.thumbnailPath.value
              : this.thumbnailPath,
      audioOnly: data.audioOnly.present ? data.audioOnly.value : this.audioOnly,
      autoUpdate:
          data.autoUpdate.present ? data.autoUpdate.value : this.autoUpdate,
      updateFrequencyHours:
          data.updateFrequencyHours.present
              ? data.updateFrequencyHours.value
              : this.updateFrequencyHours,
      includeThumbnails:
          data.includeThumbnails.present
              ? data.includeThumbnails.value
              : this.includeThumbnails,
      sponsorBlockEnabled:
          data.sponsorBlockEnabled.present
              ? data.sponsorBlockEnabled.value
              : this.sponsorBlockEnabled,
      sponsorBlockCategories:
          data.sponsorBlockCategories.present
              ? data.sponsorBlockCategories.value
              : this.sponsorBlockCategories,
      sponsorBlockCategoryActions:
          data.sponsorBlockCategoryActions.present
              ? data.sponsorBlockCategoryActions.value
              : this.sponsorBlockCategoryActions,
      lastUpdated:
          data.lastUpdated.present ? data.lastUpdated.value : this.lastUpdated,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      outputPath:
          data.outputPath.present ? data.outputPath.value : this.outputPath,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Playlist(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('name: $name, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('audioOnly: $audioOnly, ')
          ..write('autoUpdate: $autoUpdate, ')
          ..write('updateFrequencyHours: $updateFrequencyHours, ')
          ..write('includeThumbnails: $includeThumbnails, ')
          ..write('sponsorBlockEnabled: $sponsorBlockEnabled, ')
          ..write('sponsorBlockCategories: $sponsorBlockCategories, ')
          ..write('sponsorBlockCategoryActions: $sponsorBlockCategoryActions, ')
          ..write('lastUpdated: $lastUpdated, ')
          ..write('createdAt: $createdAt, ')
          ..write('outputPath: $outputPath')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    url,
    name,
    thumbnailUrl,
    thumbnailPath,
    audioOnly,
    autoUpdate,
    updateFrequencyHours,
    includeThumbnails,
    sponsorBlockEnabled,
    sponsorBlockCategories,
    sponsorBlockCategoryActions,
    lastUpdated,
    createdAt,
    outputPath,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Playlist &&
          other.id == this.id &&
          other.url == this.url &&
          other.name == this.name &&
          other.thumbnailUrl == this.thumbnailUrl &&
          other.thumbnailPath == this.thumbnailPath &&
          other.audioOnly == this.audioOnly &&
          other.autoUpdate == this.autoUpdate &&
          other.updateFrequencyHours == this.updateFrequencyHours &&
          other.includeThumbnails == this.includeThumbnails &&
          other.sponsorBlockEnabled == this.sponsorBlockEnabled &&
          other.sponsorBlockCategories == this.sponsorBlockCategories &&
          other.sponsorBlockCategoryActions ==
              this.sponsorBlockCategoryActions &&
          other.lastUpdated == this.lastUpdated &&
          other.createdAt == this.createdAt &&
          other.outputPath == this.outputPath);
}

class PlaylistsCompanion extends UpdateCompanion<Playlist> {
  final Value<int> id;
  final Value<String> url;
  final Value<String> name;
  final Value<String?> thumbnailUrl;
  final Value<String?> thumbnailPath;
  final Value<bool> audioOnly;
  final Value<bool> autoUpdate;
  final Value<int> updateFrequencyHours;
  final Value<bool> includeThumbnails;
  final Value<bool> sponsorBlockEnabled;
  final Value<String> sponsorBlockCategories;
  final Value<String> sponsorBlockCategoryActions;
  final Value<DateTime?> lastUpdated;
  final Value<DateTime> createdAt;
  final Value<String> outputPath;
  const PlaylistsCompanion({
    this.id = const Value.absent(),
    this.url = const Value.absent(),
    this.name = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.audioOnly = const Value.absent(),
    this.autoUpdate = const Value.absent(),
    this.updateFrequencyHours = const Value.absent(),
    this.includeThumbnails = const Value.absent(),
    this.sponsorBlockEnabled = const Value.absent(),
    this.sponsorBlockCategories = const Value.absent(),
    this.sponsorBlockCategoryActions = const Value.absent(),
    this.lastUpdated = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.outputPath = const Value.absent(),
  });
  PlaylistsCompanion.insert({
    this.id = const Value.absent(),
    required String url,
    required String name,
    this.thumbnailUrl = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.audioOnly = const Value.absent(),
    this.autoUpdate = const Value.absent(),
    this.updateFrequencyHours = const Value.absent(),
    this.includeThumbnails = const Value.absent(),
    this.sponsorBlockEnabled = const Value.absent(),
    this.sponsorBlockCategories = const Value.absent(),
    this.sponsorBlockCategoryActions = const Value.absent(),
    this.lastUpdated = const Value.absent(),
    required DateTime createdAt,
    required String outputPath,
  }) : url = Value(url),
       name = Value(name),
       createdAt = Value(createdAt),
       outputPath = Value(outputPath);
  static Insertable<Playlist> custom({
    Expression<int>? id,
    Expression<String>? url,
    Expression<String>? name,
    Expression<String>? thumbnailUrl,
    Expression<String>? thumbnailPath,
    Expression<bool>? audioOnly,
    Expression<bool>? autoUpdate,
    Expression<int>? updateFrequencyHours,
    Expression<bool>? includeThumbnails,
    Expression<bool>? sponsorBlockEnabled,
    Expression<String>? sponsorBlockCategories,
    Expression<String>? sponsorBlockCategoryActions,
    Expression<DateTime>? lastUpdated,
    Expression<DateTime>? createdAt,
    Expression<String>? outputPath,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (url != null) 'url': url,
      if (name != null) 'name': name,
      if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
      if (thumbnailPath != null) 'thumbnail_path': thumbnailPath,
      if (audioOnly != null) 'audio_only': audioOnly,
      if (autoUpdate != null) 'auto_update': autoUpdate,
      if (updateFrequencyHours != null)
        'update_frequency_hours': updateFrequencyHours,
      if (includeThumbnails != null) 'include_thumbnails': includeThumbnails,
      if (sponsorBlockEnabled != null)
        'sponsor_block_enabled': sponsorBlockEnabled,
      if (sponsorBlockCategories != null)
        'sponsor_block_categories': sponsorBlockCategories,
      if (sponsorBlockCategoryActions != null)
        'sponsor_block_category_actions': sponsorBlockCategoryActions,
      if (lastUpdated != null) 'last_updated': lastUpdated,
      if (createdAt != null) 'created_at': createdAt,
      if (outputPath != null) 'output_path': outputPath,
    });
  }

  PlaylistsCompanion copyWith({
    Value<int>? id,
    Value<String>? url,
    Value<String>? name,
    Value<String?>? thumbnailUrl,
    Value<String?>? thumbnailPath,
    Value<bool>? audioOnly,
    Value<bool>? autoUpdate,
    Value<int>? updateFrequencyHours,
    Value<bool>? includeThumbnails,
    Value<bool>? sponsorBlockEnabled,
    Value<String>? sponsorBlockCategories,
    Value<String>? sponsorBlockCategoryActions,
    Value<DateTime?>? lastUpdated,
    Value<DateTime>? createdAt,
    Value<String>? outputPath,
  }) {
    return PlaylistsCompanion(
      id: id ?? this.id,
      url: url ?? this.url,
      name: name ?? this.name,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      audioOnly: audioOnly ?? this.audioOnly,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      updateFrequencyHours: updateFrequencyHours ?? this.updateFrequencyHours,
      includeThumbnails: includeThumbnails ?? this.includeThumbnails,
      sponsorBlockEnabled: sponsorBlockEnabled ?? this.sponsorBlockEnabled,
      sponsorBlockCategories:
          sponsorBlockCategories ?? this.sponsorBlockCategories,
      sponsorBlockCategoryActions:
          sponsorBlockCategoryActions ?? this.sponsorBlockCategoryActions,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      createdAt: createdAt ?? this.createdAt,
      outputPath: outputPath ?? this.outputPath,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (thumbnailUrl.present) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl.value);
    }
    if (thumbnailPath.present) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath.value);
    }
    if (audioOnly.present) {
      map['audio_only'] = Variable<bool>(audioOnly.value);
    }
    if (autoUpdate.present) {
      map['auto_update'] = Variable<bool>(autoUpdate.value);
    }
    if (updateFrequencyHours.present) {
      map['update_frequency_hours'] = Variable<int>(updateFrequencyHours.value);
    }
    if (includeThumbnails.present) {
      map['include_thumbnails'] = Variable<bool>(includeThumbnails.value);
    }
    if (sponsorBlockEnabled.present) {
      map['sponsor_block_enabled'] = Variable<bool>(sponsorBlockEnabled.value);
    }
    if (sponsorBlockCategories.present) {
      map['sponsor_block_categories'] = Variable<String>(
        sponsorBlockCategories.value,
      );
    }
    if (sponsorBlockCategoryActions.present) {
      map['sponsor_block_category_actions'] = Variable<String>(
        sponsorBlockCategoryActions.value,
      );
    }
    if (lastUpdated.present) {
      map['last_updated'] = Variable<DateTime>(lastUpdated.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (outputPath.present) {
      map['output_path'] = Variable<String>(outputPath.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistsCompanion(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('name: $name, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('audioOnly: $audioOnly, ')
          ..write('autoUpdate: $autoUpdate, ')
          ..write('updateFrequencyHours: $updateFrequencyHours, ')
          ..write('includeThumbnails: $includeThumbnails, ')
          ..write('sponsorBlockEnabled: $sponsorBlockEnabled, ')
          ..write('sponsorBlockCategories: $sponsorBlockCategories, ')
          ..write('sponsorBlockCategoryActions: $sponsorBlockCategoryActions, ')
          ..write('lastUpdated: $lastUpdated, ')
          ..write('createdAt: $createdAt, ')
          ..write('outputPath: $outputPath')
          ..write(')'))
        .toString();
  }
}

class $TracksTable extends Tracks with TableInfo<$TracksTable, Track> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _playlistIdMeta = const VerificationMeta(
    'playlistId',
  );
  @override
  late final GeneratedColumn<int> playlistId = GeneratedColumn<int>(
    'playlist_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES playlists (id)',
    ),
  );
  static const VerificationMeta _indexMeta = const VerificationMeta('index');
  @override
  late final GeneratedColumn<int> index = GeneratedColumn<int>(
    'index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _videoIdMeta = const VerificationMeta(
    'videoId',
  );
  @override
  late final GeneratedColumn<String> videoId = GeneratedColumn<String>(
    'video_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbnailUrlMeta = const VerificationMeta(
    'thumbnailUrl',
  );
  @override
  late final GeneratedColumn<String> thumbnailUrl = GeneratedColumn<String>(
    'thumbnail_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbnailPathMeta = const VerificationMeta(
    'thumbnailPath',
  );
  @override
  late final GeneratedColumn<String> thumbnailPath = GeneratedColumn<String>(
    'thumbnail_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _unavailableReasonMeta = const VerificationMeta(
    'unavailableReason',
  );
  @override
  late final GeneratedColumn<String> unavailableReason =
      GeneratedColumn<String>(
        'unavailable_reason',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _isLocalReplacementMeta =
      const VerificationMeta('isLocalReplacement');
  @override
  late final GeneratedColumn<bool> isLocalReplacement = GeneratedColumn<bool>(
    'is_local_replacement',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_local_replacement" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _downloadedAtMeta = const VerificationMeta(
    'downloadedAt',
  );
  @override
  late final GeneratedColumn<DateTime> downloadedAt = GeneratedColumn<DateTime>(
    'downloaded_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sponsorBlockCheckedAtMeta =
      const VerificationMeta('sponsorBlockCheckedAt');
  @override
  late final GeneratedColumn<DateTime> sponsorBlockCheckedAt =
      GeneratedColumn<DateTime>(
        'sponsor_block_checked_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    playlistId,
    index,
    videoId,
    title,
    thumbnailUrl,
    thumbnailPath,
    filePath,
    durationSeconds,
    status,
    unavailableReason,
    isLocalReplacement,
    downloadedAt,
    sponsorBlockCheckedAt,
    lastError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tracks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Track> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('playlist_id')) {
      context.handle(
        _playlistIdMeta,
        playlistId.isAcceptableOrUnknown(data['playlist_id']!, _playlistIdMeta),
      );
    } else if (isInserting) {
      context.missing(_playlistIdMeta);
    }
    if (data.containsKey('index')) {
      context.handle(
        _indexMeta,
        index.isAcceptableOrUnknown(data['index']!, _indexMeta),
      );
    } else if (isInserting) {
      context.missing(_indexMeta);
    }
    if (data.containsKey('video_id')) {
      context.handle(
        _videoIdMeta,
        videoId.isAcceptableOrUnknown(data['video_id']!, _videoIdMeta),
      );
    } else if (isInserting) {
      context.missing(_videoIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('thumbnail_url')) {
      context.handle(
        _thumbnailUrlMeta,
        thumbnailUrl.isAcceptableOrUnknown(
          data['thumbnail_url']!,
          _thumbnailUrlMeta,
        ),
      );
    }
    if (data.containsKey('thumbnail_path')) {
      context.handle(
        _thumbnailPathMeta,
        thumbnailPath.isAcceptableOrUnknown(
          data['thumbnail_path']!,
          _thumbnailPathMeta,
        ),
      );
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('unavailable_reason')) {
      context.handle(
        _unavailableReasonMeta,
        unavailableReason.isAcceptableOrUnknown(
          data['unavailable_reason']!,
          _unavailableReasonMeta,
        ),
      );
    }
    if (data.containsKey('is_local_replacement')) {
      context.handle(
        _isLocalReplacementMeta,
        isLocalReplacement.isAcceptableOrUnknown(
          data['is_local_replacement']!,
          _isLocalReplacementMeta,
        ),
      );
    }
    if (data.containsKey('downloaded_at')) {
      context.handle(
        _downloadedAtMeta,
        downloadedAt.isAcceptableOrUnknown(
          data['downloaded_at']!,
          _downloadedAtMeta,
        ),
      );
    }
    if (data.containsKey('sponsor_block_checked_at')) {
      context.handle(
        _sponsorBlockCheckedAtMeta,
        sponsorBlockCheckedAt.isAcceptableOrUnknown(
          data['sponsor_block_checked_at']!,
          _sponsorBlockCheckedAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Track map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Track(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}id'],
          )!,
      playlistId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}playlist_id'],
          )!,
      index:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}index'],
          )!,
      videoId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}video_id'],
          )!,
      title:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}title'],
          )!,
      thumbnailUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_url'],
      ),
      thumbnailPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_path'],
      ),
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      ),
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      ),
      status:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}status'],
          )!,
      unavailableReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unavailable_reason'],
      ),
      isLocalReplacement:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_local_replacement'],
          )!,
      downloadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}downloaded_at'],
      ),
      sponsorBlockCheckedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}sponsor_block_checked_at'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $TracksTable createAlias(String alias) {
    return $TracksTable(attachedDatabase, alias);
  }
}

class Track extends DataClass implements Insertable<Track> {
  final int id;
  final int playlistId;
  final int index;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final String? thumbnailPath;
  final String? filePath;
  final int? durationSeconds;
  final String status;
  final String? unavailableReason;
  final bool isLocalReplacement;
  final DateTime? downloadedAt;
  final DateTime? sponsorBlockCheckedAt;
  final String? lastError;
  const Track({
    required this.id,
    required this.playlistId,
    required this.index,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.thumbnailPath,
    this.filePath,
    this.durationSeconds,
    required this.status,
    this.unavailableReason,
    required this.isLocalReplacement,
    this.downloadedAt,
    this.sponsorBlockCheckedAt,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['playlist_id'] = Variable<int>(playlistId);
    map['index'] = Variable<int>(index);
    map['video_id'] = Variable<String>(videoId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || thumbnailUrl != null) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl);
    }
    if (!nullToAbsent || thumbnailPath != null) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath);
    }
    if (!nullToAbsent || filePath != null) {
      map['file_path'] = Variable<String>(filePath);
    }
    if (!nullToAbsent || durationSeconds != null) {
      map['duration_seconds'] = Variable<int>(durationSeconds);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || unavailableReason != null) {
      map['unavailable_reason'] = Variable<String>(unavailableReason);
    }
    map['is_local_replacement'] = Variable<bool>(isLocalReplacement);
    if (!nullToAbsent || downloadedAt != null) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt);
    }
    if (!nullToAbsent || sponsorBlockCheckedAt != null) {
      map['sponsor_block_checked_at'] = Variable<DateTime>(
        sponsorBlockCheckedAt,
      );
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  TracksCompanion toCompanion(bool nullToAbsent) {
    return TracksCompanion(
      id: Value(id),
      playlistId: Value(playlistId),
      index: Value(index),
      videoId: Value(videoId),
      title: Value(title),
      thumbnailUrl:
          thumbnailUrl == null && nullToAbsent
              ? const Value.absent()
              : Value(thumbnailUrl),
      thumbnailPath:
          thumbnailPath == null && nullToAbsent
              ? const Value.absent()
              : Value(thumbnailPath),
      filePath:
          filePath == null && nullToAbsent
              ? const Value.absent()
              : Value(filePath),
      durationSeconds:
          durationSeconds == null && nullToAbsent
              ? const Value.absent()
              : Value(durationSeconds),
      status: Value(status),
      unavailableReason:
          unavailableReason == null && nullToAbsent
              ? const Value.absent()
              : Value(unavailableReason),
      isLocalReplacement: Value(isLocalReplacement),
      downloadedAt:
          downloadedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(downloadedAt),
      sponsorBlockCheckedAt:
          sponsorBlockCheckedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(sponsorBlockCheckedAt),
      lastError:
          lastError == null && nullToAbsent
              ? const Value.absent()
              : Value(lastError),
    );
  }

  factory Track.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Track(
      id: serializer.fromJson<int>(json['id']),
      playlistId: serializer.fromJson<int>(json['playlistId']),
      index: serializer.fromJson<int>(json['index']),
      videoId: serializer.fromJson<String>(json['videoId']),
      title: serializer.fromJson<String>(json['title']),
      thumbnailUrl: serializer.fromJson<String?>(json['thumbnailUrl']),
      thumbnailPath: serializer.fromJson<String?>(json['thumbnailPath']),
      filePath: serializer.fromJson<String?>(json['filePath']),
      durationSeconds: serializer.fromJson<int?>(json['durationSeconds']),
      status: serializer.fromJson<String>(json['status']),
      unavailableReason: serializer.fromJson<String?>(
        json['unavailableReason'],
      ),
      isLocalReplacement: serializer.fromJson<bool>(json['isLocalReplacement']),
      downloadedAt: serializer.fromJson<DateTime?>(json['downloadedAt']),
      sponsorBlockCheckedAt: serializer.fromJson<DateTime?>(
        json['sponsorBlockCheckedAt'],
      ),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'playlistId': serializer.toJson<int>(playlistId),
      'index': serializer.toJson<int>(index),
      'videoId': serializer.toJson<String>(videoId),
      'title': serializer.toJson<String>(title),
      'thumbnailUrl': serializer.toJson<String?>(thumbnailUrl),
      'thumbnailPath': serializer.toJson<String?>(thumbnailPath),
      'filePath': serializer.toJson<String?>(filePath),
      'durationSeconds': serializer.toJson<int?>(durationSeconds),
      'status': serializer.toJson<String>(status),
      'unavailableReason': serializer.toJson<String?>(unavailableReason),
      'isLocalReplacement': serializer.toJson<bool>(isLocalReplacement),
      'downloadedAt': serializer.toJson<DateTime?>(downloadedAt),
      'sponsorBlockCheckedAt': serializer.toJson<DateTime?>(
        sponsorBlockCheckedAt,
      ),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  Track copyWith({
    int? id,
    int? playlistId,
    int? index,
    String? videoId,
    String? title,
    Value<String?> thumbnailUrl = const Value.absent(),
    Value<String?> thumbnailPath = const Value.absent(),
    Value<String?> filePath = const Value.absent(),
    Value<int?> durationSeconds = const Value.absent(),
    String? status,
    Value<String?> unavailableReason = const Value.absent(),
    bool? isLocalReplacement,
    Value<DateTime?> downloadedAt = const Value.absent(),
    Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
  }) => Track(
    id: id ?? this.id,
    playlistId: playlistId ?? this.playlistId,
    index: index ?? this.index,
    videoId: videoId ?? this.videoId,
    title: title ?? this.title,
    thumbnailUrl: thumbnailUrl.present ? thumbnailUrl.value : this.thumbnailUrl,
    thumbnailPath:
        thumbnailPath.present ? thumbnailPath.value : this.thumbnailPath,
    filePath: filePath.present ? filePath.value : this.filePath,
    durationSeconds:
        durationSeconds.present ? durationSeconds.value : this.durationSeconds,
    status: status ?? this.status,
    unavailableReason:
        unavailableReason.present
            ? unavailableReason.value
            : this.unavailableReason,
    isLocalReplacement: isLocalReplacement ?? this.isLocalReplacement,
    downloadedAt: downloadedAt.present ? downloadedAt.value : this.downloadedAt,
    sponsorBlockCheckedAt:
        sponsorBlockCheckedAt.present
            ? sponsorBlockCheckedAt.value
            : this.sponsorBlockCheckedAt,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  Track copyWithCompanion(TracksCompanion data) {
    return Track(
      id: data.id.present ? data.id.value : this.id,
      playlistId:
          data.playlistId.present ? data.playlistId.value : this.playlistId,
      index: data.index.present ? data.index.value : this.index,
      videoId: data.videoId.present ? data.videoId.value : this.videoId,
      title: data.title.present ? data.title.value : this.title,
      thumbnailUrl:
          data.thumbnailUrl.present
              ? data.thumbnailUrl.value
              : this.thumbnailUrl,
      thumbnailPath:
          data.thumbnailPath.present
              ? data.thumbnailPath.value
              : this.thumbnailPath,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      durationSeconds:
          data.durationSeconds.present
              ? data.durationSeconds.value
              : this.durationSeconds,
      status: data.status.present ? data.status.value : this.status,
      unavailableReason:
          data.unavailableReason.present
              ? data.unavailableReason.value
              : this.unavailableReason,
      isLocalReplacement:
          data.isLocalReplacement.present
              ? data.isLocalReplacement.value
              : this.isLocalReplacement,
      downloadedAt:
          data.downloadedAt.present
              ? data.downloadedAt.value
              : this.downloadedAt,
      sponsorBlockCheckedAt:
          data.sponsorBlockCheckedAt.present
              ? data.sponsorBlockCheckedAt.value
              : this.sponsorBlockCheckedAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Track(')
          ..write('id: $id, ')
          ..write('playlistId: $playlistId, ')
          ..write('index: $index, ')
          ..write('videoId: $videoId, ')
          ..write('title: $title, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('filePath: $filePath, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('status: $status, ')
          ..write('unavailableReason: $unavailableReason, ')
          ..write('isLocalReplacement: $isLocalReplacement, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('sponsorBlockCheckedAt: $sponsorBlockCheckedAt, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    playlistId,
    index,
    videoId,
    title,
    thumbnailUrl,
    thumbnailPath,
    filePath,
    durationSeconds,
    status,
    unavailableReason,
    isLocalReplacement,
    downloadedAt,
    sponsorBlockCheckedAt,
    lastError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Track &&
          other.id == this.id &&
          other.playlistId == this.playlistId &&
          other.index == this.index &&
          other.videoId == this.videoId &&
          other.title == this.title &&
          other.thumbnailUrl == this.thumbnailUrl &&
          other.thumbnailPath == this.thumbnailPath &&
          other.filePath == this.filePath &&
          other.durationSeconds == this.durationSeconds &&
          other.status == this.status &&
          other.unavailableReason == this.unavailableReason &&
          other.isLocalReplacement == this.isLocalReplacement &&
          other.downloadedAt == this.downloadedAt &&
          other.sponsorBlockCheckedAt == this.sponsorBlockCheckedAt &&
          other.lastError == this.lastError);
}

class TracksCompanion extends UpdateCompanion<Track> {
  final Value<int> id;
  final Value<int> playlistId;
  final Value<int> index;
  final Value<String> videoId;
  final Value<String> title;
  final Value<String?> thumbnailUrl;
  final Value<String?> thumbnailPath;
  final Value<String?> filePath;
  final Value<int?> durationSeconds;
  final Value<String> status;
  final Value<String?> unavailableReason;
  final Value<bool> isLocalReplacement;
  final Value<DateTime?> downloadedAt;
  final Value<DateTime?> sponsorBlockCheckedAt;
  final Value<String?> lastError;
  const TracksCompanion({
    this.id = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.index = const Value.absent(),
    this.videoId = const Value.absent(),
    this.title = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.filePath = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.status = const Value.absent(),
    this.unavailableReason = const Value.absent(),
    this.isLocalReplacement = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.sponsorBlockCheckedAt = const Value.absent(),
    this.lastError = const Value.absent(),
  });
  TracksCompanion.insert({
    this.id = const Value.absent(),
    required int playlistId,
    required int index,
    required String videoId,
    required String title,
    this.thumbnailUrl = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.filePath = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.status = const Value.absent(),
    this.unavailableReason = const Value.absent(),
    this.isLocalReplacement = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.sponsorBlockCheckedAt = const Value.absent(),
    this.lastError = const Value.absent(),
  }) : playlistId = Value(playlistId),
       index = Value(index),
       videoId = Value(videoId),
       title = Value(title);
  static Insertable<Track> custom({
    Expression<int>? id,
    Expression<int>? playlistId,
    Expression<int>? index,
    Expression<String>? videoId,
    Expression<String>? title,
    Expression<String>? thumbnailUrl,
    Expression<String>? thumbnailPath,
    Expression<String>? filePath,
    Expression<int>? durationSeconds,
    Expression<String>? status,
    Expression<String>? unavailableReason,
    Expression<bool>? isLocalReplacement,
    Expression<DateTime>? downloadedAt,
    Expression<DateTime>? sponsorBlockCheckedAt,
    Expression<String>? lastError,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (playlistId != null) 'playlist_id': playlistId,
      if (index != null) 'index': index,
      if (videoId != null) 'video_id': videoId,
      if (title != null) 'title': title,
      if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
      if (thumbnailPath != null) 'thumbnail_path': thumbnailPath,
      if (filePath != null) 'file_path': filePath,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (status != null) 'status': status,
      if (unavailableReason != null) 'unavailable_reason': unavailableReason,
      if (isLocalReplacement != null)
        'is_local_replacement': isLocalReplacement,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (sponsorBlockCheckedAt != null)
        'sponsor_block_checked_at': sponsorBlockCheckedAt,
      if (lastError != null) 'last_error': lastError,
    });
  }

  TracksCompanion copyWith({
    Value<int>? id,
    Value<int>? playlistId,
    Value<int>? index,
    Value<String>? videoId,
    Value<String>? title,
    Value<String?>? thumbnailUrl,
    Value<String?>? thumbnailPath,
    Value<String?>? filePath,
    Value<int?>? durationSeconds,
    Value<String>? status,
    Value<String?>? unavailableReason,
    Value<bool>? isLocalReplacement,
    Value<DateTime?>? downloadedAt,
    Value<DateTime?>? sponsorBlockCheckedAt,
    Value<String?>? lastError,
  }) {
    return TracksCompanion(
      id: id ?? this.id,
      playlistId: playlistId ?? this.playlistId,
      index: index ?? this.index,
      videoId: videoId ?? this.videoId,
      title: title ?? this.title,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      filePath: filePath ?? this.filePath,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      status: status ?? this.status,
      unavailableReason: unavailableReason ?? this.unavailableReason,
      isLocalReplacement: isLocalReplacement ?? this.isLocalReplacement,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      sponsorBlockCheckedAt:
          sponsorBlockCheckedAt ?? this.sponsorBlockCheckedAt,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (playlistId.present) {
      map['playlist_id'] = Variable<int>(playlistId.value);
    }
    if (index.present) {
      map['index'] = Variable<int>(index.value);
    }
    if (videoId.present) {
      map['video_id'] = Variable<String>(videoId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (thumbnailUrl.present) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl.value);
    }
    if (thumbnailPath.present) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (unavailableReason.present) {
      map['unavailable_reason'] = Variable<String>(unavailableReason.value);
    }
    if (isLocalReplacement.present) {
      map['is_local_replacement'] = Variable<bool>(isLocalReplacement.value);
    }
    if (downloadedAt.present) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt.value);
    }
    if (sponsorBlockCheckedAt.present) {
      map['sponsor_block_checked_at'] = Variable<DateTime>(
        sponsorBlockCheckedAt.value,
      );
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TracksCompanion(')
          ..write('id: $id, ')
          ..write('playlistId: $playlistId, ')
          ..write('index: $index, ')
          ..write('videoId: $videoId, ')
          ..write('title: $title, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('filePath: $filePath, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('status: $status, ')
          ..write('unavailableReason: $unavailableReason, ')
          ..write('isLocalReplacement: $isLocalReplacement, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('sponsorBlockCheckedAt: $sponsorBlockCheckedAt, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }
}

class $SponsorBlockSegmentsTable extends SponsorBlockSegments
    with TableInfo<$SponsorBlockSegmentsTable, SponsorBlockSegment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SponsorBlockSegmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _trackIdMeta = const VerificationMeta(
    'trackId',
  );
  @override
  late final GeneratedColumn<int> trackId = GeneratedColumn<int>(
    'track_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tracks (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _videoIdMeta = const VerificationMeta(
    'videoId',
  );
  @override
  late final GeneratedColumn<String> videoId = GeneratedColumn<String>(
    'video_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
    'uuid',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actionTypeMeta = const VerificationMeta(
    'actionType',
  );
  @override
  late final GeneratedColumn<String> actionType = GeneratedColumn<String>(
    'action_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('skip'),
  );
  static const VerificationMeta _startMsMeta = const VerificationMeta(
    'startMs',
  );
  @override
  late final GeneratedColumn<int> startMs = GeneratedColumn<int>(
    'start_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endMsMeta = const VerificationMeta('endMs');
  @override
  late final GeneratedColumn<int> endMs = GeneratedColumn<int>(
    'end_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _votesMeta = const VerificationMeta('votes');
  @override
  late final GeneratedColumn<int> votes = GeneratedColumn<int>(
    'votes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    trackId,
    videoId,
    source,
    uuid,
    category,
    actionType,
    startMs,
    endMs,
    votes,
    locked,
    description,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sponsor_block_segments';
  @override
  VerificationContext validateIntegrity(
    Insertable<SponsorBlockSegment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('track_id')) {
      context.handle(
        _trackIdMeta,
        trackId.isAcceptableOrUnknown(data['track_id']!, _trackIdMeta),
      );
    } else if (isInserting) {
      context.missing(_trackIdMeta);
    }
    if (data.containsKey('video_id')) {
      context.handle(
        _videoIdMeta,
        videoId.isAcceptableOrUnknown(data['video_id']!, _videoIdMeta),
      );
    } else if (isInserting) {
      context.missing(_videoIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('uuid')) {
      context.handle(
        _uuidMeta,
        uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('action_type')) {
      context.handle(
        _actionTypeMeta,
        actionType.isAcceptableOrUnknown(data['action_type']!, _actionTypeMeta),
      );
    }
    if (data.containsKey('start_ms')) {
      context.handle(
        _startMsMeta,
        startMs.isAcceptableOrUnknown(data['start_ms']!, _startMsMeta),
      );
    } else if (isInserting) {
      context.missing(_startMsMeta);
    }
    if (data.containsKey('end_ms')) {
      context.handle(
        _endMsMeta,
        endMs.isAcceptableOrUnknown(data['end_ms']!, _endMsMeta),
      );
    } else if (isInserting) {
      context.missing(_endMsMeta);
    }
    if (data.containsKey('votes')) {
      context.handle(
        _votesMeta,
        votes.isAcceptableOrUnknown(data['votes']!, _votesMeta),
      );
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SponsorBlockSegment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SponsorBlockSegment(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}id'],
          )!,
      trackId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}track_id'],
          )!,
      videoId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}video_id'],
          )!,
      source:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}source'],
          )!,
      uuid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}uuid'],
      ),
      category:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}category'],
          )!,
      actionType:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}action_type'],
          )!,
      startMs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}start_ms'],
          )!,
      endMs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}end_ms'],
          )!,
      votes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}votes'],
      ),
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      ),
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      createdAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}created_at'],
          )!,
    );
  }

  @override
  $SponsorBlockSegmentsTable createAlias(String alias) {
    return $SponsorBlockSegmentsTable(attachedDatabase, alias);
  }
}

class SponsorBlockSegment extends DataClass
    implements Insertable<SponsorBlockSegment> {
  final int id;
  final int trackId;
  final String videoId;
  final String source;
  final String? uuid;
  final String category;
  final String actionType;
  final int startMs;
  final int endMs;
  final int? votes;
  final bool? locked;
  final String? description;
  final DateTime createdAt;
  const SponsorBlockSegment({
    required this.id,
    required this.trackId,
    required this.videoId,
    required this.source,
    this.uuid,
    required this.category,
    required this.actionType,
    required this.startMs,
    required this.endMs,
    this.votes,
    this.locked,
    this.description,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['track_id'] = Variable<int>(trackId);
    map['video_id'] = Variable<String>(videoId);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || uuid != null) {
      map['uuid'] = Variable<String>(uuid);
    }
    map['category'] = Variable<String>(category);
    map['action_type'] = Variable<String>(actionType);
    map['start_ms'] = Variable<int>(startMs);
    map['end_ms'] = Variable<int>(endMs);
    if (!nullToAbsent || votes != null) {
      map['votes'] = Variable<int>(votes);
    }
    if (!nullToAbsent || locked != null) {
      map['locked'] = Variable<bool>(locked);
    }
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SponsorBlockSegmentsCompanion toCompanion(bool nullToAbsent) {
    return SponsorBlockSegmentsCompanion(
      id: Value(id),
      trackId: Value(trackId),
      videoId: Value(videoId),
      source: Value(source),
      uuid: uuid == null && nullToAbsent ? const Value.absent() : Value(uuid),
      category: Value(category),
      actionType: Value(actionType),
      startMs: Value(startMs),
      endMs: Value(endMs),
      votes:
          votes == null && nullToAbsent ? const Value.absent() : Value(votes),
      locked:
          locked == null && nullToAbsent ? const Value.absent() : Value(locked),
      description:
          description == null && nullToAbsent
              ? const Value.absent()
              : Value(description),
      createdAt: Value(createdAt),
    );
  }

  factory SponsorBlockSegment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SponsorBlockSegment(
      id: serializer.fromJson<int>(json['id']),
      trackId: serializer.fromJson<int>(json['trackId']),
      videoId: serializer.fromJson<String>(json['videoId']),
      source: serializer.fromJson<String>(json['source']),
      uuid: serializer.fromJson<String?>(json['uuid']),
      category: serializer.fromJson<String>(json['category']),
      actionType: serializer.fromJson<String>(json['actionType']),
      startMs: serializer.fromJson<int>(json['startMs']),
      endMs: serializer.fromJson<int>(json['endMs']),
      votes: serializer.fromJson<int?>(json['votes']),
      locked: serializer.fromJson<bool?>(json['locked']),
      description: serializer.fromJson<String?>(json['description']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'trackId': serializer.toJson<int>(trackId),
      'videoId': serializer.toJson<String>(videoId),
      'source': serializer.toJson<String>(source),
      'uuid': serializer.toJson<String?>(uuid),
      'category': serializer.toJson<String>(category),
      'actionType': serializer.toJson<String>(actionType),
      'startMs': serializer.toJson<int>(startMs),
      'endMs': serializer.toJson<int>(endMs),
      'votes': serializer.toJson<int?>(votes),
      'locked': serializer.toJson<bool?>(locked),
      'description': serializer.toJson<String?>(description),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SponsorBlockSegment copyWith({
    int? id,
    int? trackId,
    String? videoId,
    String? source,
    Value<String?> uuid = const Value.absent(),
    String? category,
    String? actionType,
    int? startMs,
    int? endMs,
    Value<int?> votes = const Value.absent(),
    Value<bool?> locked = const Value.absent(),
    Value<String?> description = const Value.absent(),
    DateTime? createdAt,
  }) => SponsorBlockSegment(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    videoId: videoId ?? this.videoId,
    source: source ?? this.source,
    uuid: uuid.present ? uuid.value : this.uuid,
    category: category ?? this.category,
    actionType: actionType ?? this.actionType,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    votes: votes.present ? votes.value : this.votes,
    locked: locked.present ? locked.value : this.locked,
    description: description.present ? description.value : this.description,
    createdAt: createdAt ?? this.createdAt,
  );
  SponsorBlockSegment copyWithCompanion(SponsorBlockSegmentsCompanion data) {
    return SponsorBlockSegment(
      id: data.id.present ? data.id.value : this.id,
      trackId: data.trackId.present ? data.trackId.value : this.trackId,
      videoId: data.videoId.present ? data.videoId.value : this.videoId,
      source: data.source.present ? data.source.value : this.source,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      category: data.category.present ? data.category.value : this.category,
      actionType:
          data.actionType.present ? data.actionType.value : this.actionType,
      startMs: data.startMs.present ? data.startMs.value : this.startMs,
      endMs: data.endMs.present ? data.endMs.value : this.endMs,
      votes: data.votes.present ? data.votes.value : this.votes,
      locked: data.locked.present ? data.locked.value : this.locked,
      description:
          data.description.present ? data.description.value : this.description,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SponsorBlockSegment(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('videoId: $videoId, ')
          ..write('source: $source, ')
          ..write('uuid: $uuid, ')
          ..write('category: $category, ')
          ..write('actionType: $actionType, ')
          ..write('startMs: $startMs, ')
          ..write('endMs: $endMs, ')
          ..write('votes: $votes, ')
          ..write('locked: $locked, ')
          ..write('description: $description, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    trackId,
    videoId,
    source,
    uuid,
    category,
    actionType,
    startMs,
    endMs,
    votes,
    locked,
    description,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SponsorBlockSegment &&
          other.id == this.id &&
          other.trackId == this.trackId &&
          other.videoId == this.videoId &&
          other.source == this.source &&
          other.uuid == this.uuid &&
          other.category == this.category &&
          other.actionType == this.actionType &&
          other.startMs == this.startMs &&
          other.endMs == this.endMs &&
          other.votes == this.votes &&
          other.locked == this.locked &&
          other.description == this.description &&
          other.createdAt == this.createdAt);
}

class SponsorBlockSegmentsCompanion
    extends UpdateCompanion<SponsorBlockSegment> {
  final Value<int> id;
  final Value<int> trackId;
  final Value<String> videoId;
  final Value<String> source;
  final Value<String?> uuid;
  final Value<String> category;
  final Value<String> actionType;
  final Value<int> startMs;
  final Value<int> endMs;
  final Value<int?> votes;
  final Value<bool?> locked;
  final Value<String?> description;
  final Value<DateTime> createdAt;
  const SponsorBlockSegmentsCompanion({
    this.id = const Value.absent(),
    this.trackId = const Value.absent(),
    this.videoId = const Value.absent(),
    this.source = const Value.absent(),
    this.uuid = const Value.absent(),
    this.category = const Value.absent(),
    this.actionType = const Value.absent(),
    this.startMs = const Value.absent(),
    this.endMs = const Value.absent(),
    this.votes = const Value.absent(),
    this.locked = const Value.absent(),
    this.description = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SponsorBlockSegmentsCompanion.insert({
    this.id = const Value.absent(),
    required int trackId,
    required String videoId,
    required String source,
    this.uuid = const Value.absent(),
    required String category,
    this.actionType = const Value.absent(),
    required int startMs,
    required int endMs,
    this.votes = const Value.absent(),
    this.locked = const Value.absent(),
    this.description = const Value.absent(),
    required DateTime createdAt,
  }) : trackId = Value(trackId),
       videoId = Value(videoId),
       source = Value(source),
       category = Value(category),
       startMs = Value(startMs),
       endMs = Value(endMs),
       createdAt = Value(createdAt);
  static Insertable<SponsorBlockSegment> custom({
    Expression<int>? id,
    Expression<int>? trackId,
    Expression<String>? videoId,
    Expression<String>? source,
    Expression<String>? uuid,
    Expression<String>? category,
    Expression<String>? actionType,
    Expression<int>? startMs,
    Expression<int>? endMs,
    Expression<int>? votes,
    Expression<bool>? locked,
    Expression<String>? description,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (trackId != null) 'track_id': trackId,
      if (videoId != null) 'video_id': videoId,
      if (source != null) 'source': source,
      if (uuid != null) 'uuid': uuid,
      if (category != null) 'category': category,
      if (actionType != null) 'action_type': actionType,
      if (startMs != null) 'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      if (votes != null) 'votes': votes,
      if (locked != null) 'locked': locked,
      if (description != null) 'description': description,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SponsorBlockSegmentsCompanion copyWith({
    Value<int>? id,
    Value<int>? trackId,
    Value<String>? videoId,
    Value<String>? source,
    Value<String?>? uuid,
    Value<String>? category,
    Value<String>? actionType,
    Value<int>? startMs,
    Value<int>? endMs,
    Value<int?>? votes,
    Value<bool?>? locked,
    Value<String?>? description,
    Value<DateTime>? createdAt,
  }) {
    return SponsorBlockSegmentsCompanion(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      videoId: videoId ?? this.videoId,
      source: source ?? this.source,
      uuid: uuid ?? this.uuid,
      category: category ?? this.category,
      actionType: actionType ?? this.actionType,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      votes: votes ?? this.votes,
      locked: locked ?? this.locked,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (trackId.present) {
      map['track_id'] = Variable<int>(trackId.value);
    }
    if (videoId.present) {
      map['video_id'] = Variable<String>(videoId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (actionType.present) {
      map['action_type'] = Variable<String>(actionType.value);
    }
    if (startMs.present) {
      map['start_ms'] = Variable<int>(startMs.value);
    }
    if (endMs.present) {
      map['end_ms'] = Variable<int>(endMs.value);
    }
    if (votes.present) {
      map['votes'] = Variable<int>(votes.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SponsorBlockSegmentsCompanion(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('videoId: $videoId, ')
          ..write('source: $source, ')
          ..write('uuid: $uuid, ')
          ..write('category: $category, ')
          ..write('actionType: $actionType, ')
          ..write('startMs: $startMs, ')
          ..write('endMs: $endMs, ')
          ..write('votes: $votes, ')
          ..write('locked: $locked, ')
          ..write('description: $description, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $PlaylistsTable playlists = $PlaylistsTable(this);
  late final $TracksTable tracks = $TracksTable(this);
  late final $SponsorBlockSegmentsTable sponsorBlockSegments =
      $SponsorBlockSegmentsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    playlists,
    tracks,
    sponsorBlockSegments,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tracks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('sponsor_block_segments', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$PlaylistsTableCreateCompanionBuilder =
    PlaylistsCompanion Function({
      Value<int> id,
      required String url,
      required String name,
      Value<String?> thumbnailUrl,
      Value<String?> thumbnailPath,
      Value<bool> audioOnly,
      Value<bool> autoUpdate,
      Value<int> updateFrequencyHours,
      Value<bool> includeThumbnails,
      Value<bool> sponsorBlockEnabled,
      Value<String> sponsorBlockCategories,
      Value<String> sponsorBlockCategoryActions,
      Value<DateTime?> lastUpdated,
      required DateTime createdAt,
      required String outputPath,
    });
typedef $$PlaylistsTableUpdateCompanionBuilder =
    PlaylistsCompanion Function({
      Value<int> id,
      Value<String> url,
      Value<String> name,
      Value<String?> thumbnailUrl,
      Value<String?> thumbnailPath,
      Value<bool> audioOnly,
      Value<bool> autoUpdate,
      Value<int> updateFrequencyHours,
      Value<bool> includeThumbnails,
      Value<bool> sponsorBlockEnabled,
      Value<String> sponsorBlockCategories,
      Value<String> sponsorBlockCategoryActions,
      Value<DateTime?> lastUpdated,
      Value<DateTime> createdAt,
      Value<String> outputPath,
    });

final class $$PlaylistsTableReferences
    extends BaseReferences<_$AppDatabase, $PlaylistsTable, Playlist> {
  $$PlaylistsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$TracksTable, List<Track>> _tracksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.tracks,
    aliasName: $_aliasNameGenerator(db.playlists.id, db.tracks.playlistId),
  );

  $$TracksTableProcessedTableManager get tracksRefs {
    final manager = $$TracksTableTableManager(
      $_db,
      $_db.tracks,
    ).filter((f) => f.playlistId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_tracksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlaylistsTableFilterComposer
    extends Composer<_$AppDatabase, $PlaylistsTable> {
  $$PlaylistsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get audioOnly => $composableBuilder(
    column: $table.audioOnly,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoUpdate => $composableBuilder(
    column: $table.autoUpdate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updateFrequencyHours => $composableBuilder(
    column: $table.updateFrequencyHours,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get includeThumbnails => $composableBuilder(
    column: $table.includeThumbnails,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get sponsorBlockEnabled => $composableBuilder(
    column: $table.sponsorBlockEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sponsorBlockCategories => $composableBuilder(
    column: $table.sponsorBlockCategories,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sponsorBlockCategoryActions => $composableBuilder(
    column: $table.sponsorBlockCategoryActions,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastUpdated => $composableBuilder(
    column: $table.lastUpdated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outputPath => $composableBuilder(
    column: $table.outputPath,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> tracksRefs(
    Expression<bool> Function($$TracksTableFilterComposer f) f,
  ) {
    final $$TracksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.playlistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableFilterComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaylistsTableOrderingComposer
    extends Composer<_$AppDatabase, $PlaylistsTable> {
  $$PlaylistsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get audioOnly => $composableBuilder(
    column: $table.audioOnly,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoUpdate => $composableBuilder(
    column: $table.autoUpdate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updateFrequencyHours => $composableBuilder(
    column: $table.updateFrequencyHours,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get includeThumbnails => $composableBuilder(
    column: $table.includeThumbnails,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get sponsorBlockEnabled => $composableBuilder(
    column: $table.sponsorBlockEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sponsorBlockCategories => $composableBuilder(
    column: $table.sponsorBlockCategories,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sponsorBlockCategoryActions => $composableBuilder(
    column: $table.sponsorBlockCategoryActions,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastUpdated => $composableBuilder(
    column: $table.lastUpdated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outputPath => $composableBuilder(
    column: $table.outputPath,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PlaylistsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlaylistsTable> {
  $$PlaylistsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get audioOnly =>
      $composableBuilder(column: $table.audioOnly, builder: (column) => column);

  GeneratedColumn<bool> get autoUpdate => $composableBuilder(
    column: $table.autoUpdate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updateFrequencyHours => $composableBuilder(
    column: $table.updateFrequencyHours,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get includeThumbnails => $composableBuilder(
    column: $table.includeThumbnails,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get sponsorBlockEnabled => $composableBuilder(
    column: $table.sponsorBlockEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sponsorBlockCategories => $composableBuilder(
    column: $table.sponsorBlockCategories,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sponsorBlockCategoryActions => $composableBuilder(
    column: $table.sponsorBlockCategoryActions,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastUpdated => $composableBuilder(
    column: $table.lastUpdated,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get outputPath => $composableBuilder(
    column: $table.outputPath,
    builder: (column) => column,
  );

  Expression<T> tracksRefs<T extends Object>(
    Expression<T> Function($$TracksTableAnnotationComposer a) f,
  ) {
    final $$TracksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.playlistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableAnnotationComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaylistsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PlaylistsTable,
          Playlist,
          $$PlaylistsTableFilterComposer,
          $$PlaylistsTableOrderingComposer,
          $$PlaylistsTableAnnotationComposer,
          $$PlaylistsTableCreateCompanionBuilder,
          $$PlaylistsTableUpdateCompanionBuilder,
          (Playlist, $$PlaylistsTableReferences),
          Playlist,
          PrefetchHooks Function({bool tracksRefs})
        > {
  $$PlaylistsTableTableManager(_$AppDatabase db, $PlaylistsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$PlaylistsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$PlaylistsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$PlaylistsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> url = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<bool> audioOnly = const Value.absent(),
                Value<bool> autoUpdate = const Value.absent(),
                Value<int> updateFrequencyHours = const Value.absent(),
                Value<bool> includeThumbnails = const Value.absent(),
                Value<bool> sponsorBlockEnabled = const Value.absent(),
                Value<String> sponsorBlockCategories = const Value.absent(),
                Value<String> sponsorBlockCategoryActions =
                    const Value.absent(),
                Value<DateTime?> lastUpdated = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<String> outputPath = const Value.absent(),
              }) => PlaylistsCompanion(
                id: id,
                url: url,
                name: name,
                thumbnailUrl: thumbnailUrl,
                thumbnailPath: thumbnailPath,
                audioOnly: audioOnly,
                autoUpdate: autoUpdate,
                updateFrequencyHours: updateFrequencyHours,
                includeThumbnails: includeThumbnails,
                sponsorBlockEnabled: sponsorBlockEnabled,
                sponsorBlockCategories: sponsorBlockCategories,
                sponsorBlockCategoryActions: sponsorBlockCategoryActions,
                lastUpdated: lastUpdated,
                createdAt: createdAt,
                outputPath: outputPath,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String url,
                required String name,
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<bool> audioOnly = const Value.absent(),
                Value<bool> autoUpdate = const Value.absent(),
                Value<int> updateFrequencyHours = const Value.absent(),
                Value<bool> includeThumbnails = const Value.absent(),
                Value<bool> sponsorBlockEnabled = const Value.absent(),
                Value<String> sponsorBlockCategories = const Value.absent(),
                Value<String> sponsorBlockCategoryActions =
                    const Value.absent(),
                Value<DateTime?> lastUpdated = const Value.absent(),
                required DateTime createdAt,
                required String outputPath,
              }) => PlaylistsCompanion.insert(
                id: id,
                url: url,
                name: name,
                thumbnailUrl: thumbnailUrl,
                thumbnailPath: thumbnailPath,
                audioOnly: audioOnly,
                autoUpdate: autoUpdate,
                updateFrequencyHours: updateFrequencyHours,
                includeThumbnails: includeThumbnails,
                sponsorBlockEnabled: sponsorBlockEnabled,
                sponsorBlockCategories: sponsorBlockCategories,
                sponsorBlockCategoryActions: sponsorBlockCategoryActions,
                lastUpdated: lastUpdated,
                createdAt: createdAt,
                outputPath: outputPath,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          $$PlaylistsTableReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: ({tracksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (tracksRefs) db.tracks],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (tracksRefs)
                    await $_getPrefetchedData<Playlist, $PlaylistsTable, Track>(
                      currentTable: table,
                      referencedTable: $$PlaylistsTableReferences
                          ._tracksRefsTable(db),
                      managerFromTypedResult:
                          (p0) =>
                              $$PlaylistsTableReferences(
                                db,
                                table,
                                p0,
                              ).tracksRefs,
                      referencedItemsForCurrentItem:
                          (item, referencedItems) => referencedItems.where(
                            (e) => e.playlistId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$PlaylistsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PlaylistsTable,
      Playlist,
      $$PlaylistsTableFilterComposer,
      $$PlaylistsTableOrderingComposer,
      $$PlaylistsTableAnnotationComposer,
      $$PlaylistsTableCreateCompanionBuilder,
      $$PlaylistsTableUpdateCompanionBuilder,
      (Playlist, $$PlaylistsTableReferences),
      Playlist,
      PrefetchHooks Function({bool tracksRefs})
    >;
typedef $$TracksTableCreateCompanionBuilder =
    TracksCompanion Function({
      Value<int> id,
      required int playlistId,
      required int index,
      required String videoId,
      required String title,
      Value<String?> thumbnailUrl,
      Value<String?> thumbnailPath,
      Value<String?> filePath,
      Value<int?> durationSeconds,
      Value<String> status,
      Value<String?> unavailableReason,
      Value<bool> isLocalReplacement,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> sponsorBlockCheckedAt,
      Value<String?> lastError,
    });
typedef $$TracksTableUpdateCompanionBuilder =
    TracksCompanion Function({
      Value<int> id,
      Value<int> playlistId,
      Value<int> index,
      Value<String> videoId,
      Value<String> title,
      Value<String?> thumbnailUrl,
      Value<String?> thumbnailPath,
      Value<String?> filePath,
      Value<int?> durationSeconds,
      Value<String> status,
      Value<String?> unavailableReason,
      Value<bool> isLocalReplacement,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> sponsorBlockCheckedAt,
      Value<String?> lastError,
    });

final class $$TracksTableReferences
    extends BaseReferences<_$AppDatabase, $TracksTable, Track> {
  $$TracksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $PlaylistsTable _playlistIdTable(_$AppDatabase db) => db.playlists
      .createAlias($_aliasNameGenerator(db.tracks.playlistId, db.playlists.id));

  $$PlaylistsTableProcessedTableManager get playlistId {
    final $_column = $_itemColumn<int>('playlist_id')!;

    final manager = $$PlaylistsTableTableManager(
      $_db,
      $_db.playlists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_playlistIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<
    $SponsorBlockSegmentsTable,
    List<SponsorBlockSegment>
  >
  _sponsorBlockSegmentsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.sponsorBlockSegments,
        aliasName: $_aliasNameGenerator(
          db.tracks.id,
          db.sponsorBlockSegments.trackId,
        ),
      );

  $$SponsorBlockSegmentsTableProcessedTableManager
  get sponsorBlockSegmentsRefs {
    final manager = $$SponsorBlockSegmentsTableTableManager(
      $_db,
      $_db.sponsorBlockSegments,
    ).filter((f) => f.trackId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _sponsorBlockSegmentsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TracksTableFilterComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get index => $composableBuilder(
    column: $table.index,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoId => $composableBuilder(
    column: $table.videoId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unavailableReason => $composableBuilder(
    column: $table.unavailableReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isLocalReplacement => $composableBuilder(
    column: $table.isLocalReplacement,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get sponsorBlockCheckedAt => $composableBuilder(
    column: $table.sponsorBlockCheckedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  $$PlaylistsTableFilterComposer get playlistId {
    final $$PlaylistsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableFilterComposer(
            $db: $db,
            $table: $db.playlists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> sponsorBlockSegmentsRefs(
    Expression<bool> Function($$SponsorBlockSegmentsTableFilterComposer f) f,
  ) {
    final $$SponsorBlockSegmentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sponsorBlockSegments,
      getReferencedColumn: (t) => t.trackId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SponsorBlockSegmentsTableFilterComposer(
            $db: $db,
            $table: $db.sponsorBlockSegments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TracksTableOrderingComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get index => $composableBuilder(
    column: $table.index,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoId => $composableBuilder(
    column: $table.videoId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unavailableReason => $composableBuilder(
    column: $table.unavailableReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isLocalReplacement => $composableBuilder(
    column: $table.isLocalReplacement,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get sponsorBlockCheckedAt => $composableBuilder(
    column: $table.sponsorBlockCheckedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlaylistsTableOrderingComposer get playlistId {
    final $$PlaylistsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableOrderingComposer(
            $db: $db,
            $table: $db.playlists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TracksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TracksTable> {
  $$TracksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get index =>
      $composableBuilder(column: $table.index, builder: (column) => column);

  GeneratedColumn<String> get videoId =>
      $composableBuilder(column: $table.videoId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get thumbnailUrl => $composableBuilder(
    column: $table.thumbnailUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get unavailableReason => $composableBuilder(
    column: $table.unavailableReason,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isLocalReplacement => $composableBuilder(
    column: $table.isLocalReplacement,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get sponsorBlockCheckedAt => $composableBuilder(
    column: $table.sponsorBlockCheckedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  $$PlaylistsTableAnnotationComposer get playlistId {
    final $$PlaylistsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableAnnotationComposer(
            $db: $db,
            $table: $db.playlists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> sponsorBlockSegmentsRefs<T extends Object>(
    Expression<T> Function($$SponsorBlockSegmentsTableAnnotationComposer a) f,
  ) {
    final $$SponsorBlockSegmentsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.sponsorBlockSegments,
          getReferencedColumn: (t) => t.trackId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SponsorBlockSegmentsTableAnnotationComposer(
                $db: $db,
                $table: $db.sponsorBlockSegments,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$TracksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TracksTable,
          Track,
          $$TracksTableFilterComposer,
          $$TracksTableOrderingComposer,
          $$TracksTableAnnotationComposer,
          $$TracksTableCreateCompanionBuilder,
          $$TracksTableUpdateCompanionBuilder,
          (Track, $$TracksTableReferences),
          Track,
          PrefetchHooks Function({
            bool playlistId,
            bool sponsorBlockSegmentsRefs,
          })
        > {
  $$TracksTableTableManager(_$AppDatabase db, $TracksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$TracksTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$TracksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$TracksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> playlistId = const Value.absent(),
                Value<int> index = const Value.absent(),
                Value<String> videoId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<String?> filePath = const Value.absent(),
                Value<int?> durationSeconds = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> unavailableReason = const Value.absent(),
                Value<bool> isLocalReplacement = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => TracksCompanion(
                id: id,
                playlistId: playlistId,
                index: index,
                videoId: videoId,
                title: title,
                thumbnailUrl: thumbnailUrl,
                thumbnailPath: thumbnailPath,
                filePath: filePath,
                durationSeconds: durationSeconds,
                status: status,
                unavailableReason: unavailableReason,
                isLocalReplacement: isLocalReplacement,
                downloadedAt: downloadedAt,
                sponsorBlockCheckedAt: sponsorBlockCheckedAt,
                lastError: lastError,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int playlistId,
                required int index,
                required String videoId,
                required String title,
                Value<String?> thumbnailUrl = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<String?> filePath = const Value.absent(),
                Value<int?> durationSeconds = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> unavailableReason = const Value.absent(),
                Value<bool> isLocalReplacement = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => TracksCompanion.insert(
                id: id,
                playlistId: playlistId,
                index: index,
                videoId: videoId,
                title: title,
                thumbnailUrl: thumbnailUrl,
                thumbnailPath: thumbnailPath,
                filePath: filePath,
                durationSeconds: durationSeconds,
                status: status,
                unavailableReason: unavailableReason,
                isLocalReplacement: isLocalReplacement,
                downloadedAt: downloadedAt,
                sponsorBlockCheckedAt: sponsorBlockCheckedAt,
                lastError: lastError,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          $$TracksTableReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: ({
            playlistId = false,
            sponsorBlockSegmentsRefs = false,
          }) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (sponsorBlockSegmentsRefs) db.sponsorBlockSegments,
              ],
              addJoins: <
                T extends TableManagerState<
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic
                >
              >(state) {
                if (playlistId) {
                  state =
                      state.withJoin(
                            currentTable: table,
                            currentColumn: table.playlistId,
                            referencedTable: $$TracksTableReferences
                                ._playlistIdTable(db),
                            referencedColumn:
                                $$TracksTableReferences._playlistIdTable(db).id,
                          )
                          as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (sponsorBlockSegmentsRefs)
                    await $_getPrefetchedData<
                      Track,
                      $TracksTable,
                      SponsorBlockSegment
                    >(
                      currentTable: table,
                      referencedTable: $$TracksTableReferences
                          ._sponsorBlockSegmentsRefsTable(db),
                      managerFromTypedResult:
                          (p0) =>
                              $$TracksTableReferences(
                                db,
                                table,
                                p0,
                              ).sponsorBlockSegmentsRefs,
                      referencedItemsForCurrentItem:
                          (item, referencedItems) => referencedItems.where(
                            (e) => e.trackId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$TracksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TracksTable,
      Track,
      $$TracksTableFilterComposer,
      $$TracksTableOrderingComposer,
      $$TracksTableAnnotationComposer,
      $$TracksTableCreateCompanionBuilder,
      $$TracksTableUpdateCompanionBuilder,
      (Track, $$TracksTableReferences),
      Track,
      PrefetchHooks Function({bool playlistId, bool sponsorBlockSegmentsRefs})
    >;
typedef $$SponsorBlockSegmentsTableCreateCompanionBuilder =
    SponsorBlockSegmentsCompanion Function({
      Value<int> id,
      required int trackId,
      required String videoId,
      required String source,
      Value<String?> uuid,
      required String category,
      Value<String> actionType,
      required int startMs,
      required int endMs,
      Value<int?> votes,
      Value<bool?> locked,
      Value<String?> description,
      required DateTime createdAt,
    });
typedef $$SponsorBlockSegmentsTableUpdateCompanionBuilder =
    SponsorBlockSegmentsCompanion Function({
      Value<int> id,
      Value<int> trackId,
      Value<String> videoId,
      Value<String> source,
      Value<String?> uuid,
      Value<String> category,
      Value<String> actionType,
      Value<int> startMs,
      Value<int> endMs,
      Value<int?> votes,
      Value<bool?> locked,
      Value<String?> description,
      Value<DateTime> createdAt,
    });

final class $$SponsorBlockSegmentsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $SponsorBlockSegmentsTable,
          SponsorBlockSegment
        > {
  $$SponsorBlockSegmentsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $TracksTable _trackIdTable(_$AppDatabase db) => db.tracks.createAlias(
    $_aliasNameGenerator(db.sponsorBlockSegments.trackId, db.tracks.id),
  );

  $$TracksTableProcessedTableManager get trackId {
    final $_column = $_itemColumn<int>('track_id')!;

    final manager = $$TracksTableTableManager(
      $_db,
      $_db.tracks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_trackIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SponsorBlockSegmentsTableFilterComposer
    extends Composer<_$AppDatabase, $SponsorBlockSegmentsTable> {
  $$SponsorBlockSegmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoId => $composableBuilder(
    column: $table.videoId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uuid => $composableBuilder(
    column: $table.uuid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startMs => $composableBuilder(
    column: $table.startMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endMs => $composableBuilder(
    column: $table.endMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get votes => $composableBuilder(
    column: $table.votes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$TracksTableFilterComposer get trackId {
    final $$TracksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableFilterComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SponsorBlockSegmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $SponsorBlockSegmentsTable> {
  $$SponsorBlockSegmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoId => $composableBuilder(
    column: $table.videoId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uuid => $composableBuilder(
    column: $table.uuid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startMs => $composableBuilder(
    column: $table.startMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endMs => $composableBuilder(
    column: $table.endMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get votes => $composableBuilder(
    column: $table.votes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$TracksTableOrderingComposer get trackId {
    final $$TracksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableOrderingComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SponsorBlockSegmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SponsorBlockSegmentsTable> {
  $$SponsorBlockSegmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get videoId =>
      $composableBuilder(column: $table.videoId, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get startMs =>
      $composableBuilder(column: $table.startMs, builder: (column) => column);

  GeneratedColumn<int> get endMs =>
      $composableBuilder(column: $table.endMs, builder: (column) => column);

  GeneratedColumn<int> get votes =>
      $composableBuilder(column: $table.votes, builder: (column) => column);

  GeneratedColumn<bool> get locked =>
      $composableBuilder(column: $table.locked, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$TracksTableAnnotationComposer get trackId {
    final $$TracksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.trackId,
      referencedTable: $db.tracks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TracksTableAnnotationComposer(
            $db: $db,
            $table: $db.tracks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SponsorBlockSegmentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SponsorBlockSegmentsTable,
          SponsorBlockSegment,
          $$SponsorBlockSegmentsTableFilterComposer,
          $$SponsorBlockSegmentsTableOrderingComposer,
          $$SponsorBlockSegmentsTableAnnotationComposer,
          $$SponsorBlockSegmentsTableCreateCompanionBuilder,
          $$SponsorBlockSegmentsTableUpdateCompanionBuilder,
          (SponsorBlockSegment, $$SponsorBlockSegmentsTableReferences),
          SponsorBlockSegment,
          PrefetchHooks Function({bool trackId})
        > {
  $$SponsorBlockSegmentsTableTableManager(
    _$AppDatabase db,
    $SponsorBlockSegmentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$SponsorBlockSegmentsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer:
              () => $$SponsorBlockSegmentsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer:
              () => $$SponsorBlockSegmentsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> trackId = const Value.absent(),
                Value<String> videoId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> uuid = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<String> actionType = const Value.absent(),
                Value<int> startMs = const Value.absent(),
                Value<int> endMs = const Value.absent(),
                Value<int?> votes = const Value.absent(),
                Value<bool?> locked = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => SponsorBlockSegmentsCompanion(
                id: id,
                trackId: trackId,
                videoId: videoId,
                source: source,
                uuid: uuid,
                category: category,
                actionType: actionType,
                startMs: startMs,
                endMs: endMs,
                votes: votes,
                locked: locked,
                description: description,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int trackId,
                required String videoId,
                required String source,
                Value<String?> uuid = const Value.absent(),
                required String category,
                Value<String> actionType = const Value.absent(),
                required int startMs,
                required int endMs,
                Value<int?> votes = const Value.absent(),
                Value<bool?> locked = const Value.absent(),
                Value<String?> description = const Value.absent(),
                required DateTime createdAt,
              }) => SponsorBlockSegmentsCompanion.insert(
                id: id,
                trackId: trackId,
                videoId: videoId,
                source: source,
                uuid: uuid,
                category: category,
                actionType: actionType,
                startMs: startMs,
                endMs: endMs,
                votes: votes,
                locked: locked,
                description: description,
                createdAt: createdAt,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          $$SponsorBlockSegmentsTableReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: ({trackId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                T extends TableManagerState<
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic,
                  dynamic
                >
              >(state) {
                if (trackId) {
                  state =
                      state.withJoin(
                            currentTable: table,
                            currentColumn: table.trackId,
                            referencedTable:
                                $$SponsorBlockSegmentsTableReferences
                                    ._trackIdTable(db),
                            referencedColumn:
                                $$SponsorBlockSegmentsTableReferences
                                    ._trackIdTable(db)
                                    .id,
                          )
                          as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SponsorBlockSegmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SponsorBlockSegmentsTable,
      SponsorBlockSegment,
      $$SponsorBlockSegmentsTableFilterComposer,
      $$SponsorBlockSegmentsTableOrderingComposer,
      $$SponsorBlockSegmentsTableAnnotationComposer,
      $$SponsorBlockSegmentsTableCreateCompanionBuilder,
      $$SponsorBlockSegmentsTableUpdateCompanionBuilder,
      (SponsorBlockSegment, $$SponsorBlockSegmentsTableReferences),
      SponsorBlockSegment,
      PrefetchHooks Function({bool trackId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$PlaylistsTableTableManager get playlists =>
      $$PlaylistsTableTableManager(_db, _db.playlists);
  $$TracksTableTableManager get tracks =>
      $$TracksTableTableManager(_db, _db.tracks);
  $$SponsorBlockSegmentsTableTableManager get sponsorBlockSegments =>
      $$SponsorBlockSegmentsTableTableManager(_db, _db.sponsorBlockSegments);
}
