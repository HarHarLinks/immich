import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/modules/album/services/album.service.dart';
import 'package:immich_mobile/shared/models/exif_info.dart';
import 'package:immich_mobile/shared/models/store.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:immich_mobile/shared/providers/user.provider.dart';
import 'package:immich_mobile/shared/services/asset.service.dart';
import 'package:immich_mobile/modules/home/ui/asset_grid/asset_grid_data_structure.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/services/sync.service.dart';
import 'package:immich_mobile/shared/services/user.service.dart';
import 'package:immich_mobile/utils/db.dart';
import 'package:immich_mobile/utils/renderlist_generator.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart';

class AssetNotifier extends StateNotifier<bool> {
  final AssetService _assetService;
  final AlbumService _albumService;
  final UserService _userService;
  final SyncService _syncService;
  final Isar _db;
  final log = Logger('AssetNotifier');
  bool _getAllAssetInProgress = false;
  bool _deleteInProgress = false;
  bool _getPartnerAssetsInProgress = false;

  AssetNotifier(
    this._assetService,
    this._albumService,
    this._userService,
    this._syncService,
    this._db,
  ) : super(false);

  Future<void> getAllAsset({bool clear = false}) async {
    if (_getAllAssetInProgress || _deleteInProgress) {
      // guard against multiple calls to this method while it's still working
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      _getAllAssetInProgress = true;
      state = true;
      if (clear) {
        await clearAssetsAndAlbums(_db);
        log.info("Manual refresh requested, cleared assets and albums from db");
      }
      final bool newRemote = await _assetService.refreshRemoteAssets();
      final bool newLocal = await _albumService.refreshDeviceAlbums();
      debugPrint("newRemote: $newRemote, newLocal: $newLocal");

      log.info("Load assets: ${stopwatch.elapsedMilliseconds}ms");
    } finally {
      _getAllAssetInProgress = false;
      state = false;
    }
  }

  Future<void> getPartnerAssets([User? partner]) async {
    if (_getPartnerAssetsInProgress) return;
    try {
      final stopwatch = Stopwatch()..start();
      _getPartnerAssetsInProgress = true;
      if (partner == null) {
        await _userService.refreshUsers();
        final List<User> partners =
            await _db.users.filter().isPartnerSharedWithEqualTo(true).findAll();
        for (User u in partners) {
          await _assetService.refreshRemoteAssets(u);
        }
      } else {
        await _assetService.refreshRemoteAssets(partner);
      }
      log.info("Load partner assets: ${stopwatch.elapsedMilliseconds}ms");
    } finally {
      _getPartnerAssetsInProgress = false;
    }
  }

  Future<void> clearAllAsset() {
    return clearAssetsAndAlbums(_db);
  }

  Future<void> onNewAssetUploaded(Asset newAsset) async {
    // eTag on device is not valid after partially modifying the assets
    Store.delete(StoreKey.assetETag);
    await _syncService.syncNewAssetToDb(newAsset);
  }

  Future<bool> deleteAssets(
    Iterable<Asset> deleteAssets, {
    bool force = false,
  }) async {
    _deleteInProgress = true;
    state = true;
    try {
      final localDeleted = await _deleteLocalAssets(deleteAssets);
      final remoteDeleted = await _deleteRemoteAssets(deleteAssets, force);
      if (localDeleted.isNotEmpty || remoteDeleted.isNotEmpty) {
        final dbIds = <int>[];
        final dbUpdates = <Asset>[];

        // Local assets are removed
        if (localDeleted.isNotEmpty) {
          // Permanently remove local only assets from isar
          dbIds.addAll(
            deleteAssets
                .where((a) => a.storage == AssetState.local)
                .map((e) => e.id),
          );

          if (remoteDeleted.any((e) => e.isLocal)) {
            // Force delete: Add all local assets including merged assets
            if (force) {
              dbIds.addAll(remoteDeleted.map((e) => e.id));
              // Soft delete: Remove local Id from asset and trash it
            } else {
              dbUpdates.addAll(
                remoteDeleted.map((e) {
                  e.localId = null;
                  e.isTrashed = true;
                  return e;
                }),
              );
            }
          }
        }

        // Handle remote deletion
        if (remoteDeleted.isNotEmpty) {
          if (force) {
            // Remove remote only assets
            dbIds.addAll(
              deleteAssets
                  .where((a) => a.storage == AssetState.remote)
                  .map((e) => e.id),
            );
            // Local assets are not removed and there are merged assets
            final hasLocal = remoteDeleted.any((e) => e.isLocal);
            if (localDeleted.isEmpty && hasLocal) {
              // Remove remote Id from local assets
              dbUpdates.addAll(
                remoteDeleted.map((e) {
                  e.remoteId = null;
                  // Remove from trashed if remote asset is removed
                  e.isTrashed = false;
                  return e;
                }),
              );
            }
          } else {
            dbUpdates.addAll(
              remoteDeleted.map((e) {
                e.isTrashed = true;
                return e;
              }),
            );
          }
        }

        await _db.writeTxn(() async {
          await _db.assets.putAll(dbUpdates);
          await _db.exifInfos.deleteAll(dbIds);
          await _db.assets.deleteAll(dbIds);
        });
        return true;
      }
    } finally {
      _deleteInProgress = false;
      state = false;
    }
    return false;
  }

