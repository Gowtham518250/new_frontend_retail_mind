import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'secure_token_storage.dart';

/// Durable local-first attendance operations.
///
/// The server is authoritative whenever a network connection is available.
/// Local storage is used as an outbox/cache when the request cannot reach the
/// backend. This is intentionally self-contained because the generic sync
/// queue does not currently dispatch attendance_check_in/check_out actions.
class OfflineAttendanceService {
  static const String _prefix = 'attendance_local_v2_';

  static Future<int?> _userId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('user_id') ?? prefs.getInt('userId');
  }

  static Future<String> _key(int userId) async => '$_prefix$userId';

  static Future<List<Map<String, dynamic>>> loadLocalRecords() async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return <Map<String, dynamic>>[];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _key(uid));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _saveRecords(List<Map<String, dynamic>> records) async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final dedup = <String, Map<String, dynamic>>{};
    for (final record in records) {
      final key = '${record['worker_id'] ?? record['employee_id'] ?? uid}:${record['attendance_date'] ?? ''}';
      dedup[key] = record;
    }
    await prefs.setString(await _key(uid), jsonEncode(dedup.values.toList()));
  }

  static Future<void> _upsertLocal({
    required int employeeId,
    int? workerId,
    required String date,
    DateTime? checkIn,
    DateTime? checkOut,
    String? status,
    double? workingHours,
  }) async {
    final records = await loadLocalRecords();
    final index = records.indexWhere((r) =>
        (r['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '') &&
        (r['employee_id']?.toString() ?? '') == employeeId.toString() &&
        (r['attendance_date']?.toString().split('T').first ?? '') == date);

    final existing = index >= 0 ? Map<String, dynamic>.from(records[index]) : <String, dynamic>{};
    final merged = <String, dynamic>{
      ...existing,
      'employee_id': employeeId,
      if (workerId != null) 'worker_id': workerId,
      'attendance_date': date,
      if (checkIn != null) 'check_in_time': checkIn.toUtc().toIso8601String(),
      if (checkOut != null) 'check_out_time': checkOut.toUtc().toIso8601String(),
      if (status != null) 'status': status.toUpperCase(),
      if (workingHours != null) 'working_hours': workingHours,
      'local_pending': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (index >= 0) {
      records[index] = merged;
    } else {
      records.add(merged);
    }
    await _saveRecords(records);
  }

  static Future<Map<String, dynamic>?> _fetchRemoteToday(String date) async {
    try {
      final uid = await _userId();
      if (uid == null || uid <= 0) return null;
      final response = await ApiClient.getJson(
        '${ApiClient.attendancePrefix}/date/$date?employee_id=$uid',
      );
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['records'] is! List) return null;

      for (final raw in decoded['records'] as List) {
        if (raw is! Map) continue;
        final record = Map<String, dynamic>.from(raw);
        final employeeId = record['employee_id']?.toString();
        if (employeeId == uid.toString()) return record;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Attendance remote fetch skipped: $e');
    }
    return null;
  }

  static Future<bool> _postAttendance({
    required String endpoint,
    required int employeeId,
  }) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return false;

      final response = await ApiClient.postJson(
        '$endpoint?employee_id=$employeeId',
        {},
        headers: {'Authorization': 'Bearer $token'},
      );

      // 200/201 means the operation was persisted by the backend.
      if (response.statusCode == 200 || response.statusCode == 201) return true;

      // A duplicate state is already durable on the backend. Treat these as
      // successful reconciliation rather than recreating local state forever.
      if (response.statusCode == 400) {
        final body = response.body.toLowerCase();
        if (body.contains('already') ||
            body.contains('already checked') ||
            body.contains('already marked')) {
          return true;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Attendance POST deferred: $e');
    }
    return false;
  }

  static Future<void> _syncPendingToday() async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return;

    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final records = await loadLocalRecords();

    Map<String, dynamic>? local;
    for (final r in records) {
      if ((r['employee_id']?.toString() ?? '') == uid.toString() &&
          (r['attendance_date']?.toString().split('T').first ?? '') == date) {
        local = r;
        break;
      }
    }
    if (local == null || local['local_pending'] != true) return;

    final remote = await _fetchRemoteToday(date);
    bool synced = false;

    if (remote == null && local['check_in_time'] != null) {
      // No server record: restore the check-in first.
      synced = await _postAttendance(
        endpoint: ApiClient.attendanceCheckIn,
        employeeId: uid,
      );
    } else if (remote != null) {
      synced = true;
    }

    // If the local state also contains a checkout, ensure the backend reaches
    // the same final state. This covers a check-in + check-out performed while
    // offline before the app is opened again.
    final remoteAfterCheckIn = await _fetchRemoteToday(date);
    final localHasCheckout = local['check_out_time'] != null;
    if (localHasCheckout && remoteAfterCheckIn != null &&
        remoteAfterCheckIn['check_out_time'] == null) {
      synced = await _postAttendance(
        endpoint: ApiClient.attendanceCheckOut,
        employeeId: uid,
      ) && synced;
    }

    if (synced) {
      await markSynced(employeeId: uid, workerId: null, date: date);
    }
  }

  static Future<bool> checkIn({required int employeeId, int? workerId}) async {
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // Write local state first so the UI never loses the user's action.
    await _upsertLocal(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
      checkIn: now,
      status: 'PRESENT',
    );

    // IMPORTANT: the generic SyncService currently has no cases for
    // attendance_check_in/check_out. Attempt the authoritative backend call
    // here instead of enqueueing an operation that nobody will dispatch.
    final synced = await _postAttendance(
      endpoint: ApiClient.attendanceCheckIn,
      employeeId: employeeId,
    );

    if (synced) {
      await markSynced(employeeId: employeeId, workerId: workerId, date: date);
    }
    // A false result is intentionally not treated as data loss: local_pending
    // remains true and _syncPendingToday() will retry on the next app start.
    return true;
  }

  static Future<bool> checkOut({required int employeeId, int? workerId}) async {
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final records = await loadLocalRecords();
    Map<String, dynamic>? existing;
    for (final r in records) {
      if ((r['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '') &&
          (r['employee_id']?.toString() ?? '') == employeeId.toString() &&
          (r['attendance_date']?.toString().split('T').first ?? '') == date) {
        existing = r;
        break;
      }
    }

    DateTime? checkIn;
    final rawCheckIn = existing?['check_in_time'];
    if (rawCheckIn != null) checkIn = DateTime.tryParse(rawCheckIn.toString());
    final workingHours = checkIn == null ? null : now.difference(checkIn.toLocal()).inSeconds / 3600.0;

    await _upsertLocal(
      employeeId: employeeId,
      workerId: workerId,
      date: date,
      checkOut: now,
      workingHours: workingHours,
      status: 'PRESENT',
    );

    final synced = await _postAttendance(
      endpoint: ApiClient.attendanceCheckOut,
      employeeId: employeeId,
    );

    if (synced) {
      await markSynced(employeeId: employeeId, workerId: workerId, date: date);
    }
    return true;
  }

  static Future<void> reconcileFromBackend() async {
    final uid = await _userId();
    if (uid == null || uid <= 0) return;

    // First recover any local action that was performed while offline. This is
    // the critical part that makes the state survive app-data clearing once the
    // user logs back in.
    await _syncPendingToday();

    try {
      final today = DateTime.now();
      final date = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final response = await ApiClient.getJson('${ApiClient.attendancePrefix}/date/$date');
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['records'] is! List) return;

      final remote = (decoded['records'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final local = await loadLocalRecords();
      final merged = <String, Map<String, dynamic>>{};
      for (final r in [...local, ...remote]) {
        final key = '${r['worker_id'] ?? r['employee_id'] ?? uid}:${r['attendance_date'] ?? ''}';
        final previous = merged[key];
        if (previous == null) {
          merged[key] = r;
        } else if (r['local_pending'] == true && previous['local_pending'] != true) {
          merged[key] = r;
        } else if (previous['local_pending'] == true) {
          merged[key] = {...r, ...previous, 'local_pending': true};
        } else {
          merged[key] = {...previous, ...r};
        }
      }
      await _saveRecords(merged.values.toList());
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineAttendance reconcile skipped: $e');
    }
  }

  static Future<void> markSynced({required int employeeId, int? workerId, required String date}) async {
    final records = await loadLocalRecords();
    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      if ((r['employee_id']?.toString() ?? '') == employeeId.toString() &&
          (r['worker_id']?.toString() ?? '') == (workerId?.toString() ?? '') &&
          (r['attendance_date']?.toString().split('T').first ?? '') == date) {
        records[i] = {
          ...r,
          'local_pending': false,
          'synced_at': DateTime.now().toUtc().toIso8601String(),
        };
        await _saveRecords(records);
        return;
      }
    }
  }
}
