// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $PlaylistsTable extends Playlists
    with TableInfo<$PlaylistsTable, Playlist> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _playChaptersMeta = const VerificationMeta(
    'playChapters',
  );
  @override
  late final GeneratedColumn<bool> playChapters = GeneratedColumn<bool>(
    'play_chapters',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("play_chapters" IN (0, 1))',
    ),
  );
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
  static const VerificationMeta _lastUpdateAttemptMeta = const VerificationMeta(
    'lastUpdateAttempt',
  );
  @override
  late final GeneratedColumn<DateTime> lastUpdateAttempt =
      GeneratedColumn<DateTime>(
        'last_update_attempt',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _videoQualityMeta = const VerificationMeta(
    'videoQuality',
  );
  @override
  late final GeneratedColumn<int> videoQuality = GeneratedColumn<int>(
    'video_quality',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isTemporaryMeta = const VerificationMeta(
    'isTemporary',
  );
  @override
  late final GeneratedColumn<bool> isTemporary = GeneratedColumn<bool>(
    'is_temporary',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_temporary" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lyricsModeMeta = const VerificationMeta(
    'lyricsMode',
  );
  @override
  late final GeneratedColumn<String> lyricsMode = GeneratedColumn<String>(
    'lyrics_mode',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    playChapters,
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
    lastUpdateAttempt,
    sortOrder,
    videoQuality,
    isTemporary,
    lyricsMode,
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
    if (data.containsKey('play_chapters')) {
      context.handle(
        _playChaptersMeta,
        playChapters.isAcceptableOrUnknown(
          data['play_chapters']!,
          _playChaptersMeta,
        ),
      );
    }
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
    if (data.containsKey('last_update_attempt')) {
      context.handle(
        _lastUpdateAttemptMeta,
        lastUpdateAttempt.isAcceptableOrUnknown(
          data['last_update_attempt']!,
          _lastUpdateAttemptMeta,
        ),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('video_quality')) {
      context.handle(
        _videoQualityMeta,
        videoQuality.isAcceptableOrUnknown(
          data['video_quality']!,
          _videoQualityMeta,
        ),
      );
    }
    if (data.containsKey('is_temporary')) {
      context.handle(
        _isTemporaryMeta,
        isTemporary.isAcceptableOrUnknown(
          data['is_temporary']!,
          _isTemporaryMeta,
        ),
      );
    }
    if (data.containsKey('lyrics_mode')) {
      context.handle(
        _lyricsModeMeta,
        lyricsMode.isAcceptableOrUnknown(data['lyrics_mode']!, _lyricsModeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Playlist map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Playlist(
      playChapters: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}play_chapters'],
      ),
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
      lastUpdateAttempt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_update_attempt'],
      ),
      sortOrder:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}sort_order'],
          )!,
      videoQuality: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}video_quality'],
      ),
      isTemporary:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_temporary'],
          )!,
      lyricsMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lyrics_mode'],
      ),
    );
  }

  @override
  $PlaylistsTable createAlias(String alias) {
    return $PlaylistsTable(attachedDatabase, alias);
  }
}

class Playlist extends DataClass implements Insertable<Playlist> {
  final bool? playChapters;
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

  /// When an update (manual or scheduled) last started checking this
  /// playlist, successful or not. The scheduled worker takes the playlists
  /// it tried longest ago first, so one playlist that never finishes in
  /// time cannot keep the others from ever being updated.
  final DateTime? lastUpdateAttempt;

  /// Position on the home page: lower comes first, ties by id. Only the
  /// app's own order; it is not part of the metadata files.
  final int sortOrder;

  /// Highest video height to download (720 = up to 720p); null = the best
  /// available. Ignored for audio-only playlists.
  final int? videoQuality;

  /// The app's own "Temporary" playlist, which has no YouTube playlist
  /// behind it.
  final bool isTemporary;

  /// What text is fetched for search: 'lyrics' (songs) or 'transcript'
  /// (spoken content); null = off. See `LyricsMode`.
  final String? lyricsMode;
  const Playlist({
    this.playChapters,
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
    this.lastUpdateAttempt,
    required this.sortOrder,
    this.videoQuality,
    required this.isTemporary,
    this.lyricsMode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || playChapters != null) {
      map['play_chapters'] = Variable<bool>(playChapters);
    }
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
    if (!nullToAbsent || lastUpdateAttempt != null) {
      map['last_update_attempt'] = Variable<DateTime>(lastUpdateAttempt);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || videoQuality != null) {
      map['video_quality'] = Variable<int>(videoQuality);
    }
    map['is_temporary'] = Variable<bool>(isTemporary);
    if (!nullToAbsent || lyricsMode != null) {
      map['lyrics_mode'] = Variable<String>(lyricsMode);
    }
    return map;
  }

  PlaylistsCompanion toCompanion(bool nullToAbsent) {
    return PlaylistsCompanion(
      playChapters:
          playChapters == null && nullToAbsent
              ? const Value.absent()
              : Value(playChapters),
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
      lastUpdateAttempt:
          lastUpdateAttempt == null && nullToAbsent
              ? const Value.absent()
              : Value(lastUpdateAttempt),
      sortOrder: Value(sortOrder),
      videoQuality:
          videoQuality == null && nullToAbsent
              ? const Value.absent()
              : Value(videoQuality),
      isTemporary: Value(isTemporary),
      lyricsMode:
          lyricsMode == null && nullToAbsent
              ? const Value.absent()
              : Value(lyricsMode),
    );
  }