  Future<List<String>> _deleteLocalAssets(
    Iterable<Asset> assetsToDelete,
  ) async {
    final List<String> local =
        assetsToDelete.where((a) => a.isLocal).map((a) => a.localId!).toList();
    // Delete asset from device
    if (local.isNotEmpty) {
      try {
        return await PhotoManager.editor.deleteWithIds(local);
      } catch (e, stack) {
        log.severe("Failed to delete asset from device", e, stack);
      }
    }
    return [];
  }

  Future<Iterable<Asset>> _deleteRemoteAssets(
    Iterable<Asset> assetsToDelete,
    bool? force,
  ) async {
    final Iterable<Asset> remote = assetsToDelete.where((e) => e.isRemote);

    final isSuccess = await _assetService.deleteAssets(remote, force: force);
    return isSuccess ? remote : [];
  }

  Future<void> toggleFavorite(List<Asset> assets, [bool? status]) async {
    status ??= !assets.every((a) => a.isFavorite);
    final newAssets = await _assetService.changeFavoriteStatus(assets, status);
    for (Asset? newAsset in newAssets) {
      if (newAsset == null) {
        log.severe("Change favorite status failed for asset");
        continue;
      }
    }
  }

  Future<void> toggleArchive(List<Asset> assets, [bool? status]) async {
    status ??= assets.every((a) => a.isArchived);
    final newAssets = await _assetService.changeArchiveStatus(assets, status);
    int i = 0;
    for (Asset oldAsset in assets) {
      final newAsset = newAssets[i++];
      if (newAsset == null) {
        log.severe("Change archive status failed for asset ${oldAsset.id}");
        continue;
      }
    }
  }
}

final assetProvider = StateNotifierProvider<AssetNotifier, bool>((ref) {
  return AssetNotifier(
    ref.watch(assetServiceProvider),
    ref.watch(albumServiceProvider),
    ref.watch(userServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(dbProvider),
  );
});

final assetDetailProvider =
    StreamProvider.autoDispose.family<Asset, Asset>((ref, asset) async* {
  yield await ref.watch(assetServiceProvider).loadExif(asset);
  final db = ref.watch(dbProvider);
  await for (final a in db.assets.watchObject(asset.id)) {
    if (a != null) yield await ref.watch(assetServiceProvider).loadExif(a);
  }
});

final assetWatcher =
    StreamProvider.autoDispose.family<Asset?, Asset>((ref, asset) {
  final db = ref.watch(dbProvider);
  return db.assets.watchObject(asset.id, fireImmediately: true);
});

final assetsProvider = StreamProvider.family<RenderList, int?>((ref, userId) {
  if (userId == null) return const Stream.empty();
  final query = _commonFilterAndSort(
    _assets(ref).where().ownerIdEqualToAnyChecksum(userId),
  );
  return renderListGenerator(query, ref);
});

final multiUserAssetsProvider =
    StreamProvider.family<RenderList, List<int>>((ref, userIds) {
  if (userIds.isEmpty) return const Stream.empty();
  final query = _commonFilterAndSort(
    _assets(ref)
        .where()
        .anyOf(userIds, (q, u) => q.ownerIdEqualToAnyChecksum(u)),
  );
  return renderListGenerator(query, ref);
});

QueryBuilder<Asset, Asset, QAfterSortBy>? getRemoteAssetQuery(WidgetRef ref) {
  final userId = ref.watch(currentUserProvider)?.isarId;
  if (userId == null) {
    return null;
  }
  return ref
      .watch(dbProvider)
      .assets
      .where()
      .remoteIdIsNotNull()
      .filter()
      .ownerIdEqualTo(userId)
      .isTrashedEqualTo(false)
      .stackParentIdIsNull()
      .sortByFileCreatedAtDesc();
}

IsarCollection<Asset> _assets(StreamProviderRef<RenderList> ref) =>
    ref.watch(dbProvider).assets;

QueryBuilder<Asset, Asset, QAfterSortBy> _commonFilterAndSort(
  QueryBuilder<Asset, Asset, QAfterWhereClause> query,
) {
  return query
      .filter()
      .isArchivedEqualTo(false)
      .isTrashedEqualTo(false)
      .stackParentIdIsNull()
      .sortByFileCreatedAtDesc();
}