  factory Playlist.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Playlist(
      playChapters: serializer.fromJson<bool?>(json['playChapters']),
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
      lastUpdateAttempt: serializer.fromJson<DateTime?>(
        json['lastUpdateAttempt'],
      ),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      videoQuality: serializer.fromJson<int?>(json['videoQuality']),
      isTemporary: serializer.fromJson<bool>(json['isTemporary']),
      lyricsMode: serializer.fromJson<String?>(json['lyricsMode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'playChapters': serializer.toJson<bool?>(playChapters),
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
      'lastUpdateAttempt': serializer.toJson<DateTime?>(lastUpdateAttempt),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'videoQuality': serializer.toJson<int?>(videoQuality),
      'isTemporary': serializer.toJson<bool>(isTemporary),
      'lyricsMode': serializer.toJson<String?>(lyricsMode),
    };
  }

  Playlist copyWith({
    Value<bool?> playChapters = const Value.absent(),
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
    Value<DateTime?> lastUpdateAttempt = const Value.absent(),
    int? sortOrder,
    Value<int?> videoQuality = const Value.absent(),
    bool? isTemporary,
    Value<String?> lyricsMode = const Value.absent(),
  }) => Playlist(
    playChapters: playChapters.present ? playChapters.value : this.playChapters,
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
    lastUpdateAttempt:
        lastUpdateAttempt.present
            ? lastUpdateAttempt.value
            : this.lastUpdateAttempt,
    sortOrder: sortOrder ?? this.sortOrder,
    videoQuality: videoQuality.present ? videoQuality.value : this.videoQuality,
    isTemporary: isTemporary ?? this.isTemporary,
    lyricsMode: lyricsMode.present ? lyricsMode.value : this.lyricsMode,
  );
  Playlist copyWithCompanion(PlaylistsCompanion data) {
    return Playlist(
      playChapters:
          data.playChapters.present
              ? data.playChapters.value
              : this.playChapters,
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
      lastUpdateAttempt:
          data.lastUpdateAttempt.present
              ? data.lastUpdateAttempt.value
              : this.lastUpdateAttempt,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      videoQuality:
          data.videoQuality.present
              ? data.videoQuality.value
              : this.videoQuality,
      isTemporary:
          data.isTemporary.present ? data.isTemporary.value : this.isTemporary,
      lyricsMode:
          data.lyricsMode.present ? data.lyricsMode.value : this.lyricsMode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Playlist(')
          ..write('playChapters: $playChapters, ')
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
          ..write('outputPath: $outputPath, ')
          ..write('lastUpdateAttempt: $lastUpdateAttempt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('videoQuality: $videoQuality, ')
          ..write('isTemporary: $isTemporary, ')
          ..write('lyricsMode: $lyricsMode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    playChapters,
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
    lastUpdateAttempt,
    sortOrder,
    videoQuality,
    isTemporary,
    lyricsMode,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Playlist &&
          other.playChapters == this.playChapters &&
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
          other.outputPath == this.outputPath &&
          other.lastUpdateAttempt == this.lastUpdateAttempt &&
          other.sortOrder == this.sortOrder &&
          other.videoQuality == this.videoQuality &&
          other.isTemporary == this.isTemporary &&
          other.lyricsMode == this.lyricsMode);
}

class PlaylistsCompanion extends UpdateCompanion<Playlist> {
  final Value<bool?> playChapters;
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
  final Value<DateTime?> lastUpdateAttempt;
  final Value<int> sortOrder;
  final Value<int?> videoQuality;
  final Value<bool> isTemporary;
  final Value<String?> lyricsMode;
  const PlaylistsCompanion({
    this.playChapters = const Value.absent(),
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
    this.lastUpdateAttempt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.videoQuality = const Value.absent(),
    this.isTemporary = const Value.absent(),
    this.lyricsMode = const Value.absent(),
  });
  PlaylistsCompanion.insert({
    this.playChapters = const Value.absent(),
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
    this.lastUpdateAttempt = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.videoQuality = const Value.absent(),
    this.isTemporary = const Value.absent(),
    this.lyricsMode = const Value.absent(),
  }) : url = Value(url),
       name = Value(name),
       createdAt = Value(createdAt),
       outputPath = Value(outputPath);
  static Insertable<Playlist> custom({
    Expression<bool>? playChapters,
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
    Expression<DateTime>? lastUpdateAttempt,
    Expression<int>? sortOrder,
    Expression<int>? videoQuality,
    Expression<bool>? isTemporary,
    Expression<String>? lyricsMode,
  }) {
    return RawValuesInsertable({
      if (playChapters != null) 'play_chapters': playChapters,
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
      if (lastUpdateAttempt != null) 'last_update_attempt': lastUpdateAttempt,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (videoQuality != null) 'video_quality': videoQuality,
      if (isTemporary != null) 'is_temporary': isTemporary,
      if (lyricsMode != null) 'lyrics_mode': lyricsMode,
    });
  }

  PlaylistsCompanion copyWith({
    Value<bool?>? playChapters,
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
    Value<DateTime?>? lastUpdateAttempt,
    Value<int>? sortOrder,
    Value<int?>? videoQuality,
    Value<bool>? isTemporary,
    Value<String?>? lyricsMode,
  }) {
    return PlaylistsCompanion(
      playChapters: playChapters ?? this.playChapters,
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
      lastUpdateAttempt: lastUpdateAttempt ?? this.lastUpdateAttempt,
      sortOrder: sortOrder ?? this.sortOrder,
      videoQuality: videoQuality ?? this.videoQuality,
      isTemporary: isTemporary ?? this.isTemporary,
      lyricsMode: lyricsMode ?? this.lyricsMode,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (playChapters.present) {
      map['play_chapters'] = Variable<bool>(playChapters.value);
    }
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
    if (lastUpdateAttempt.present) {
      map['last_update_attempt'] = Variable<DateTime>(lastUpdateAttempt.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (videoQuality.present) {
      map['video_quality'] = Variable<int>(videoQuality.value);
    }
    if (isTemporary.present) {
      map['is_temporary'] = Variable<bool>(isTemporary.value);
    }
    if (lyricsMode.present) {
      map['lyrics_mode'] = Variable<String>(lyricsMode.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistsCompanion(')
          ..write('playChapters: $playChapters, ')
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
          ..write('outputPath: $outputPath, ')
          ..write('lastUpdateAttempt: $lastUpdateAttempt, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('videoQuality: $videoQuality, ')
          ..write('isTemporary: $isTemporary, ')
          ..write('lyricsMode: $lyricsMode')
          ..write(')'))
        .toString();
  }
}

class $TracksTable extends Tracks with TableInfo<$TracksTable, Track> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _chaptersJsonMeta = const VerificationMeta(
    'chaptersJson',
  );
  @override
  late final GeneratedColumn<String> chaptersJson = GeneratedColumn<String>(
    'chapters_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _chaptersEnabledMeta = const VerificationMeta(
    'chaptersEnabled',
  );
  @override
  late final GeneratedColumn<bool> chaptersEnabled = GeneratedColumn<bool>(
    'chapters_enabled',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("chapters_enabled" IN (0, 1))',
    ),
  );
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
  static const VerificationMeta _alwaysSkipMeta = const VerificationMeta(
    'alwaysSkip',
  );
  @override
  late final GeneratedColumn<bool> alwaysSkip = GeneratedColumn<bool>(
    'always_skip',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("always_skip" IN (0, 1))',
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
  static const VerificationMeta _replaceRequestedMeta = const VerificationMeta(
    'replaceRequested',
  );
  @override
  late final GeneratedColumn<bool> replaceRequested = GeneratedColumn<bool>(
    'replace_requested',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("replace_requested" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _videoQualityMeta = const VerificationMeta(
    'videoQuality',
  );
  @override
  late final GeneratedColumn<int> videoQuality = GeneratedColumn<int>(
    'video_quality',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _downloadedMaxHeightMeta =
      const VerificationMeta('downloadedMaxHeight');
  @override
  late final GeneratedColumn<int> downloadedMaxHeight = GeneratedColumn<int>(
    'downloaded_max_height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    chaptersJson,
    chaptersEnabled,
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
    alwaysSkip,
    downloadedAt,
    sponsorBlockCheckedAt,
    lastError,
    replaceRequested,
    videoQuality,
    downloadedMaxHeight,
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
    if (data.containsKey('chapters_json')) {
      context.handle(
        _chaptersJsonMeta,
        chaptersJson.isAcceptableOrUnknown(
          data['chapters_json']!,
          _chaptersJsonMeta,
        ),
      );
    }
    if (data.containsKey('chapters_enabled')) {
      context.handle(
        _chaptersEnabledMeta,
        chaptersEnabled.isAcceptableOrUnknown(
          data['chapters_enabled']!,
          _chaptersEnabledMeta,
        ),
      );
    }
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
    if (data.containsKey('always_skip')) {
      context.handle(
        _alwaysSkipMeta,
        alwaysSkip.isAcceptableOrUnknown(data['always_skip']!, _alwaysSkipMeta),
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
    if (data.containsKey('replace_requested')) {
      context.handle(
        _replaceRequestedMeta,
        replaceRequested.isAcceptableOrUnknown(
          data['replace_requested']!,
          _replaceRequestedMeta,
        ),
      );
    }
    if (data.containsKey('video_quality')) {
      context.handle(
        _videoQualityMeta,
        videoQuality.isAcceptableOrUnknown(
          data['video_quality']!,
          _videoQualityMeta,
        ),
      );
    }
    if (data.containsKey('downloaded_max_height')) {
      context.handle(
        _downloadedMaxHeightMeta,
        downloadedMaxHeight.isAcceptableOrUnknown(
          data['downloaded_max_height']!,
          _downloadedMaxHeightMeta,
        ),
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
      chaptersJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapters_json'],
      ),
      chaptersEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}chapters_enabled'],
      ),
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
      alwaysSkip:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}always_skip'],
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
      replaceRequested:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}replace_requested'],
          )!,
      videoQuality: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}video_quality'],
      ),
      downloadedMaxHeight: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_max_height'],
      ),
    );
  }

  @override
  $TracksTable createAlias(String alias) {
    return $TracksTable(attachedDatabase, alias);
  }
}

class Track extends DataClass implements Insertable<Track> {
  final String? chaptersJson;

  /// null inherits the playlist preference.
  final bool? chaptersEnabled;
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

  /// Exclude this track from automatic playback, while still allowing an
  /// explicit tap to play it.
  final bool alwaysSkip;
  final DateTime? downloadedAt;
  final DateTime? sponsorBlockCheckedAt;
  final String? lastError;

  /// The file should be replaced by a fresh download (the YouTube original
  /// of a local replacement, or the other format after a mode switch). The
  /// current file stays in use until the new one is completely on disk.
  final bool replaceRequested;

  /// Video quality for this track alone: null inherits the playlist's,
  /// 0 = the best available, N = up to N p.
  final int? videoQuality;

  /// The height cap the current file was downloaded under: 0 = no cap,
  /// null = unknown (downloaded before caps existed, or audio).
  final int? downloadedMaxHeight;
  const Track({
    this.chaptersJson,
    this.chaptersEnabled,
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
    required this.alwaysSkip,
    this.downloadedAt,
    this.sponsorBlockCheckedAt,
    this.lastError,
    required this.replaceRequested,
    this.videoQuality,
    this.downloadedMaxHeight,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (!nullToAbsent || chaptersJson != null) {
      map['chapters_json'] = Variable<String>(chaptersJson);
    }
    if (!nullToAbsent || chaptersEnabled != null) {
      map['chapters_enabled'] = Variable<bool>(chaptersEnabled);
    }
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
    map['always_skip'] = Variable<bool>(alwaysSkip);
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
    map['replace_requested'] = Variable<bool>(replaceRequested);
    if (!nullToAbsent || videoQuality != null) {
      map['video_quality'] = Variable<int>(videoQuality);
    }
    if (!nullToAbsent || downloadedMaxHeight != null) {
      map['downloaded_max_height'] = Variable<int>(downloadedMaxHeight);
    }
    return map;
  }

  TracksCompanion toCompanion(bool nullToAbsent) {
    return TracksCompanion(
      chaptersJson:
          chaptersJson == null && nullToAbsent
              ? const Value.absent()
              : Value(chaptersJson),
      chaptersEnabled:
          chaptersEnabled == null && nullToAbsent
              ? const Value.absent()
              : Value(chaptersEnabled),
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
      alwaysSkip: Value(alwaysSkip),
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
      replaceRequested: Value(replaceRequested),
      videoQuality:
          videoQuality == null && nullToAbsent
              ? const Value.absent()
              : Value(videoQuality),
      downloadedMaxHeight:
          downloadedMaxHeight == null && nullToAbsent
              ? const Value.absent()
              : Value(downloadedMaxHeight),
    );
  }

  factory Track.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Track(
      chaptersJson: serializer.fromJson<String?>(json['chaptersJson']),
      chaptersEnabled: serializer.fromJson<bool?>(json['chaptersEnabled']),
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
      alwaysSkip: serializer.fromJson<bool>(json['alwaysSkip']),
      downloadedAt: serializer.fromJson<DateTime?>(json['downloadedAt']),
      sponsorBlockCheckedAt: serializer.fromJson<DateTime?>(
        json['sponsorBlockCheckedAt'],
      ),
      lastError: serializer.fromJson<String?>(json['lastError']),
      replaceRequested: serializer.fromJson<bool>(json['replaceRequested']),
      videoQuality: serializer.fromJson<int?>(json['videoQuality']),
      downloadedMaxHeight: serializer.fromJson<int?>(
        json['downloadedMaxHeight'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'chaptersJson': serializer.toJson<String?>(chaptersJson),
      'chaptersEnabled': serializer.toJson<bool?>(chaptersEnabled),
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
      'alwaysSkip': serializer.toJson<bool>(alwaysSkip),
      'downloadedAt': serializer.toJson<DateTime?>(downloadedAt),
      'sponsorBlockCheckedAt': serializer.toJson<DateTime?>(
        sponsorBlockCheckedAt,
      ),
      'lastError': serializer.toJson<String?>(lastError),
      'replaceRequested': serializer.toJson<bool>(replaceRequested),
      'videoQuality': serializer.toJson<int?>(videoQuality),
      'downloadedMaxHeight': serializer.toJson<int?>(downloadedMaxHeight),
    };
  }

  Track copyWith({
    Value<String?> chaptersJson = const Value.absent(),
    Value<bool?> chaptersEnabled = const Value.absent(),
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
    bool? alwaysSkip,
    Value<DateTime?> downloadedAt = const Value.absent(),
    Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
    bool? replaceRequested,
    Value<int?> videoQuality = const Value.absent(),
    Value<int?> downloadedMaxHeight = const Value.absent(),
  }) => Track(
    chaptersJson: chaptersJson.present ? chaptersJson.value : this.chaptersJson,
    chaptersEnabled:
        chaptersEnabled.present ? chaptersEnabled.value : this.chaptersEnabled,
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
    alwaysSkip: alwaysSkip ?? this.alwaysSkip,
    downloadedAt: downloadedAt.present ? downloadedAt.value : this.downloadedAt,
    sponsorBlockCheckedAt:
        sponsorBlockCheckedAt.present
            ? sponsorBlockCheckedAt.value
            : this.sponsorBlockCheckedAt,
    lastError: lastError.present ? lastError.value : this.lastError,
    replaceRequested: replaceRequested ?? this.replaceRequested,
    videoQuality: videoQuality.present ? videoQuality.value : this.videoQuality,
    downloadedMaxHeight:
        downloadedMaxHeight.present
            ? downloadedMaxHeight.value
            : this.downloadedMaxHeight,
  );
  Track copyWithCompanion(TracksCompanion data) {
    return Track(
      chaptersJson:
          data.chaptersJson.present
              ? data.chaptersJson.value
              : this.chaptersJson,
      chaptersEnabled:
          data.chaptersEnabled.present
              ? data.chaptersEnabled.value
              : this.chaptersEnabled,
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
      alwaysSkip:
          data.alwaysSkip.present ? data.alwaysSkip.value : this.alwaysSkip,
      downloadedAt:
          data.downloadedAt.present
              ? data.downloadedAt.value
              : this.downloadedAt,
      sponsorBlockCheckedAt:
          data.sponsorBlockCheckedAt.present
              ? data.sponsorBlockCheckedAt.value
              : this.sponsorBlockCheckedAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      replaceRequested:
          data.replaceRequested.present
              ? data.replaceRequested.value
              : this.replaceRequested,
      videoQuality:
          data.videoQuality.present
              ? data.videoQuality.value
              : this.videoQuality,
      downloadedMaxHeight:
          data.downloadedMaxHeight.present
              ? data.downloadedMaxHeight.value
              : this.downloadedMaxHeight,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Track(')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('chaptersEnabled: $chaptersEnabled, ')
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
          ..write('alwaysSkip: $alwaysSkip, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('sponsorBlockCheckedAt: $sponsorBlockCheckedAt, ')
          ..write('lastError: $lastError, ')
          ..write('replaceRequested: $replaceRequested, ')
          ..write('videoQuality: $videoQuality, ')
          ..write('downloadedMaxHeight: $downloadedMaxHeight')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    chaptersJson,
    chaptersEnabled,
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
    alwaysSkip,
    downloadedAt,
    sponsorBlockCheckedAt,
    lastError,
    replaceRequested,
    videoQuality,
    downloadedMaxHeight,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Track &&
          other.chaptersJson == this.chaptersJson &&
          other.chaptersEnabled == this.chaptersEnabled &&
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
          other.alwaysSkip == this.alwaysSkip &&
          other.downloadedAt == this.downloadedAt &&
          other.sponsorBlockCheckedAt == this.sponsorBlockCheckedAt &&
          other.lastError == this.lastError &&
          other.replaceRequested == this.replaceRequested &&
          other.videoQuality == this.videoQuality &&
          other.downloadedMaxHeight == this.downloadedMaxHeight);
}

class TracksCompanion extends UpdateCompanion<Track> {
  final Value<String?> chaptersJson;
  final Value<bool?> chaptersEnabled;
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
  final Value<bool> alwaysSkip;
  final Value<DateTime?> downloadedAt;
  final Value<DateTime?> sponsorBlockCheckedAt;
  final Value<String?> lastError;
  final Value<bool> replaceRequested;
  final Value<int?> videoQuality;
  final Value<int?> downloadedMaxHeight;
  const TracksCompanion({
    this.chaptersJson = const Value.absent(),
    this.chaptersEnabled = const Value.absent(),
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
    this.alwaysSkip = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.sponsorBlockCheckedAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.replaceRequested = const Value.absent(),
    this.videoQuality = const Value.absent(),
    this.downloadedMaxHeight = const Value.absent(),
  });
  TracksCompanion.insert({
    this.chaptersJson = const Value.absent(),
    this.chaptersEnabled = const Value.absent(),
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
    this.alwaysSkip = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.sponsorBlockCheckedAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.replaceRequested = const Value.absent(),
    this.videoQuality = const Value.absent(),
    this.downloadedMaxHeight = const Value.absent(),
  }) : playlistId = Value(playlistId),
       index = Value(index),
       videoId = Value(videoId),
       title = Value(title);
  static Insertable<Track> custom({
    Expression<String>? chaptersJson,
    Expression<bool>? chaptersEnabled,
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
    Expression<bool>? alwaysSkip,
    Expression<DateTime>? downloadedAt,
    Expression<DateTime>? sponsorBlockCheckedAt,
    Expression<String>? lastError,
    Expression<bool>? replaceRequested,
    Expression<int>? videoQuality,
    Expression<int>? downloadedMaxHeight,
  }) {
    return RawValuesInsertable({
      if (chaptersJson != null) 'chapters_json': chaptersJson,
      if (chaptersEnabled != null) 'chapters_enabled': chaptersEnabled,
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
      if (alwaysSkip != null) 'always_skip': alwaysSkip,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (sponsorBlockCheckedAt != null)
        'sponsor_block_checked_at': sponsorBlockCheckedAt,
      if (lastError != null) 'last_error': lastError,
      if (replaceRequested != null) 'replace_requested': replaceRequested,
      if (videoQuality != null) 'video_quality': videoQuality,
      if (downloadedMaxHeight != null)
        'downloaded_max_height': downloadedMaxHeight,
    });
  }

  TracksCompanion copyWith({
    Value<String?>? chaptersJson,
    Value<bool?>? chaptersEnabled,
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
    Value<bool>? alwaysSkip,
    Value<DateTime?>? downloadedAt,
    Value<DateTime?>? sponsorBlockCheckedAt,
    Value<String?>? lastError,
    Value<bool>? replaceRequested,
    Value<int?>? videoQuality,
    Value<int?>? downloadedMaxHeight,
  }) {
    return TracksCompanion(
      chaptersJson: chaptersJson ?? this.chaptersJson,
      chaptersEnabled: chaptersEnabled ?? this.chaptersEnabled,
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
      alwaysSkip: alwaysSkip ?? this.alwaysSkip,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      sponsorBlockCheckedAt:
          sponsorBlockCheckedAt ?? this.sponsorBlockCheckedAt,
      lastError: lastError ?? this.lastError,
      replaceRequested: replaceRequested ?? this.replaceRequested,
      videoQuality: videoQuality ?? this.videoQuality,
      downloadedMaxHeight: downloadedMaxHeight ?? this.downloadedMaxHeight,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (chaptersJson.present) {
      map['chapters_json'] = Variable<String>(chaptersJson.value);
    }
    if (chaptersEnabled.present) {
      map['chapters_enabled'] = Variable<bool>(chaptersEnabled.value);
    }
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
    if (alwaysSkip.present) {
      map['always_skip'] = Variable<bool>(alwaysSkip.value);
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
    if (replaceRequested.present) {
      map['replace_requested'] = Variable<bool>(replaceRequested.value);
    }
    if (videoQuality.present) {
      map['video_quality'] = Variable<int>(videoQuality.value);
    }
    if (downloadedMaxHeight.present) {
      map['downloaded_max_height'] = Variable<int>(downloadedMaxHeight.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TracksCompanion(')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('chaptersEnabled: $chaptersEnabled, ')
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
          ..write('alwaysSkip: $alwaysSkip, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('sponsorBlockCheckedAt: $sponsorBlockCheckedAt, ')
          ..write('lastError: $lastError, ')
          ..write('replaceRequested: $replaceRequested, ')
          ..write('videoQuality: $videoQuality, ')
          ..write('downloadedMaxHeight: $downloadedMaxHeight')
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

class $LyricsDocsTable extends LyricsDocs
    with TableInfo<$LyricsDocsTable, LyricsDoc> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LyricsDocsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _chapterIdMeta = const VerificationMeta(
    'chapterId',
  );
  @override
  late final GeneratedColumn<String> chapterId = GeneratedColumn<String>(
    'chapter_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _offsetMsMeta = const VerificationMeta(
    'offsetMs',
  );
  @override
  late final GeneratedColumn<int> offsetMs = GeneratedColumn<int>(
    'offset_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
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
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _matchedArtistMeta = const VerificationMeta(
    'matchedArtist',
  );
  @override
  late final GeneratedColumn<String> matchedArtist = GeneratedColumn<String>(
    'matched_artist',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _matchedTitleMeta = const VerificationMeta(
    'matchedTitle',
  );
  @override
  late final GeneratedColumn<String> matchedTitle = GeneratedColumn<String>(
    'matched_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _timeScaleMeta = const VerificationMeta(
    'timeScale',
  );
  @override
  late final GeneratedColumn<double> timeScale = GeneratedColumn<double>(
    'time_scale',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(1.0),
  );
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
    'synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _shiftMsMeta = const VerificationMeta(
    'shiftMs',
  );
  @override
  late final GeneratedColumn<int> shiftMs = GeneratedColumn<int>(
    'shift_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _timingOffMeta = const VerificationMeta(
    'timingOff',
  );
  @override
  late final GeneratedColumn<bool> timingOff = GeneratedColumn<bool>(
    'timing_off',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("timing_off" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _langMeta = const VerificationMeta('lang');
  @override
  late final GeneratedColumn<String> lang = GeneratedColumn<String>(
    'lang',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _checkedAtMeta = const VerificationMeta(
    'checkedAt',
  );
  @override
  late final GeneratedColumn<DateTime> checkedAt = GeneratedColumn<DateTime>(
    'checked_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    trackId,
    chapterId,
    offsetMs,
    kind,
    status,
    source,
    sourceRef,
    matchedArtist,
    matchedTitle,
    timeScale,
    synced,
    pinned,
    shiftMs,
    timingOff,
    lang,
    checkedAt,
    attempts,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lyrics_docs';
  @override
  VerificationContext validateIntegrity(
    Insertable<LyricsDoc> instance, {
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
    if (data.containsKey('chapter_id')) {
      context.handle(
        _chapterIdMeta,
        chapterId.isAcceptableOrUnknown(data['chapter_id']!, _chapterIdMeta),
      );
    }
    if (data.containsKey('offset_ms')) {
      context.handle(
        _offsetMsMeta,
        offsetMs.isAcceptableOrUnknown(data['offset_ms']!, _offsetMsMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('matched_artist')) {
      context.handle(
        _matchedArtistMeta,
        matchedArtist.isAcceptableOrUnknown(
          data['matched_artist']!,
          _matchedArtistMeta,
        ),
      );
    }
    if (data.containsKey('matched_title')) {
      context.handle(
        _matchedTitleMeta,
        matchedTitle.isAcceptableOrUnknown(
          data['matched_title']!,
          _matchedTitleMeta,
        ),
      );
    }
    if (data.containsKey('time_scale')) {
      context.handle(
        _timeScaleMeta,
        timeScale.isAcceptableOrUnknown(data['time_scale']!, _timeScaleMeta),
      );
    }
    if (data.containsKey('synced')) {
      context.handle(
        _syncedMeta,
        synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    if (data.containsKey('shift_ms')) {
      context.handle(
        _shiftMsMeta,
        shiftMs.isAcceptableOrUnknown(data['shift_ms']!, _shiftMsMeta),
      );
    }
    if (data.containsKey('timing_off')) {
      context.handle(
        _timingOffMeta,
        timingOff.isAcceptableOrUnknown(data['timing_off']!, _timingOffMeta),
      );
    }
    if (data.containsKey('lang')) {
      context.handle(
        _langMeta,
        lang.isAcceptableOrUnknown(data['lang']!, _langMeta),
      );
    }
    if (data.containsKey('checked_at')) {
      context.handle(
        _checkedAtMeta,
        checkedAt.isAcceptableOrUnknown(data['checked_at']!, _checkedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_checkedAtMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LyricsDoc map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LyricsDoc(
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
      chapterId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_id'],
      ),
      offsetMs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}offset_ms'],
          )!,
      kind:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}kind'],
          )!,
      status:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}status'],
          )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      ),
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      matchedArtist: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}matched_artist'],
      ),
      matchedTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}matched_title'],
      ),
      timeScale:
          attachedDatabase.typeMapping.read(
            DriftSqlType.double,
            data['${effectivePrefix}time_scale'],
          )!,
      synced:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}synced'],
          )!,
      pinned:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}pinned'],
          )!,
      shiftMs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}shift_ms'],
          )!,
      timingOff:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}timing_off'],
          )!,
      lang: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lang'],
      ),
      checkedAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}checked_at'],
          )!,
      attempts:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}attempts'],
          )!,
    );
  }

  @override
  $LyricsDocsTable createAlias(String alias) {
    return $LyricsDocsTable(attachedDatabase, alias);
  }
}

class LyricsDoc extends DataClass implements Insertable<LyricsDoc> {
  final int id;
  final int trackId;

  /// `MediaChapter.id`; null = the whole file.
  final String? chapterId;

  /// Chapter start; line times are relative to it.
  final int offsetMs;

  /// 'lyrics' | 'transcript'
  final String kind;

  /// 'found' | 'none' | 'instrumental' | 'error'
  final String status;

  /// 'lrclib' | 'ytmusic' | 'yt_subs' | 'yt_auto'
  final String? source;

  /// LRCLIB id, ytmusic browseId, caption language key, or a video id.
  final String? sourceRef;
  final String? matchedArtist;
  final String? matchedTitle;

  /// Nightcore: local duration / original duration. Line times are already
  /// scaled by it.
  final double timeScale;
  final bool synced;

  /// The user chose this; automatic runs never replace it.
  final bool pinned;

  /// The user's timing correction. Already added to the lines' `startMs`;
  /// kept so a restore from `sourceRef` adds it again. Schema 17.
  final int shiftMs;

  /// The user chose the lines without times. Schema 17.
  final bool timingOff;
  final String? lang;
  final DateTime checkedAt;
  final int attempts;
  const LyricsDoc({
    required this.id,
    required this.trackId,
    this.chapterId,
    required this.offsetMs,
    required this.kind,
    required this.status,
    this.source,
    this.sourceRef,
    this.matchedArtist,
    this.matchedTitle,
    required this.timeScale,
    required this.synced,
    required this.pinned,
    required this.shiftMs,
    required this.timingOff,
    this.lang,
    required this.checkedAt,
    required this.attempts,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['track_id'] = Variable<int>(trackId);
    if (!nullToAbsent || chapterId != null) {
      map['chapter_id'] = Variable<String>(chapterId);
    }
    map['offset_ms'] = Variable<int>(offsetMs);
    map['kind'] = Variable<String>(kind);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    if (!nullToAbsent || matchedArtist != null) {
      map['matched_artist'] = Variable<String>(matchedArtist);
    }
    if (!nullToAbsent || matchedTitle != null) {
      map['matched_title'] = Variable<String>(matchedTitle);
    }
    map['time_scale'] = Variable<double>(timeScale);
    map['synced'] = Variable<bool>(synced);
    map['pinned'] = Variable<bool>(pinned);
    map['shift_ms'] = Variable<int>(shiftMs);
    map['timing_off'] = Variable<bool>(timingOff);
    if (!nullToAbsent || lang != null) {
      map['lang'] = Variable<String>(lang);
    }
    map['checked_at'] = Variable<DateTime>(checkedAt);
    map['attempts'] = Variable<int>(attempts);
    return map;
  }

  LyricsDocsCompanion toCompanion(bool nullToAbsent) {
    return LyricsDocsCompanion(
      id: Value(id),
      trackId: Value(trackId),
      chapterId:
          chapterId == null && nullToAbsent
              ? const Value.absent()
              : Value(chapterId),
      offsetMs: Value(offsetMs),
      kind: Value(kind),
      status: Value(status),
      source:
          source == null && nullToAbsent ? const Value.absent() : Value(source),
      sourceRef:
          sourceRef == null && nullToAbsent
              ? const Value.absent()
              : Value(sourceRef),
      matchedArtist:
          matchedArtist == null && nullToAbsent
              ? const Value.absent()
              : Value(matchedArtist),
      matchedTitle:
          matchedTitle == null && nullToAbsent
              ? const Value.absent()
              : Value(matchedTitle),
      timeScale: Value(timeScale),
      synced: Value(synced),
      pinned: Value(pinned),
      shiftMs: Value(shiftMs),
      timingOff: Value(timingOff),
      lang: lang == null && nullToAbsent ? const Value.absent() : Value(lang),
      checkedAt: Value(checkedAt),
      attempts: Value(attempts),
    );
  }

  factory LyricsDoc.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LyricsDoc(
      id: serializer.fromJson<int>(json['id']),
      trackId: serializer.fromJson<int>(json['trackId']),
      chapterId: serializer.fromJson<String?>(json['chapterId']),
      offsetMs: serializer.fromJson<int>(json['offsetMs']),
      kind: serializer.fromJson<String>(json['kind']),
      status: serializer.fromJson<String>(json['status']),
      source: serializer.fromJson<String?>(json['source']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      matchedArtist: serializer.fromJson<String?>(json['matchedArtist']),
      matchedTitle: serializer.fromJson<String?>(json['matchedTitle']),
      timeScale: serializer.fromJson<double>(json['timeScale']),
      synced: serializer.fromJson<bool>(json['synced']),
      pinned: serializer.fromJson<bool>(json['pinned']),
      shiftMs: serializer.fromJson<int>(json['shiftMs']),
      timingOff: serializer.fromJson<bool>(json['timingOff']),
      lang: serializer.fromJson<String?>(json['lang']),
      checkedAt: serializer.fromJson<DateTime>(json['checkedAt']),
      attempts: serializer.fromJson<int>(json['attempts']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'trackId': serializer.toJson<int>(trackId),
      'chapterId': serializer.toJson<String?>(chapterId),
      'offsetMs': serializer.toJson<int>(offsetMs),
      'kind': serializer.toJson<String>(kind),
      'status': serializer.toJson<String>(status),
      'source': serializer.toJson<String?>(source),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'matchedArtist': serializer.toJson<String?>(matchedArtist),
      'matchedTitle': serializer.toJson<String?>(matchedTitle),
      'timeScale': serializer.toJson<double>(timeScale),
      'synced': serializer.toJson<bool>(synced),
      'pinned': serializer.toJson<bool>(pinned),
      'shiftMs': serializer.toJson<int>(shiftMs),
      'timingOff': serializer.toJson<bool>(timingOff),
      'lang': serializer.toJson<String?>(lang),
      'checkedAt': serializer.toJson<DateTime>(checkedAt),
      'attempts': serializer.toJson<int>(attempts),
    };
  }

  LyricsDoc copyWith({
    int? id,
    int? trackId,
    Value<String?> chapterId = const Value.absent(),
    int? offsetMs,
    String? kind,
    String? status,
    Value<String?> source = const Value.absent(),
    Value<String?> sourceRef = const Value.absent(),
    Value<String?> matchedArtist = const Value.absent(),
    Value<String?> matchedTitle = const Value.absent(),
    double? timeScale,
    bool? synced,
    bool? pinned,
    int? shiftMs,
    bool? timingOff,
    Value<String?> lang = const Value.absent(),
    DateTime? checkedAt,
    int? attempts,
  }) => LyricsDoc(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    chapterId: chapterId.present ? chapterId.value : this.chapterId,
    offsetMs: offsetMs ?? this.offsetMs,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    source: source.present ? source.value : this.source,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    matchedArtist:
        matchedArtist.present ? matchedArtist.value : this.matchedArtist,
    matchedTitle: matchedTitle.present ? matchedTitle.value : this.matchedTitle,
    timeScale: timeScale ?? this.timeScale,
    synced: synced ?? this.synced,
    pinned: pinned ?? this.pinned,
    shiftMs: shiftMs ?? this.shiftMs,
    timingOff: timingOff ?? this.timingOff,
    lang: lang.present ? lang.value : this.lang,
    checkedAt: checkedAt ?? this.checkedAt,
    attempts: attempts ?? this.attempts,
  );
  LyricsDoc copyWithCompanion(LyricsDocsCompanion data) {
    return LyricsDoc(
      id: data.id.present ? data.id.value : this.id,
      trackId: data.trackId.present ? data.trackId.value : this.trackId,
      chapterId: data.chapterId.present ? data.chapterId.value : this.chapterId,
      offsetMs: data.offsetMs.present ? data.offsetMs.value : this.offsetMs,
      kind: data.kind.present ? data.kind.value : this.kind,
      status: data.status.present ? data.status.value : this.status,
      source: data.source.present ? data.source.value : this.source,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      matchedArtist:
          data.matchedArtist.present
              ? data.matchedArtist.value
              : this.matchedArtist,
      matchedTitle:
          data.matchedTitle.present
              ? data.matchedTitle.value
              : this.matchedTitle,
      timeScale: data.timeScale.present ? data.timeScale.value : this.timeScale,
      synced: data.synced.present ? data.synced.value : this.synced,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      shiftMs: data.shiftMs.present ? data.shiftMs.value : this.shiftMs,
      timingOff: data.timingOff.present ? data.timingOff.value : this.timingOff,
      lang: data.lang.present ? data.lang.value : this.lang,
      checkedAt: data.checkedAt.present ? data.checkedAt.value : this.checkedAt,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LyricsDoc(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('chapterId: $chapterId, ')
          ..write('offsetMs: $offsetMs, ')
          ..write('kind: $kind, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('matchedArtist: $matchedArtist, ')
          ..write('matchedTitle: $matchedTitle, ')
          ..write('timeScale: $timeScale, ')
          ..write('synced: $synced, ')
          ..write('pinned: $pinned, ')
          ..write('shiftMs: $shiftMs, ')
          ..write('timingOff: $timingOff, ')
          ..write('lang: $lang, ')
          ..write('checkedAt: $checkedAt, ')
          ..write('attempts: $attempts')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    trackId,
    chapterId,
    offsetMs,
    kind,
    status,
    source,
    sourceRef,
    matchedArtist,
    matchedTitle,
    timeScale,
    synced,
    pinned,
    shiftMs,
    timingOff,
    lang,
    checkedAt,
    attempts,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LyricsDoc &&
          other.id == this.id &&
          other.trackId == this.trackId &&
          other.chapterId == this.chapterId &&
          other.offsetMs == this.offsetMs &&
          other.kind == this.kind &&
          other.status == this.status &&
          other.source == this.source &&
          other.sourceRef == this.sourceRef &&
          other.matchedArtist == this.matchedArtist &&
          other.matchedTitle == this.matchedTitle &&
          other.timeScale == this.timeScale &&
          other.synced == this.synced &&
          other.pinned == this.pinned &&
          other.shiftMs == this.shiftMs &&
          other.timingOff == this.timingOff &&
          other.lang == this.lang &&
          other.checkedAt == this.checkedAt &&
          other.attempts == this.attempts);
}

class LyricsDocsCompanion extends UpdateCompanion<LyricsDoc> {
  final Value<int> id;
  final Value<int> trackId;
  final Value<String?> chapterId;
  final Value<int> offsetMs;
  final Value<String> kind;
  final Value<String> status;
  final Value<String?> source;
  final Value<String?> sourceRef;
  final Value<String?> matchedArtist;
  final Value<String?> matchedTitle;
  final Value<double> timeScale;
  final Value<bool> synced;
  final Value<bool> pinned;
  final Value<int> shiftMs;
  final Value<bool> timingOff;
  final Value<String?> lang;
  final Value<DateTime> checkedAt;
  final Value<int> attempts;
  const LyricsDocsCompanion({
    this.id = const Value.absent(),
    this.trackId = const Value.absent(),
    this.chapterId = const Value.absent(),
    this.offsetMs = const Value.absent(),
    this.kind = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.matchedArtist = const Value.absent(),
    this.matchedTitle = const Value.absent(),
    this.timeScale = const Value.absent(),
    this.synced = const Value.absent(),
    this.pinned = const Value.absent(),
    this.shiftMs = const Value.absent(),
    this.timingOff = const Value.absent(),
    this.lang = const Value.absent(),
    this.checkedAt = const Value.absent(),
    this.attempts = const Value.absent(),
  });
  LyricsDocsCompanion.insert({
    this.id = const Value.absent(),
    required int trackId,
    this.chapterId = const Value.absent(),
    this.offsetMs = const Value.absent(),
    required String kind,
    required String status,
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.matchedArtist = const Value.absent(),
    this.matchedTitle = const Value.absent(),
    this.timeScale = const Value.absent(),
    this.synced = const Value.absent(),
    this.pinned = const Value.absent(),
    this.shiftMs = const Value.absent(),
    this.timingOff = const Value.absent(),
    this.lang = const Value.absent(),
    required DateTime checkedAt,
    this.attempts = const Value.absent(),
  }) : trackId = Value(trackId),
       kind = Value(kind),
       status = Value(status),
       checkedAt = Value(checkedAt);
  static Insertable<LyricsDoc> custom({
    Expression<int>? id,
    Expression<int>? trackId,
    Expression<String>? chapterId,
    Expression<int>? offsetMs,
    Expression<String>? kind,
    Expression<String>? status,
    Expression<String>? source,
    Expression<String>? sourceRef,
    Expression<String>? matchedArtist,
    Expression<String>? matchedTitle,
    Expression<double>? timeScale,
    Expression<bool>? synced,
    Expression<bool>? pinned,
    Expression<int>? shiftMs,
    Expression<bool>? timingOff,
    Expression<String>? lang,
    Expression<DateTime>? checkedAt,
    Expression<int>? attempts,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (trackId != null) 'track_id': trackId,
      if (chapterId != null) 'chapter_id': chapterId,
      if (offsetMs != null) 'offset_ms': offsetMs,
      if (kind != null) 'kind': kind,
      if (status != null) 'status': status,
      if (source != null) 'source': source,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (matchedArtist != null) 'matched_artist': matchedArtist,
      if (matchedTitle != null) 'matched_title': matchedTitle,
      if (timeScale != null) 'time_scale': timeScale,
      if (synced != null) 'synced': synced,
      if (pinned != null) 'pinned': pinned,
      if (shiftMs != null) 'shift_ms': shiftMs,
      if (timingOff != null) 'timing_off': timingOff,
      if (lang != null) 'lang': lang,
      if (checkedAt != null) 'checked_at': checkedAt,
      if (attempts != null) 'attempts': attempts,
    });
  }

  LyricsDocsCompanion copyWith({
    Value<int>? id,
    Value<int>? trackId,
    Value<String?>? chapterId,
    Value<int>? offsetMs,
    Value<String>? kind,
    Value<String>? status,
    Value<String?>? source,
    Value<String?>? sourceRef,
    Value<String?>? matchedArtist,
    Value<String?>? matchedTitle,
    Value<double>? timeScale,
    Value<bool>? synced,
    Value<bool>? pinned,
    Value<int>? shiftMs,
    Value<bool>? timingOff,
    Value<String?>? lang,
    Value<DateTime>? checkedAt,
    Value<int>? attempts,
  }) {
    return LyricsDocsCompanion(
      id: id ?? this.id,
      trackId: trackId ?? this.trackId,
      chapterId: chapterId ?? this.chapterId,
      offsetMs: offsetMs ?? this.offsetMs,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      source: source ?? this.source,
      sourceRef: sourceRef ?? this.sourceRef,
      matchedArtist: matchedArtist ?? this.matchedArtist,
      matchedTitle: matchedTitle ?? this.matchedTitle,
      timeScale: timeScale ?? this.timeScale,
      synced: synced ?? this.synced,
      pinned: pinned ?? this.pinned,
      shiftMs: shiftMs ?? this.shiftMs,
      timingOff: timingOff ?? this.timingOff,
      lang: lang ?? this.lang,
      checkedAt: checkedAt ?? this.checkedAt,
      attempts: attempts ?? this.attempts,
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
    if (chapterId.present) {
      map['chapter_id'] = Variable<String>(chapterId.value);
    }
    if (offsetMs.present) {
      map['offset_ms'] = Variable<int>(offsetMs.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (matchedArtist.present) {
      map['matched_artist'] = Variable<String>(matchedArtist.value);
    }
    if (matchedTitle.present) {
      map['matched_title'] = Variable<String>(matchedTitle.value);
    }
    if (timeScale.present) {
      map['time_scale'] = Variable<double>(timeScale.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (shiftMs.present) {
      map['shift_ms'] = Variable<int>(shiftMs.value);
    }
    if (timingOff.present) {
      map['timing_off'] = Variable<bool>(timingOff.value);
    }
    if (lang.present) {
      map['lang'] = Variable<String>(lang.value);
    }
    if (checkedAt.present) {
      map['checked_at'] = Variable<DateTime>(checkedAt.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LyricsDocsCompanion(')
          ..write('id: $id, ')
          ..write('trackId: $trackId, ')
          ..write('chapterId: $chapterId, ')
          ..write('offsetMs: $offsetMs, ')
          ..write('kind: $kind, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('matchedArtist: $matchedArtist, ')
          ..write('matchedTitle: $matchedTitle, ')
          ..write('timeScale: $timeScale, ')
          ..write('synced: $synced, ')
          ..write('pinned: $pinned, ')
          ..write('shiftMs: $shiftMs, ')
          ..write('timingOff: $timingOff, ')
          ..write('lang: $lang, ')
          ..write('checkedAt: $checkedAt, ')
          ..write('attempts: $attempts')
          ..write(')'))
        .toString();
  }
}

class $LyricsLinesTable extends LyricsLines
    with TableInfo<$LyricsLinesTable, LyricsLine> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LyricsLinesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _docIdMeta = const VerificationMeta('docId');
  @override
  late final GeneratedColumn<int> docId = GeneratedColumn<int>(
    'doc_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES lyrics_docs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _lineNoMeta = const VerificationMeta('lineNo');
  @override
  late final GeneratedColumn<int> lineNo = GeneratedColumn<int>(
    'line_no',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startMsMeta = const VerificationMeta(
    'startMs',
  );
  @override
  late final GeneratedColumn<int> startMs = GeneratedColumn<int>(
    'start_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lineTextMeta = const VerificationMeta(
    'lineText',
  );
  @override
  late final GeneratedColumn<String> lineText = GeneratedColumn<String>(
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _searchTextMeta = const VerificationMeta(
    'searchText',
  );
  @override
  late final GeneratedColumn<String> searchText = GeneratedColumn<String>(
    'search_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    docId,
    lineNo,
    startMs,
    lineText,
    searchText,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lyrics_lines';
  @override
  VerificationContext validateIntegrity(
    Insertable<LyricsLine> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('doc_id')) {
      context.handle(
        _docIdMeta,
        docId.isAcceptableOrUnknown(data['doc_id']!, _docIdMeta),
      );
    } else if (isInserting) {
      context.missing(_docIdMeta);
    }
    if (data.containsKey('line_no')) {
      context.handle(
        _lineNoMeta,
        lineNo.isAcceptableOrUnknown(data['line_no']!, _lineNoMeta),
      );
    } else if (isInserting) {
      context.missing(_lineNoMeta);
    }
    if (data.containsKey('start_ms')) {
      context.handle(
        _startMsMeta,
        startMs.isAcceptableOrUnknown(data['start_ms']!, _startMsMeta),
      );
    }
    if (data.containsKey('text')) {
      context.handle(
        _lineTextMeta,
        lineText.isAcceptableOrUnknown(data['text']!, _lineTextMeta),
      );
    } else if (isInserting) {
      context.missing(_lineTextMeta);
    }
    if (data.containsKey('search_text')) {
      context.handle(
        _searchTextMeta,
        searchText.isAcceptableOrUnknown(data['search_text']!, _searchTextMeta),
      );
    } else if (isInserting) {
      context.missing(_searchTextMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LyricsLine map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LyricsLine(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}id'],
          )!,
      docId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}doc_id'],
          )!,
      lineNo:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}line_no'],
          )!,
      startMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_ms'],
      ),
      lineText:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}text'],
          )!,
      searchText:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}search_text'],
          )!,
    );
  }

  @override
  $LyricsLinesTable createAlias(String alias) {
    return $LyricsLinesTable(attachedDatabase, alias);
  }
}

class LyricsLine extends DataClass implements Insertable<LyricsLine> {
  final int id;
  final int docId;
  final int lineNo;

  /// Already scaled by the doc's time scale; relative to the doc (add
  /// `offsetMs` for file time). Null for plain text.
  final int? startMs;

  /// Raw, for display. (`text` in SQL; a Drift getter can't be named so.)
  final String lineText;

  /// Folded line i + ' ' + folded line i+1 (see `buildSearchWindow`).
  final String searchText;
  const LyricsLine({
    required this.id,
    required this.docId,
    required this.lineNo,
    this.startMs,
    required this.lineText,
    required this.searchText,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['doc_id'] = Variable<int>(docId);
    map['line_no'] = Variable<int>(lineNo);
    if (!nullToAbsent || startMs != null) {
      map['start_ms'] = Variable<int>(startMs);
    }
    map['text'] = Variable<String>(lineText);
    map['search_text'] = Variable<String>(searchText);
    return map;
  }

  LyricsLinesCompanion toCompanion(bool nullToAbsent) {
    return LyricsLinesCompanion(
      id: Value(id),
      docId: Value(docId),
      lineNo: Value(lineNo),
      startMs:
          startMs == null && nullToAbsent
              ? const Value.absent()
              : Value(startMs),
      lineText: Value(lineText),
      searchText: Value(searchText),
    );
  }

  factory LyricsLine.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LyricsLine(
      id: serializer.fromJson<int>(json['id']),
      docId: serializer.fromJson<int>(json['docId']),
      lineNo: serializer.fromJson<int>(json['lineNo']),
      startMs: serializer.fromJson<int?>(json['startMs']),
      lineText: serializer.fromJson<String>(json['lineText']),
      searchText: serializer.fromJson<String>(json['searchText']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'docId': serializer.toJson<int>(docId),
      'lineNo': serializer.toJson<int>(lineNo),
      'startMs': serializer.toJson<int?>(startMs),
      'lineText': serializer.toJson<String>(lineText),
      'searchText': serializer.toJson<String>(searchText),
    };
  }

  LyricsLine copyWith({
    int? id,
    int? docId,
    int? lineNo,
    Value<int?> startMs = const Value.absent(),
    String? lineText,
    String? searchText,
  }) => LyricsLine(
    id: id ?? this.id,
    docId: docId ?? this.docId,
    lineNo: lineNo ?? this.lineNo,
    startMs: startMs.present ? startMs.value : this.startMs,
    lineText: lineText ?? this.lineText,
    searchText: searchText ?? this.searchText,
  );
  LyricsLine copyWithCompanion(LyricsLinesCompanion data) {
    return LyricsLine(
      id: data.id.present ? data.id.value : this.id,
      docId: data.docId.present ? data.docId.value : this.docId,
      lineNo: data.lineNo.present ? data.lineNo.value : this.lineNo,
      startMs: data.startMs.present ? data.startMs.value : this.startMs,
      lineText: data.lineText.present ? data.lineText.value : this.lineText,
      searchText:
          data.searchText.present ? data.searchText.value : this.searchText,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LyricsLine(')
          ..write('id: $id, ')
          ..write('docId: $docId, ')
          ..write('lineNo: $lineNo, ')
          ..write('startMs: $startMs, ')
          ..write('lineText: $lineText, ')
          ..write('searchText: $searchText')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, docId, lineNo, startMs, lineText, searchText);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LyricsLine &&
          other.id == this.id &&
          other.docId == this.docId &&
          other.lineNo == this.lineNo &&
          other.startMs == this.startMs &&
          other.lineText == this.lineText &&
          other.searchText == this.searchText);
}

class LyricsLinesCompanion extends UpdateCompanion<LyricsLine> {
  final Value<int> id;
  final Value<int> docId;
  final Value<int> lineNo;
  final Value<int?> startMs;
  final Value<String> lineText;
  final Value<String> searchText;
  const LyricsLinesCompanion({
    this.id = const Value.absent(),
    this.docId = const Value.absent(),
    this.lineNo = const Value.absent(),
    this.startMs = const Value.absent(),
    this.lineText = const Value.absent(),
    this.searchText = const Value.absent(),
  });
  LyricsLinesCompanion.insert({
    this.id = const Value.absent(),
    required int docId,
    required int lineNo,
    this.startMs = const Value.absent(),
    required String lineText,
    required String searchText,
  }) : docId = Value(docId),
       lineNo = Value(lineNo),
       lineText = Value(lineText),
       searchText = Value(searchText);
  static Insertable<LyricsLine> custom({
    Expression<int>? id,
    Expression<int>? docId,
    Expression<int>? lineNo,
    Expression<int>? startMs,
    Expression<String>? lineText,
    Expression<String>? searchText,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (docId != null) 'doc_id': docId,
      if (lineNo != null) 'line_no': lineNo,
      if (startMs != null) 'start_ms': startMs,
      if (lineText != null) 'text': lineText,
      if (searchText != null) 'search_text': searchText,
    });
  }

  LyricsLinesCompanion copyWith({
    Value<int>? id,
    Value<int>? docId,
    Value<int>? lineNo,
    Value<int?>? startMs,
    Value<String>? lineText,
    Value<String>? searchText,
  }) {
    return LyricsLinesCompanion(
      id: id ?? this.id,
      docId: docId ?? this.docId,
      lineNo: lineNo ?? this.lineNo,
      startMs: startMs ?? this.startMs,
      lineText: lineText ?? this.lineText,
      searchText: searchText ?? this.searchText,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (docId.present) {
      map['doc_id'] = Variable<int>(docId.value);
    }
    if (lineNo.present) {
      map['line_no'] = Variable<int>(lineNo.value);
    }
    if (startMs.present) {
      map['start_ms'] = Variable<int>(startMs.value);
    }
    if (lineText.present) {
      map['text'] = Variable<String>(lineText.value);
    }
    if (searchText.present) {
      map['search_text'] = Variable<String>(searchText.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LyricsLinesCompanion(')
          ..write('id: $id, ')
          ..write('docId: $docId, ')
          ..write('lineNo: $lineNo, ')
          ..write('startMs: $startMs, ')
          ..write('lineText: $lineText, ')
          ..write('searchText: $searchText')
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
  late final $LyricsDocsTable lyricsDocs = $LyricsDocsTable(this);
  late final $LyricsLinesTable lyricsLines = $LyricsLinesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    playlists,
    tracks,
    sponsorBlockSegments,
    lyricsDocs,
    lyricsLines,
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
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'tracks',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('lyrics_docs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'lyrics_docs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('lyrics_lines', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$PlaylistsTableCreateCompanionBuilder =
    PlaylistsCompanion Function({
      Value<bool?> playChapters,
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
      Value<DateTime?> lastUpdateAttempt,
      Value<int> sortOrder,
      Value<int?> videoQuality,
      Value<bool> isTemporary,
      Value<String?> lyricsMode,
    });
typedef $$PlaylistsTableUpdateCompanionBuilder =
    PlaylistsCompanion Function({
      Value<bool?> playChapters,
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
      Value<DateTime?> lastUpdateAttempt,
      Value<int> sortOrder,
      Value<int?> videoQuality,
      Value<bool> isTemporary,
      Value<String?> lyricsMode,
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
  ColumnFilters<bool> get playChapters => $composableBuilder(
    column: $table.playChapters,
    builder: (column) => ColumnFilters(column),
  );

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

  ColumnFilters<DateTime> get lastUpdateAttempt => $composableBuilder(
    column: $table.lastUpdateAttempt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isTemporary => $composableBuilder(
    column: $table.isTemporary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lyricsMode => $composableBuilder(
    column: $table.lyricsMode,
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
  ColumnOrderings<bool> get playChapters => $composableBuilder(
    column: $table.playChapters,
    builder: (column) => ColumnOrderings(column),
  );

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

  ColumnOrderings<DateTime> get lastUpdateAttempt => $composableBuilder(
    column: $table.lastUpdateAttempt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isTemporary => $composableBuilder(
    column: $table.isTemporary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lyricsMode => $composableBuilder(
    column: $table.lyricsMode,
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
  GeneratedColumn<bool> get playChapters => $composableBuilder(
    column: $table.playChapters,
    builder: (column) => column,
  );

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

  GeneratedColumn<DateTime> get lastUpdateAttempt => $composableBuilder(
    column: $table.lastUpdateAttempt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isTemporary => $composableBuilder(
    column: $table.isTemporary,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lyricsMode => $composableBuilder(
    column: $table.lyricsMode,
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
                Value<bool?> playChapters = const Value.absent(),
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
                Value<DateTime?> lastUpdateAttempt = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int?> videoQuality = const Value.absent(),
                Value<bool> isTemporary = const Value.absent(),
                Value<String?> lyricsMode = const Value.absent(),
              }) => PlaylistsCompanion(
                playChapters: playChapters,
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
                lastUpdateAttempt: lastUpdateAttempt,
                sortOrder: sortOrder,
                videoQuality: videoQuality,
                isTemporary: isTemporary,
                lyricsMode: lyricsMode,
              ),
          createCompanionCallback:
              ({
                Value<bool?> playChapters = const Value.absent(),
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
                Value<DateTime?> lastUpdateAttempt = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int?> videoQuality = const Value.absent(),
                Value<bool> isTemporary = const Value.absent(),
                Value<String?> lyricsMode = const Value.absent(),
              }) => PlaylistsCompanion.insert(
                playChapters: playChapters,
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
                lastUpdateAttempt: lastUpdateAttempt,
                sortOrder: sortOrder,
                videoQuality: videoQuality,
                isTemporary: isTemporary,
                lyricsMode: lyricsMode,
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
      Value<String?> chaptersJson,
      Value<bool?> chaptersEnabled,
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
      Value<bool> alwaysSkip,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> sponsorBlockCheckedAt,
      Value<String?> lastError,
      Value<bool> replaceRequested,
      Value<int?> videoQuality,
      Value<int?> downloadedMaxHeight,
    });
typedef $$TracksTableUpdateCompanionBuilder =
    TracksCompanion Function({
      Value<String?> chaptersJson,
      Value<bool?> chaptersEnabled,
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
      Value<bool> alwaysSkip,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> sponsorBlockCheckedAt,
      Value<String?> lastError,
      Value<bool> replaceRequested,
      Value<int?> videoQuality,
      Value<int?> downloadedMaxHeight,
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

  static MultiTypedResultKey<$LyricsDocsTable, List<LyricsDoc>>
  _lyricsDocsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.lyricsDocs,
    aliasName: $_aliasNameGenerator(db.tracks.id, db.lyricsDocs.trackId),
  );

  $$LyricsDocsTableProcessedTableManager get lyricsDocsRefs {
    final manager = $$LyricsDocsTableTableManager(
      $_db,
      $_db.lyricsDocs,
    ).filter((f) => f.trackId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_lyricsDocsRefsTable($_db));
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
  ColumnFilters<String> get chaptersJson => $composableBuilder(
    column: $table.chaptersJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get chaptersEnabled => $composableBuilder(
    column: $table.chaptersEnabled,
    builder: (column) => ColumnFilters(column),
  );

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

  ColumnFilters<bool> get alwaysSkip => $composableBuilder(
    column: $table.alwaysSkip,
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

  ColumnFilters<bool> get replaceRequested => $composableBuilder(
    column: $table.replaceRequested,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedMaxHeight => $composableBuilder(
    column: $table.downloadedMaxHeight,
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

  Expression<bool> lyricsDocsRefs(
    Expression<bool> Function($$LyricsDocsTableFilterComposer f) f,
  ) {
    final $$LyricsDocsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.lyricsDocs,
      getReferencedColumn: (t) => t.trackId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsDocsTableFilterComposer(
            $db: $db,
            $table: $db.lyricsDocs,
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
  ColumnOrderings<String> get chaptersJson => $composableBuilder(
    column: $table.chaptersJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get chaptersEnabled => $composableBuilder(
    column: $table.chaptersEnabled,
    builder: (column) => ColumnOrderings(column),
  );

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

  ColumnOrderings<bool> get alwaysSkip => $composableBuilder(
    column: $table.alwaysSkip,
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

  ColumnOrderings<bool> get replaceRequested => $composableBuilder(
    column: $table.replaceRequested,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedMaxHeight => $composableBuilder(
    column: $table.downloadedMaxHeight,
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
  GeneratedColumn<String> get chaptersJson => $composableBuilder(
    column: $table.chaptersJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get chaptersEnabled => $composableBuilder(
    column: $table.chaptersEnabled,
    builder: (column) => column,
  );

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

  GeneratedColumn<bool> get alwaysSkip => $composableBuilder(
    column: $table.alwaysSkip,
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

  GeneratedColumn<bool> get replaceRequested => $composableBuilder(
    column: $table.replaceRequested,
    builder: (column) => column,
  );

  GeneratedColumn<int> get videoQuality => $composableBuilder(
    column: $table.videoQuality,
    builder: (column) => column,
  );

  GeneratedColumn<int> get downloadedMaxHeight => $composableBuilder(
    column: $table.downloadedMaxHeight,
    builder: (column) => column,
  );

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

  Expression<T> lyricsDocsRefs<T extends Object>(
    Expression<T> Function($$LyricsDocsTableAnnotationComposer a) f,
  ) {
    final $$LyricsDocsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.lyricsDocs,
      getReferencedColumn: (t) => t.trackId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsDocsTableAnnotationComposer(
            $db: $db,
            $table: $db.lyricsDocs,
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
            bool lyricsDocsRefs,
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
                Value<String?> chaptersJson = const Value.absent(),
                Value<bool?> chaptersEnabled = const Value.absent(),
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
                Value<bool> alwaysSkip = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<bool> replaceRequested = const Value.absent(),
                Value<int?> videoQuality = const Value.absent(),
                Value<int?> downloadedMaxHeight = const Value.absent(),
              }) => TracksCompanion(
                chaptersJson: chaptersJson,
                chaptersEnabled: chaptersEnabled,
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
                alwaysSkip: alwaysSkip,
                downloadedAt: downloadedAt,
                sponsorBlockCheckedAt: sponsorBlockCheckedAt,
                lastError: lastError,
                replaceRequested: replaceRequested,
                videoQuality: videoQuality,
                downloadedMaxHeight: downloadedMaxHeight,
              ),
          createCompanionCallback:
              ({
                Value<String?> chaptersJson = const Value.absent(),
                Value<bool?> chaptersEnabled = const Value.absent(),
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
                Value<bool> alwaysSkip = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> sponsorBlockCheckedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<bool> replaceRequested = const Value.absent(),
                Value<int?> videoQuality = const Value.absent(),
                Value<int?> downloadedMaxHeight = const Value.absent(),
              }) => TracksCompanion.insert(
                chaptersJson: chaptersJson,
                chaptersEnabled: chaptersEnabled,
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
                alwaysSkip: alwaysSkip,
                downloadedAt: downloadedAt,
                sponsorBlockCheckedAt: sponsorBlockCheckedAt,
                lastError: lastError,
                replaceRequested: replaceRequested,
                videoQuality: videoQuality,
                downloadedMaxHeight: downloadedMaxHeight,
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
            lyricsDocsRefs = false,
          }) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (sponsorBlockSegmentsRefs) db.sponsorBlockSegments,
                if (lyricsDocsRefs) db.lyricsDocs,
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
                  if (lyricsDocsRefs)
                    await $_getPrefetchedData<Track, $TracksTable, LyricsDoc>(
                      currentTable: table,
                      referencedTable: $$TracksTableReferences
                          ._lyricsDocsRefsTable(db),
                      managerFromTypedResult:
                          (p0) =>
                              $$TracksTableReferences(
                                db,
                                table,
                                p0,
                              ).lyricsDocsRefs,
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
      PrefetchHooks Function({
        bool playlistId,
        bool sponsorBlockSegmentsRefs,
        bool lyricsDocsRefs,
      })
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
typedef $$LyricsDocsTableCreateCompanionBuilder =
    LyricsDocsCompanion Function({
      Value<int> id,
      required int trackId,
      Value<String?> chapterId,
      Value<int> offsetMs,
      required String kind,
      required String status,
      Value<String?> source,
      Value<String?> sourceRef,
      Value<String?> matchedArtist,
      Value<String?> matchedTitle,
      Value<double> timeScale,
      Value<bool> synced,
      Value<bool> pinned,
      Value<int> shiftMs,
      Value<bool> timingOff,
      Value<String?> lang,
      required DateTime checkedAt,
      Value<int> attempts,
    });
typedef $$LyricsDocsTableUpdateCompanionBuilder =
    LyricsDocsCompanion Function({
      Value<int> id,
      Value<int> trackId,
      Value<String?> chapterId,
      Value<int> offsetMs,
      Value<String> kind,
      Value<String> status,
      Value<String?> source,
      Value<String?> sourceRef,
      Value<String?> matchedArtist,
      Value<String?> matchedTitle,
      Value<double> timeScale,
      Value<bool> synced,
      Value<bool> pinned,
      Value<int> shiftMs,
      Value<bool> timingOff,
      Value<String?> lang,
      Value<DateTime> checkedAt,
      Value<int> attempts,
    });

final class $$LyricsDocsTableReferences
    extends BaseReferences<_$AppDatabase, $LyricsDocsTable, LyricsDoc> {
  $$LyricsDocsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TracksTable _trackIdTable(_$AppDatabase db) => db.tracks.createAlias(
    $_aliasNameGenerator(db.lyricsDocs.trackId, db.tracks.id),
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

  static MultiTypedResultKey<$LyricsLinesTable, List<LyricsLine>>
  _lyricsLinesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.lyricsLines,
    aliasName: $_aliasNameGenerator(db.lyricsDocs.id, db.lyricsLines.docId),
  );

  $$LyricsLinesTableProcessedTableManager get lyricsLinesRefs {
    final manager = $$LyricsLinesTableTableManager(
      $_db,
      $_db.lyricsLines,
    ).filter((f) => f.docId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_lyricsLinesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LyricsDocsTableFilterComposer
    extends Composer<_$AppDatabase, $LyricsDocsTable> {
  $$LyricsDocsTableFilterComposer({
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

  ColumnFilters<String> get chapterId => $composableBuilder(
    column: $table.chapterId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get offsetMs => $composableBuilder(
    column: $table.offsetMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get matchedArtist => $composableBuilder(
    column: $table.matchedArtist,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get matchedTitle => $composableBuilder(
    column: $table.matchedTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get timeScale => $composableBuilder(
    column: $table.timeScale,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get shiftMs => $composableBuilder(
    column: $table.shiftMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get timingOff => $composableBuilder(
    column: $table.timingOff,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lang => $composableBuilder(
    column: $table.lang,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get checkedAt => $composableBuilder(
    column: $table.checkedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
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

  Expression<bool> lyricsLinesRefs(
    Expression<bool> Function($$LyricsLinesTableFilterComposer f) f,
  ) {
    final $$LyricsLinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.lyricsLines,
      getReferencedColumn: (t) => t.docId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsLinesTableFilterComposer(
            $db: $db,
            $table: $db.lyricsLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LyricsDocsTableOrderingComposer
    extends Composer<_$AppDatabase, $LyricsDocsTable> {
  $$LyricsDocsTableOrderingComposer({
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

  ColumnOrderings<String> get chapterId => $composableBuilder(
    column: $table.chapterId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get offsetMs => $composableBuilder(
    column: $table.offsetMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get matchedArtist => $composableBuilder(
    column: $table.matchedArtist,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get matchedTitle => $composableBuilder(
    column: $table.matchedTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get timeScale => $composableBuilder(
    column: $table.timeScale,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get shiftMs => $composableBuilder(
    column: $table.shiftMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get timingOff => $composableBuilder(
    column: $table.timingOff,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lang => $composableBuilder(
    column: $table.lang,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get checkedAt => $composableBuilder(
    column: $table.checkedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
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

class $$LyricsDocsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LyricsDocsTable> {
  $$LyricsDocsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get chapterId =>
      $composableBuilder(column: $table.chapterId, builder: (column) => column);

  GeneratedColumn<int> get offsetMs =>
      $composableBuilder(column: $table.offsetMs, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get matchedArtist => $composableBuilder(
    column: $table.matchedArtist,
    builder: (column) => column,
  );

  GeneratedColumn<String> get matchedTitle => $composableBuilder(
    column: $table.matchedTitle,
    builder: (column) => column,
  );

  GeneratedColumn<double> get timeScale =>
      $composableBuilder(column: $table.timeScale, builder: (column) => column);

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);

  GeneratedColumn<int> get shiftMs =>
      $composableBuilder(column: $table.shiftMs, builder: (column) => column);

  GeneratedColumn<bool> get timingOff =>
      $composableBuilder(column: $table.timingOff, builder: (column) => column);

  GeneratedColumn<String> get lang =>
      $composableBuilder(column: $table.lang, builder: (column) => column);

  GeneratedColumn<DateTime> get checkedAt =>
      $composableBuilder(column: $table.checkedAt, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

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

  Expression<T> lyricsLinesRefs<T extends Object>(
    Expression<T> Function($$LyricsLinesTableAnnotationComposer a) f,
  ) {
    final $$LyricsLinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.lyricsLines,
      getReferencedColumn: (t) => t.docId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsLinesTableAnnotationComposer(
            $db: $db,
            $table: $db.lyricsLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LyricsDocsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LyricsDocsTable,
          LyricsDoc,
          $$LyricsDocsTableFilterComposer,
          $$LyricsDocsTableOrderingComposer,
          $$LyricsDocsTableAnnotationComposer,
          $$LyricsDocsTableCreateCompanionBuilder,
          $$LyricsDocsTableUpdateCompanionBuilder,
          (LyricsDoc, $$LyricsDocsTableReferences),
          LyricsDoc,
          PrefetchHooks Function({bool trackId, bool lyricsLinesRefs})
        > {
  $$LyricsDocsTableTableManager(_$AppDatabase db, $LyricsDocsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$LyricsDocsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$LyricsDocsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$LyricsDocsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> trackId = const Value.absent(),
                Value<String?> chapterId = const Value.absent(),
                Value<int> offsetMs = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String?> matchedArtist = const Value.absent(),
                Value<String?> matchedTitle = const Value.absent(),
                Value<double> timeScale = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> shiftMs = const Value.absent(),
                Value<bool> timingOff = const Value.absent(),
                Value<String?> lang = const Value.absent(),
                Value<DateTime> checkedAt = const Value.absent(),
                Value<int> attempts = const Value.absent(),
              }) => LyricsDocsCompanion(
                id: id,
                trackId: trackId,
                chapterId: chapterId,
                offsetMs: offsetMs,
                kind: kind,
                status: status,
                source: source,
                sourceRef: sourceRef,
                matchedArtist: matchedArtist,
                matchedTitle: matchedTitle,
                timeScale: timeScale,
                synced: synced,
                pinned: pinned,
                shiftMs: shiftMs,
                timingOff: timingOff,
                lang: lang,
                checkedAt: checkedAt,
                attempts: attempts,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int trackId,
                Value<String?> chapterId = const Value.absent(),
                Value<int> offsetMs = const Value.absent(),
                required String kind,
                required String status,
                Value<String?> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String?> matchedArtist = const Value.absent(),
                Value<String?> matchedTitle = const Value.absent(),
                Value<double> timeScale = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> shiftMs = const Value.absent(),
                Value<bool> timingOff = const Value.absent(),
                Value<String?> lang = const Value.absent(),
                required DateTime checkedAt,
                Value<int> attempts = const Value.absent(),
              }) => LyricsDocsCompanion.insert(
                id: id,
                trackId: trackId,
                chapterId: chapterId,
                offsetMs: offsetMs,
                kind: kind,
                status: status,
                source: source,
                sourceRef: sourceRef,
                matchedArtist: matchedArtist,
                matchedTitle: matchedTitle,
                timeScale: timeScale,
                synced: synced,
                pinned: pinned,
                shiftMs: shiftMs,
                timingOff: timingOff,
                lang: lang,
                checkedAt: checkedAt,
                attempts: attempts,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          $$LyricsDocsTableReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: ({trackId = false, lyricsLinesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (lyricsLinesRefs) db.lyricsLines],
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
                            referencedTable: $$LyricsDocsTableReferences
                                ._trackIdTable(db),
                            referencedColumn:
                                $$LyricsDocsTableReferences
                                    ._trackIdTable(db)
                                    .id,
                          )
                          as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (lyricsLinesRefs)
                    await $_getPrefetchedData<
                      LyricsDoc,
                      $LyricsDocsTable,
                      LyricsLine
                    >(
                      currentTable: table,
                      referencedTable: $$LyricsDocsTableReferences
                          ._lyricsLinesRefsTable(db),
                      managerFromTypedResult:
                          (p0) =>
                              $$LyricsDocsTableReferences(
                                db,
                                table,
                                p0,
                              ).lyricsLinesRefs,
                      referencedItemsForCurrentItem:
                          (item, referencedItems) =>
                              referencedItems.where((e) => e.docId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$LyricsDocsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LyricsDocsTable,
      LyricsDoc,
      $$LyricsDocsTableFilterComposer,
      $$LyricsDocsTableOrderingComposer,
      $$LyricsDocsTableAnnotationComposer,
      $$LyricsDocsTableCreateCompanionBuilder,
      $$LyricsDocsTableUpdateCompanionBuilder,
      (LyricsDoc, $$LyricsDocsTableReferences),
      LyricsDoc,
      PrefetchHooks Function({bool trackId, bool lyricsLinesRefs})
    >;
typedef $$LyricsLinesTableCreateCompanionBuilder =
    LyricsLinesCompanion Function({
      Value<int> id,
      required int docId,
      required int lineNo,
      Value<int?> startMs,
      required String lineText,
      required String searchText,
    });
typedef $$LyricsLinesTableUpdateCompanionBuilder =
    LyricsLinesCompanion Function({
      Value<int> id,
      Value<int> docId,
      Value<int> lineNo,
      Value<int?> startMs,
      Value<String> lineText,
      Value<String> searchText,
    });

final class $$LyricsLinesTableReferences
    extends BaseReferences<_$AppDatabase, $LyricsLinesTable, LyricsLine> {
  $$LyricsLinesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LyricsDocsTable _docIdTable(_$AppDatabase db) =>
      db.lyricsDocs.createAlias(
        $_aliasNameGenerator(db.lyricsLines.docId, db.lyricsDocs.id),
      );

  $$LyricsDocsTableProcessedTableManager get docId {
    final $_column = $_itemColumn<int>('doc_id')!;

    final manager = $$LyricsDocsTableTableManager(
      $_db,
      $_db.lyricsDocs,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_docIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LyricsLinesTableFilterComposer
    extends Composer<_$AppDatabase, $LyricsLinesTable> {
  $$LyricsLinesTableFilterComposer({
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

  ColumnFilters<int> get lineNo => $composableBuilder(
    column: $table.lineNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startMs => $composableBuilder(
    column: $table.startMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lineText => $composableBuilder(
    column: $table.lineText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get searchText => $composableBuilder(
    column: $table.searchText,
    builder: (column) => ColumnFilters(column),
  );

  $$LyricsDocsTableFilterComposer get docId {
    final $$LyricsDocsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.docId,
      referencedTable: $db.lyricsDocs,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsDocsTableFilterComposer(
            $db: $db,
            $table: $db.lyricsDocs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LyricsLinesTableOrderingComposer
    extends Composer<_$AppDatabase, $LyricsLinesTable> {
  $$LyricsLinesTableOrderingComposer({
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

  ColumnOrderings<int> get lineNo => $composableBuilder(
    column: $table.lineNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startMs => $composableBuilder(
    column: $table.startMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lineText => $composableBuilder(
    column: $table.lineText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get searchText => $composableBuilder(
    column: $table.searchText,
    builder: (column) => ColumnOrderings(column),
  );

  $$LyricsDocsTableOrderingComposer get docId {
    final $$LyricsDocsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.docId,
      referencedTable: $db.lyricsDocs,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsDocsTableOrderingComposer(
            $db: $db,
            $table: $db.lyricsDocs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LyricsLinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LyricsLinesTable> {
  $$LyricsLinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get lineNo =>
      $composableBuilder(column: $table.lineNo, builder: (column) => column);

  GeneratedColumn<int> get startMs =>
      $composableBuilder(column: $table.startMs, builder: (column) => column);

  GeneratedColumn<String> get lineText =>
      $composableBuilder(column: $table.lineText, builder: (column) => column);

  GeneratedColumn<String> get searchText => $composableBuilder(
    column: $table.searchText,
    builder: (column) => column,
  );

  $$LyricsDocsTableAnnotationComposer get docId {
    final $$LyricsDocsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.docId,
      referencedTable: $db.lyricsDocs,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LyricsDocsTableAnnotationComposer(
            $db: $db,
            $table: $db.lyricsDocs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LyricsLinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LyricsLinesTable,
          LyricsLine,
          $$LyricsLinesTableFilterComposer,
          $$LyricsLinesTableOrderingComposer,
          $$LyricsLinesTableAnnotationComposer,
          $$LyricsLinesTableCreateCompanionBuilder,
          $$LyricsLinesTableUpdateCompanionBuilder,
          (LyricsLine, $$LyricsLinesTableReferences),
          LyricsLine,
          PrefetchHooks Function({bool docId})
        > {
  $$LyricsLinesTableTableManager(_$AppDatabase db, $LyricsLinesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$LyricsLinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$LyricsLinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () =>
                  $$LyricsLinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> docId = const Value.absent(),
                Value<int> lineNo = const Value.absent(),
                Value<int?> startMs = const Value.absent(),
                Value<String> lineText = const Value.absent(),
                Value<String> searchText = const Value.absent(),
              }) => LyricsLinesCompanion(
                id: id,
                docId: docId,
                lineNo: lineNo,
                startMs: startMs,
                lineText: lineText,
                searchText: searchText,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int docId,
                required int lineNo,
                Value<int?> startMs = const Value.absent(),
                required String lineText,
                required String searchText,
              }) => LyricsLinesCompanion.insert(
                id: id,
                docId: docId,
                lineNo: lineNo,
                startMs: startMs,
                lineText: lineText,
                searchText: searchText,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          $$LyricsLinesTableReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: ({docId = false}) {
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
                if (docId) {
                  state =
                      state.withJoin(
                            currentTable: table,
                            currentColumn: table.docId,
                            referencedTable: $$LyricsLinesTableReferences
                                ._docIdTable(db),
                            referencedColumn:
                                $$LyricsLinesTableReferences._docIdTable(db).id,
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

typedef $$LyricsLinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LyricsLinesTable,
      LyricsLine,
      $$LyricsLinesTableFilterComposer,
      $$LyricsLinesTableOrderingComposer,
      $$LyricsLinesTableAnnotationComposer,
      $$LyricsLinesTableCreateCompanionBuilder,
      $$LyricsLinesTableUpdateCompanionBuilder,
      (LyricsLine, $$LyricsLinesTableReferences),
      LyricsLine,
      PrefetchHooks Function({bool docId})
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
  $$LyricsDocsTableTableManager get lyricsDocs =>
      $$LyricsDocsTableTableManager(_db, _db.lyricsDocs);
  $$LyricsLinesTableTableManager get lyricsLines =>
      $$LyricsLinesTableTableManager(_db, _db.lyricsLines);
}
