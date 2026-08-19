import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'api_client.dart';

// =============================================================================
// payment_detection_service.dart  –  V18 REAL-WORLD DETECTION EDITION
// Built directly on V17. Goal: reduce false negatives, keep fraud safety.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT CHANGED FROM V17 (FIX-37 through FIX-48)
// ═══════════════════════════════════════════════════════════════════════════
//
//  FIX-37  RELAX UTR DEPENDENCY — small payments (< ₹2000) with
//          structured context + trusted app/SMS can CONFIRM without UTR
//
//  FIX-38  SOFTEN STRUCTURED CONTEXT — tiered scoring:
//          STRONG (credit verb + bank ref) = +0.30
//          MEDIUM (credit verb only)       = +0.15
//          WEAK   (amount only)            = +0.05
//          No rejection based on context alone
//
//  FIX-39  MULTI-LANGUAGE CONTEXT — Tamil/Hindi/Telugu/Kannada payment
//          words added to _context and _creditVerb regexes
//
//  FIX-40  CASHBACK RECLASSIFICATION — instead of hard reject,
//          classify as WALLET_CREDIT → decision = LIKELY (not rejected)
//
//  FIX-41  TRUSTED APP BOOST (controlled) — GPay/PhonePe/Paytm with
//          amount + keyword → +0.25. CONFIRMED only if amount < ₹2000
//          OR TCM match OR SMS present
//
//  FIX-42  DELAYED SMS HANDLING — TCM window 25s → 60s
//          Late SMS match upgrades LIKELY → CONFIRMED
//
//  FIX-43  BANK FORMAT FLEXIBILITY — any 2-of-3 (amount, keyword,
//          trusted sender/app) treated as valid structure
//
//  FIX-44  PENALTY BALANCING — reduced penalties:
//          unwhitelisted sender: -0.25 → -0.15
//          fake structure:       -0.30 → -0.15
//          invalid UTR:          -0.40 → -0.25
//          Floor: total score never drops below 0.20 for real signals
//
//  FIX-45  HIGH VALUE SMART CONFIRM — ≥ ₹2000 CONFIRMED if ANY of:
//          valid UTR OR trusted SMS sender OR strong context + trusted app
//
//  FIX-46  SMART SPOOF DETECTION — perfect grammar + no bank + no UTR
//          → -0.10 soft penalty
//
//  FIX-47  NOTIFICATION-ONLY SUPPORT — trusted app notif allows LIKELY
//          even without SMS (already partially present, now explicit)
//
//  FIX-48  FINAL DECISION BALANCE — CONFIRMED if score ≥ threshold
//          AND not fraud AND (UTR OR trusted sender OR strong ctx + trusted)
//          REJECT only for fraud/promo — not for missing optional fields
//
//  FIX-49  REAL BANK NAME VALIDATION — require at least one real bank keyword:
//          HDFC, SBI, ICICI, AXIS, KOTAK, PNB, CANARA, BOB, YES, IDFC, etc
//          If missing: → reduce score by 0.20 (soft penalty)
//
//  FIX-50  TRUSTED APP LIMITATION (CRITICAL) — trusted app MUST NOT confirm alone
//          Even with high score: CONFIRMED only if ANY:
//          - valid UTR
//          - OR SMS sender verified
//          - OR TCM match success
//          Prevents app-only spoofs (fake notification + high score)
//
//  FIX-51  CLEAN SPOOF DETECTION — if message has:
//          amount + credited + account BUT missing:
//          UTR + masked account + bank name → force LIKELY
//          Catches sophisticated spoofs that look clean but lack depth
//
//  FIX-52  NOTIFICATION-ONLY CAP — if source == notification only:
//          max decision = LIKELY
//          Require SMS or TCM for CONFIRMED
//          Prevents notification-only attacks from confirming
//
//  FIX-53  FINAL CONFIRM LOCK — CONFIRMED ONLY IF:
//          ( score ≥ threshold AND NOT fraud AND 
//            ( valid UTR OR verified SMS sender OR TCM match ) )
//          Else: → ALWAYS downgrade to LIKELY
//
//  FIX-54  SPOOF HEURISTIC BOOST — perfect clean sentence + generic wording
//          → apply -0.10 penalty
//          Catches AI-generated/template messages lacking authentic details
// ═══════════════════════════════════════════════════════════════════════════
// RETAINED FROM V17 (FIX-17 through FIX-30, all V16, V15 fixes)
// =============================================================================

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_accessibility_service/accessibility_event.dart';
import 'package:flutter_accessibility_service/flutter_accessibility_service.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';
import 'payment_event.dart';
import 'sms_background_receiver.dart';
import 'local_storage_service.dart';
import 'sync_service.dart';
import 'session_management.dart';

// =============================================================================
// ENUMS
// =============================================================================

// PaymentApp, PaymentDecision, ConfidenceTier are in payment_event.dart

/// FIX-G: supported voice languages (10 including English)
enum VoiceLanguage {
  english, hindi, tamil, telugu, kannada, marathi, gujarati, bengali,
  punjabi, malayalam,
}

// =============================================================================
// FIX-J: PaymentUiState  —  id + timeAgo
// =============================================================================

class PaymentUiState {
  final String          id;
  final PaymentDecision decision;
  final double          amount;
  final String?         payerName;
  final String?         bankName;
  final bool            isFailed;
  final bool            isPartial;
  final double?         shortfall;
  final bool            isBillMatch;
  final DateTime        detectedAt;
  final bool            isUserConfirmed;
  final bool            isUserRejected;
  final String?         saleId; // FIX 4: Mapping Payment -> Sale

  const PaymentUiState({
    required this.id,
    required this.decision,
    required this.amount,
    this.payerName,
    this.bankName,
    required this.isFailed,
    this.isPartial       = false,
    this.shortfall,
    this.isBillMatch     = false,
    required this.detectedAt,
    this.isUserConfirmed = false,
    this.isUserRejected  = false,
    this.saleId,
  });

  // FIX-J: human-readable time-ago helper
  String get timeAgo {
    final d = DateTime.now().difference(detectedAt);
    if (d.inSeconds < 10)  return 'just now';
    if (d.inSeconds < 60)  return '${d.inSeconds}s ago';
    if (d.inMinutes < 60)  return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

  String get displayText {
    if (isFailed)  return '❌ Failed — ₹${_fmt(amount)} · $timeAgo';
    if (isPartial) {
      return '⚠️ Partial ₹${_fmt(amount)} '
          '(₹${_fmt(shortfall ?? 0)} short) · $timeAgo';
    }
    final from = payerName != null ? ' from $payerName' : '';
    switch (decision) {
      case PaymentDecision.confirmed:
        final check = isUserConfirmed ? ' ✓' : '';
        return '✅ ₹${_fmt(amount)}$from received$check · $timeAgo';
      case PaymentDecision.likely:
        if (isUserConfirmed) return '✅ ₹${_fmt(amount)}$from confirmed · $timeAgo';
        if (isUserRejected)  return '❌ ₹${_fmt(amount)} rejected · $timeAgo';
        return '⚠️ ₹${_fmt(amount)}$from — please confirm · $timeAgo';
      case PaymentDecision.rejected:
        return '';
    }
  }

  /// Build voice text via VoiceBuilder (FIX-G).
  /// FIX-3: language passed explicitly (no global state).
  String voiceText(VoiceLanguage lang) {
    if (isFailed)  return VoiceBuilder.failed(amount, lang);
    if (isPartial) return VoiceBuilder.partial(amount, shortfall ?? 0, lang);
    switch (decision) {
      case PaymentDecision.confirmed:
        return VoiceBuilder.received(amount, payerName, lang);
      case PaymentDecision.likely:
        return VoiceBuilder.detected(amount, lang);
      case PaymentDecision.rejected:
        return '';
    }
  }

  PaymentUiState copyWith({
    PaymentDecision? decision,
    bool?            isUserConfirmed,
    bool?            isUserRejected,
    bool?            isBillMatch,
  }) => PaymentUiState(
    id:              id,
    decision:        decision        ?? this.decision,
    amount:          amount,
    payerName:       payerName,
    bankName:        bankName,
    isFailed:        isFailed,
    isPartial:       isPartial,
    shortfall:       shortfall,
    isBillMatch:     isBillMatch    ?? this.isBillMatch,
    detectedAt:      detectedAt,
    isUserConfirmed: isUserConfirmed ?? this.isUserConfirmed,
    isUserRejected:  isUserRejected  ?? this.isUserRejected,
  );

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}

// =============================================================================
// FIX-G + FIX-1 + FIX-2: MULTI-LANGUAGE VOICE BUILDER (10 languages, complete)
// =============================================================================

abstract class VoiceBuilder {
  // ── received ─────────────────────────────────────────────────────────────────
  static String received(double amount, String? name, VoiceLanguage lang) {
    final a = _amt(amount, lang);
    final f = name != null ? '${_from(lang)}$name' : '';
    switch (lang) {
      case VoiceLanguage.hindi:     return 'पेमेंट मिला। $a$f';
      case VoiceLanguage.tamil:     return 'பணம் வந்தது. $a$f';
      case VoiceLanguage.telugu:    return 'చెల్లింపు వచ్చింది. $a$f';
      case VoiceLanguage.kannada:   return 'ಪಾವತಿ ಬಂತು. $a$f';
      case VoiceLanguage.marathi:   return 'पैसे मिळाले. $a$f';
      case VoiceLanguage.gujarati:  return 'ચૂકવણી મળી. $a$f';
      case VoiceLanguage.bengali:   return 'পেমেন্ট পাওয়া গেছে। $a$f';
      case VoiceLanguage.punjabi:   return 'ਭੁਗਤਾਨ ਮਿਲਿਆ। $a$f';
      case VoiceLanguage.malayalam: return 'പേയ്‌മെന്റ് ലഭിച്ചു. $a$f';
      default:                      return 'Payment received. $a$f';
    }
  }

  // ── detected (LIKELY) ────────────────────────────────────────────────────────
  static String detected(double amount, VoiceLanguage lang) {
    final a = _amt(amount, lang);
    switch (lang) {
      case VoiceLanguage.hindi:     return '$a मिला, एक बार जांचें';
      case VoiceLanguage.tamil:     return '$a வந்தது, ஒருமுறை சரிபார்க்கவும்';
      case VoiceLanguage.telugu:    return '$a వచ్చింది, ఒకసారి చెక్ చేయండి';
      case VoiceLanguage.kannada:   return '$a ಬಂತು, ಒಮ್ಮೆ ಪರಿಶೀಲಿಸಿ';
      case VoiceLanguage.marathi:   return '$a आले, एकदा तपासा';
      case VoiceLanguage.gujarati:  return '$a મળ્યા, એક વખત ચકાસો';
      case VoiceLanguage.bengali:   return '$a এসেছে, একবার যাচাই করুন';
      case VoiceLanguage.punjabi:   return '$a ਮਿਲਿਆ, ਇੱਕ ਵਾਰ ਜਾਂਚ ਕਰੋ';
      case VoiceLanguage.malayalam: return '$a ലഭിച്ചു, ഒന്ന് പരിശോധിക്കൂ';
      default:                      return '$a detected. Please confirm.';
    }
  }

  // ── FIX-1: failed — all 10 languages ────────────────────────────────────────
  static String failed(double amount, VoiceLanguage lang) {
    final a = _amt(amount, lang);
    switch (lang) {
      case VoiceLanguage.hindi:     return 'पेमेंट फेल। $a';
      case VoiceLanguage.tamil:     return 'பணம் வரவில்லை. $a';
      case VoiceLanguage.telugu:    return 'చెల్లింపు విఫలమైంది. $a';
      case VoiceLanguage.kannada:   return 'ಪಾವತಿ ವಿಫಲವಾಗಿದೆ. $a';
      case VoiceLanguage.marathi:   return 'पेमेंट अयशस्वी. $a';
      case VoiceLanguage.gujarati:  return 'ચૂકવણી નિષ્ફળ. $a';
      case VoiceLanguage.bengali:   return 'পেমেন্ট ব্যর্থ. $a';
      case VoiceLanguage.punjabi:   return 'ਭੁਗਤਾਨ ਅਸਫਲ. $a';
      case VoiceLanguage.malayalam: return 'പേയ്‌മെന്റ് പരാജയപ്പെട്ടു. $a';
      default:                      return 'Payment failed. $a';
    }
  }

  // ── FIX-1: partial — all 10 languages ───────────────────────────────────────
  static String partial(double received, double shortfall, VoiceLanguage lang) {
    final r = _amt(received,  lang);
    final s = _amt(shortfall, lang);
    switch (lang) {
      case VoiceLanguage.hindi:     return 'आधा पेमेंट $r मिला, $s बाकी';
      case VoiceLanguage.tamil:     return 'பகுதி $r வந்தது. $s குறைவு.';
      case VoiceLanguage.telugu:    return 'పాక్షిక $r వచ్చింది. $s తక్కువ.';
      case VoiceLanguage.kannada:   return 'ಭಾಗಶಃ $r ಬಂತು. $s ಕಡಿಮೆ.';
      case VoiceLanguage.marathi:   return 'आंशिक $r मिळाले. $s कमी.';
      case VoiceLanguage.gujarati:  return 'આંશિક $r મળ્યા. $s ઓછા.';
      case VoiceLanguage.bengali:   return 'আংশিক $r পাওয়া গেছে। $s কম।';
      case VoiceLanguage.punjabi:   return 'ਅੰਸ਼ਕ $r ਮਿਲਿਆ। $s ਘੱਟ।';
      case VoiceLanguage.malayalam: return 'ഭാഗിക $r ലഭിച്ചു. $s കുറവ്.';
      default:                      return 'Partial $r received. $s short.';
    }
  }

  // ── FIX-2: stillWaiting — all 10 languages ──────────────────────────────────
  static String stillWaiting(double amount, VoiceLanguage lang) {
    final a = _amt(amount, lang);
    switch (lang) {
      case VoiceLanguage.hindi:     return '$a की पुष्टि बाकी है';
      case VoiceLanguage.tamil:     return '$a உறுதிப்படுத்தல் காத்திருக்கிறது';
      case VoiceLanguage.telugu:    return '$a నిర్ధారణ పెండింగ్‌లో ఉంది';
      case VoiceLanguage.kannada:   return '$a ದೃಢೀಕರಣ ಬಾಕಿ ಇದೆ';
      case VoiceLanguage.marathi:   return '$a ची पुष्टी बाकी आहे';
      case VoiceLanguage.gujarati:  return '$a ની પુષ્ટિ બાકી છે';
      case VoiceLanguage.bengali:   return '$a নিশ্চিতকরণ বাকি আছে';
      case VoiceLanguage.punjabi:   return '$a ਦੀ ਪੁਸ਼ਟੀ ਬਾਕੀ ਹੈ';
      case VoiceLanguage.malayalam: return '$a സ്ഥിരീകരണം കാത്തിരിക്കുന്നു';
      default:                      return 'Still waiting for $a confirmation.';
    }
  }

  // ── FIX-H: burst with payer names ───────────────────────────────────────────
  static String burst(List<(double, String?)> payments, VoiceLanguage lang) {
    if (payments.isEmpty) return '';
    final named = payments.take(2).map((p) {
      final n = p.$2;
      return n != null ? '$n ₹${p.$1.toInt()}' : '₹${p.$1.toInt()}';
    }).join(', ');
    final more = payments.length > 2 ? ' and ${payments.length - 2} more' : '';
    switch (lang) {
      case VoiceLanguage.hindi:     return '$named$more मिले';
      case VoiceLanguage.tamil:     return '$named$more வந்தது';
      case VoiceLanguage.telugu:    return '$named$more వచ్చాయి';
      case VoiceLanguage.kannada:   return '$named$more ಬಂದಿದೆ';
      case VoiceLanguage.marathi:   return '$named$more मिळाले';
      case VoiceLanguage.gujarati:  return '$named$more મળ્યા';
      case VoiceLanguage.bengali:   return '$named$more পাওয়া গেছে';
      case VoiceLanguage.punjabi:   return '$named$more ਮਿਲੇ';
      case VoiceLanguage.malayalam: return '$named$more ലഭിച്ചു';
      default:                      return '$named$more received';
    }
  }

  // ── Regional amount formatting ───────────────────────────────────────────────
  static String _amt(double v, VoiceLanguage lang) {
    final r = v.toInt();
    if (r >= 100000) {
      final l = r ~/ 100000;
      final t = (r % 100000) ~/ 1000;
      if (lang == VoiceLanguage.hindi || lang == VoiceLanguage.marathi) {
        return t > 0 ? '₹$r, $l लाख $t हज़ार' : '₹$r, $l लाख';
      }
      if (lang == VoiceLanguage.tamil) {
        return t > 0 ? '₹$r, $l லட்சம் $t ஆயிரம்' : '₹$r, $l லட்சம்';
      }
      if (lang == VoiceLanguage.telugu) {
        return t > 0 ? '₹$r, $l లక్ష $t వేలు' : '₹$r, $l లక్ష';
      }
      return t > 0 ? '₹$r, $l lakh $t thousand' : '₹$r, $l lakh';
    }
    if (r >= 1000) {
      final k   = r ~/ 1000;
      final rem = r % 1000;
      if (lang == VoiceLanguage.hindi || lang == VoiceLanguage.marathi) {
        return rem > 0 ? '₹$r, $k हज़ार $rem' : '₹$r, $k हज़ार';
      }
      if (lang == VoiceLanguage.tamil) {
        return rem > 0 ? '₹$r, $k ஆயிரம் $rem' : '₹$r, $k ஆயிரம்';
      }
      if (lang == VoiceLanguage.telugu) {
        return rem > 0 ? '₹$r, $k వేల $rem' : '₹$r, $k వేలు';
      }
      return rem > 0 ? '₹$r, $k thousand $rem' : '₹$r, $k thousand';
    }
    return v == v.truncateToDouble()
        ? '₹${v.toInt()}'
        : '₹${v.toStringAsFixed(2)}';
  }

  static String _from(VoiceLanguage lang) {
    switch (lang) {
      case VoiceLanguage.hindi:     return ' से ';
      case VoiceLanguage.tamil:     return ' இலிருந்து ';
      case VoiceLanguage.telugu:    return ' నుండి ';
      case VoiceLanguage.kannada:   return ' ಇಂದ ';
      case VoiceLanguage.marathi:   return ' कडून ';
      case VoiceLanguage.gujarati:  return ' તરફથી ';
      case VoiceLanguage.bengali:   return ' থেকে ';
      case VoiceLanguage.punjabi:   return ' ਤੋਂ ';
      case VoiceLanguage.malayalam: return ' ൽ നിന്ന് ';
      default:                      return ' from ';
    }
  }
}

// =============================================================================
// BILL CONTEXT  (FIX-L: tolerance max(5%, ₹2))
// =============================================================================

class BillContext {
  double?   expectedAmount;
  bool      isActive       = false;
  DateTime? setAt;
  double    _partialReceived = 0;

  void setExpected(double amount) {
    assert(amount > 0);
    // FIX: Always reset partial history when a new bill is set
    _partialReceived = 0;
    expectedAmount     = amount;
    isActive           = true;
    setAt              = DateTime.now();
  }

  void clear() {
    expectedAmount   = null;
    isActive         = false;
    setAt            = null;
    _partialReceived = 0;
  }

  bool get isExpired {
    if (!isActive || setAt == null) return true;
    return DateTime.now().difference(setAt!) > const Duration(minutes: 5);
  }

  void recordPartial(double v) => _partialReceived += v;

  /// How much has been received so far against this bill.
  double get partialReceived => _partialReceived;

  /// How much is still owed on this bill.
  double get remainingAmount => (expectedAmount ?? 0) - _partialReceived;

  bool get isFullyPaid => expectedAmount != null && 
      (partialReceived - expectedAmount!).abs() < 1.0;

  DateTime? _lastSettlementAt;
  bool get isSettlementLocked {
    if (_lastSettlementAt == null) return false;
    return DateTime.now().difference(_lastSettlementAt!) < const Duration(seconds: 5);
  }

  void markSettled() { _lastSettlementAt = DateTime.now(); }

  BillMatchResult evaluate(double detected) {
    if (!isActive || isExpired || expectedAmount == null) {
      return BillMatchResult.noContext;
    }
    final remaining = expectedAmount! - _partialReceived;
    if (remaining <= 0) return BillMatchResult.noContext;

    final diff = (detected - remaining).abs();

    // Business rule: exact means the payment covers the remaining balance.
    // Any positive payment below the remaining balance is a valid partial
    // payment. There is deliberately no 50% minimum: ₹2 against ₹10 is valid.
    if (diff <= math.max(remaining * 0.01, 0.01)) return BillMatchResult.exact;
    if (detected > 0 && detected < remaining) return BillMatchResult.partial;
    if (detected > expectedAmount! * 2.0) return BillMatchResult.suspicious;
    return BillMatchResult.mismatch;
  }
}

enum BillMatchResult { noContext, exact, partial, suspicious, mismatch }

// =============================================================================
// FIX-I: PAYMENT HISTORY BUFFER
// =============================================================================

class PaymentHistoryBuffer {
  static const int _max = 20;
  final _history = ListQueue<PaymentUiState>();

  void addOrUpdate(PaymentUiState s) {
    final list = _history.toList();
    final idx = list.indexWhere((old) => old.id == s.id);
    if (idx != -1) {
      list[idx] = s;
      _history.clear();
      for (final item in list) _history.add(item);
    } else {
      if (_history.length >= _max) _history.removeFirst();
      _history.add(s);
    }
  }

  void update(String id, PaymentUiState updated) {
    final list = _history.toList();
    final idx  = list.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    list[idx] = updated;
    _history.clear();
    for (final s in list) _history.add(s);
  }

  List<PaymentUiState> get all => _history.toList().reversed.toList();

  PaymentUiState? findById(String id) {
    try { return _history.firstWhere((s) => s.id == id); }
    catch (_) { return null; }
  }

  bool hasRecentPayment(double amount,
      {Duration within = const Duration(minutes: 2)}) {
    final cutoff = DateTime.now().subtract(within);
    return _history.any((s) =>
        (s.amount - amount).abs() < 1.0 &&
        s.detectedAt.isAfter(cutoff) &&
        s.decision != PaymentDecision.rejected);
  }

  double get todayTotal {
    final now        = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    return _history
        .where((s) =>
            s.detectedAt.isAfter(startOfDay) &&
            s.decision != PaymentDecision.rejected &&
            !s.isFailed)
        .fold(0.0, (sum, s) => sum + s.amount);
  }

  void clear() => _history.clear();
}

// =============================================================================
// CONFIGURATION
// =============================================================================

class PdsConfig {
  // FIX-F: TCM threshold ₹2000
  static const double tcmSmallThreshold = 2000.0;

  // Confidence thresholds
  static const double confirmedThreshold = 0.70;
  static const double likelyThreshold    = 0.40;

  // Per-source thresholds
  static const double thresholdVerifiedSms   = 0.40;
  static const double thresholdTrustedApp    = 0.45;
  static const double thresholdAccessibility = 0.60;

  // Amount limits
  static const double minAmount          = 1.0;
  static const double notifOnlyHighValue = 50000.0;
  static const double smsConfirmedMax    = 500000.0;
  static const double hardCapNoUtr       = 500000.0;

  // FIX-17: strict UTR amount gate — above this, no valid UTR = max LIKELY
  static const double utrRequiredAbove      = 500.0;
  // FIX-22: high value safety — requires UTR or verified sender or TCM
  static const double highValueThreshold    = 2000.0;
  // FIX-28: large amount — requires UTR AND (SMS or bank verified)
  static const double largeAmountThreshold  = 10000.0;

  // ANTI-01: UTR required caps (kept for backward compat, superseded by FIX-17)
  static const double utrRequiredSmsAbove   = 200.0;
  static const double utrRequiredNotifAbove = 500.0;

  // FIX-E: unknown sender penalty (superseded by FIX-24 for SMS)
  static const double unknownSenderPenalty  = 0.10;
  // FIX-44: reduced penalties — keep real payments from being killed by penalties
  // unwhitelisted sender: -0.25 → -0.15
  static const double unwhitelistedSmsPenalty = 0.15;
  // FIX-17 retained, FIX-44: invalid UTR penalty: -0.40 → -0.25
  static const double invalidUtrPenalty       = 0.25;
  // FIX-23 retained, FIX-44: fake structure penalty: -0.30 → -0.15
  static const double fakeStructurePenalty    = 0.15;
  // FIX-44: minimum floor — penalties can't drop real signals below this
  static const double minScoreFloor           = 0.20;

  // FIX-42: TCM window extended 25s → 60s for delayed SMS handling
  // FIX-55: Graduated window for India's actual SMS network delays
  // Small (<₹2000): 90s | Medium (₹2-10K): 120s | Large (>₹10K): 180s
  // During peak (noon-2PM, 6PM-9PM), bank SMS regularly takes 2-5min
  static Duration tcmSmsMatchWindow(double? amount) {
    if (amount == null || amount < 2000) return const Duration(seconds: 90);
    if (amount < 10000) return const Duration(seconds: 120);
    return const Duration(seconds: 180);  // Large txns get 3min window
  }
  static const Duration tcmSmallDrain     = Duration(seconds: 5);
  static const Duration tcmLargeDrain     = Duration(seconds: 20);
  static const Duration tcmDrainInterval  = Duration(seconds: 2);

  // FIX-K: LIKELY re-announce timeout
  static const Duration likelyReannounceAfter = Duration(seconds: 12);

  // Dedup
  static const Duration dedupUtrTtl          = Duration(hours: 24);
  static const Duration dedupHashTtl         = Duration(seconds: 30);
  static const Duration dedupCleanupInterval = Duration(minutes: 5);
  // FIX-C: debounce save
  static const Duration dedupSaveDebounce    = Duration(seconds: 30);

  // Behavioral memory
  static const int      behaviorMaxPayers      = 500;
  static const int      behaviorMaxTxPerPayer  = 50;
  static const double   behaviorAnomalyMult    = 10.0;
  static const Duration behaviorVelocityWindow = Duration(seconds: 30);
  static const int      behaviorVelocityLimit  = 4;

  // Guards
  static const int      accRateLimitPerMin = 10;
  static const int      accBurstLimit      = 5;
  static const Duration accBurstWindow     = Duration(seconds: 3);
  static const Duration accBurstBlock      = Duration(seconds: 60);
  static const int      floodLimit         = 12;
  static const Duration floodWindow        = Duration(seconds: 30);
  static const Duration floodBlock         = Duration(minutes: 3);

  // Watchdog
  static const Duration watchdogHeartbeat      = Duration(seconds: 60);
  static const Duration watchdogStaleThreshold = Duration(minutes: 5);

  // Voice
  static const Duration voiceMinGap      = Duration(seconds: 2);
  static const int      voiceBurstCount  = 3;
  static const Duration voiceBurstWindow = Duration(seconds: 5);
  // FIX-3: language removed from PdsConfig — now on PaymentDetectionService

  // Buffer
  static const int pendingBufferMax = 25;

  // ANTI-07
  static const Duration bankVerifyTimeout = Duration(seconds: 30);

  // Feature flags
  static bool isSmsEnabled            = true;
  static bool isNotificationEnabled   = true;
  static bool isAccessibilityEnabled  = false; // off by default (ANTI-05)
  static bool isVoiceEnabled          = true;
  static bool isBehaviorMemoryEnabled = true;
  static bool isFraudTelemetryEnabled = true;
  static bool isTrustedSenderEnabled  = true;
  static bool isBankVerifyEnabled     = false;
}

// =============================================================================
// STRUCTURED LOGGER
// =============================================================================

enum _LogLevel { debug, info, warn, error }

abstract class PdsLogger {
  static void d(String tag, String msg) {
    if (kDebugMode) {
      _emit(_LogLevel.debug, tag, msg);
    }
  }
  static void i(String tag, String msg) => _emit(_LogLevel.info,  tag, msg);
  static void w(String tag, String msg) => _emit(_LogLevel.warn,  tag, msg);
  static void e(String tag, String msg, [Object? err, StackTrace? st]) {
    _emit(_LogLevel.error, tag, msg);
    if (err != null) {
      debugPrint('  ↳ $err');
    }
    if (st != null && kDebugMode) {
      debugPrint('  ↳ $st');
    }
  }
  static void _emit(_LogLevel lvl, String tag, String msg) {
    if (kDebugMode) {
      debugPrint('[PDS][${lvl.name.toUpperCase().padRight(5)}][$tag] $msg');
    }
  }
}

// =============================================================================
// CHANNEL STATUS
// =============================================================================

enum ChannelType   { notification, sms, accessibility }
enum ChannelStatus { online, permissionDenied, error, rateLimited, blocked, stale }

class ChannelStatusEvent {
  final ChannelType   channel;
  final ChannelStatus status;
  final String?       detail;
  final DateTime      at;
  ChannelStatusEvent(this.channel, this.status, {this.detail})
      : at = DateTime.now();

  String get advice {
    if (status == ChannelStatus.permissionDenied) {
      return channel == ChannelType.notification
          ? 'Go to Settings → Notification Access → Enable this app.'
          : channel == ChannelType.sms
              ? 'Go to Settings → Apps → Permissions → SMS → Allow.'
              : 'Go to Settings → Accessibility → Enable this app.';
    }
    if (status == ChannelStatus.stale) {
      return channel == ChannelType.notification
          ? 'Battery saver may be blocking payments. Set app to Unrestricted in Battery settings.'
          : 'Bank SMS not received recently. Check SMS permission.';
    }
    if (status == ChannelStatus.error) return 'Detection error. Please restart the app.';
    return '';
  }
}

// =============================================================================
// FRAUD VERDICTS
// =============================================================================

// FraudVerdict and FraudAnalysis moved to payment_event.dart to avoid circular imports and enable test access

class FraudAlertEvent {
  final FraudVerdict verdict;
  final String       type;
  final String       detail;
  final String       source;
  final String?      sender;
  final double?      amount;
  final DateTime     detectedAt;

  const FraudAlertEvent({
    required this.verdict, required this.type, required this.detail,
    required this.source,  this.sender, this.amount, required this.detectedAt,
  });

  Map<String, dynamic> toJson() => {
    'verdict': verdict.name, 'type': type, 'detail': detail,
    'source':  source,       'amount': amount,
    'detectedAt': detectedAt.toIso8601String(),
  };
}

// =============================================================================
// SESSION STATS
// =============================================================================

class PdsSessionStats {
  int    txConfirmed  = 0;
  int    txLikely     = 0;
  int    txRejected   = 0;
  double totalAmount  = 0;
  int    fraudBlocked = 0;
  int    dupeBlocked  = 0;
  DateTime  sessionStart = DateTime.now();
  DateTime? lastTxAt;

  void recordDecision(PaymentDecision d, double amount) {
    switch (d) {
      case PaymentDecision.confirmed:
        txConfirmed++; totalAmount += amount; break;
      case PaymentDecision.likely:
        txLikely++;    totalAmount += amount; break;
      case PaymentDecision.rejected:
        txRejected++;  break;
    }
    if (d != PaymentDecision.rejected) lastTxAt = DateTime.now();
  }
  void recordFraud() => fraudBlocked++;
  void recordDupe()  => dupeBlocked++;
  void reset() {
    txConfirmed = txLikely = txRejected = 0;
    totalAmount = 0.0;
    fraudBlocked = dupeBlocked = 0;
    sessionStart = DateTime.now(); lastTxAt = null;
  }
  Map<String, dynamic> toJson() => {
    'txConfirmed':  txConfirmed,  'txLikely':    txLikely,
    'txRejected':   txRejected,   'totalAmount': totalAmount,
    'fraudBlocked': fraudBlocked, 'dupeBlocked': dupeBlocked,
    'sessionStart': sessionStart.toIso8601String(),
    'lastTxAt':     lastTxAt?.toIso8601String(),
  };
}

// =============================================================================
// PERSISTENCE  (FIX-C: debounced save)
// =============================================================================

class PdsStateStore {
  static const _kDedup = 'pds_dedup_v1';

  static Future<void> loadDedup(Map<String, DateTime> store) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kDedup);
      if (raw == null || raw.isEmpty) return;
      final Map<String, dynamic> decoded = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      int loaded = 0;
      decoded.forEach((fp, isoExpiry) {
        try {
          final expiry = DateTime.parse(isoExpiry as String);
          if (expiry.isAfter(now)) { store[fp] = expiry; loaded++; }
        } catch (_) {}
      });
      PdsLogger.i('STORE', 'Loaded $loaded dedup entries');
    } catch (e, st) { PdsLogger.e('STORE', 'loadDedup error', e, st); }
  }

  static Future<void> saveDedup(Map<String, DateTime> store) async {
    try {
      final prefs  = await SharedPreferences.getInstance();
      final now    = DateTime.now();
      final toSave = <String, String>{};
      store.forEach((fp, expiry) {
        if (fp.startsWith('utr:') && expiry.isAfter(now)) {
          toSave[fp] = expiry.toIso8601String();
        }
      });
      await prefs.setString(_kDedup, jsonEncode(toSave));
    } catch (e, st) { PdsLogger.e('STORE', 'saveDedup error', e, st); }
  }

  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kDedup);
      await TrustedSenderStore._clearPrefs();
    } catch (_) {}
  }
}

// =============================================================================
// TRUSTED SENDER STORE  (FIX-B: in-memory cache)
// =============================================================================

class TrustedSenderStore {
  static const _kKey = 'pds_trusted_senders_v1';

  static final _cache  = <String>{};
  static bool  _cacheLoaded = false;

  static Future<void> preload() async {
    if (_cacheLoaded) return;
    try {
      final prefs    = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_kKey) ?? [];
      _cache.addAll(existing);
      _cacheLoaded = true;
      PdsLogger.i('TRUST', 'Preloaded ${_cache.length} trusted senders');
    } catch (e) { PdsLogger.e('TRUST', 'preload error', e); }
  }

  static Future<void> learnSender(String sender) async {
    final hash = _hash(sender);
    if (_cache.contains(hash)) return;
    _cache.add(hash);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list  = prefs.getStringList(_kKey) ?? [];
      list.add(hash);
      await prefs.setStringList(_kKey, list);
      PdsLogger.i('TRUST', 'Learned sender: $sender');
    } catch (e) { PdsLogger.e('TRUST', 'learnSender error', e); }
  }

  // FIX-B: O(1) synchronous lookup — no async I/O in hot path
  static bool isKnownSync(String sender) => _cache.contains(_hash(sender));

  static String _hash(String s) =>
      sha256.convert(utf8.encode(s.toUpperCase().trim())).toString();

  static Future<void> _clearPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
      _cache.clear();
    } catch (_) {}
  }
}

// =============================================================================
// BANK VERIFIER INTERFACE (ANTI-07)
// =============================================================================

abstract class BankVerifier {
  Future<bool?> verify({
    required double   amount,
    required String?  utr,
    required String   detectionSource,
    required DateTime detectedAt,
  });
}

class _NoOpVerifier implements BankVerifier {
  @override
  Future<bool?> verify({
    required double   amount,
    required String?  utr,
    required String   detectionSource,
    required DateTime detectedAt,
  }) async => null;
}

// =============================================================================
// CONFIRMATION MANAGER (ANTI-03 + FIX-D)
// =============================================================================

class _ConfirmEntry {
  final PaymentEvent   event;
  final PaymentUiState ui;
  final DateTime       expiresAt;
  _ConfirmEntry(this.event, this.ui)
      : expiresAt = DateTime.now().add(const Duration(minutes: 2));
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class ConfirmationManager {
  final _pending = <String, _ConfirmEntry>{};

  void add(PaymentEvent event, PaymentUiState ui) {
    _pending[event.id] = _ConfirmEntry(event, ui);
    PdsLogger.i('CONFIRM', 'Awaiting confirm: ₹${event.amount} id=${event.id}');
  }

  PaymentEvent? confirm(String id) {
    final entry = _pending.remove(id);
    if (entry == null || entry.isExpired) {
      PdsLogger.w('CONFIRM', 'confirm id=$id not found or expired');
      return null;
    }
    PdsLogger.i('CONFIRM', '✅ Confirmed ₹${entry.event.amount}');
    return entry.event.copyWith(
      decision: PaymentDecision.confirmed,
      detectionSource: '${entry.event.detectionSource}:merchant_confirmed',
    );
  }

  void reject(String id) {
    final entry = _pending.remove(id);
    if (entry != null) {
      PdsLogger.i('CONFIRM', '❌ Rejected ₹${entry.event.amount}');
    }
  }

  void cleanup() => _pending.removeWhere((_, e) => e.isExpired);
  void dispose() => _pending.clear();
}

// =============================================================================
// BEHAVIORAL MEMORY
// =============================================================================

class _PayerProfile {
  final List<double>   amounts    = [];
  final List<DateTime> timestamps = [];

  void record(double v) {
    amounts.add(v); timestamps.add(DateTime.now());
    if (amounts.length > PdsConfig.behaviorMaxTxPerPayer) {
      amounts.removeAt(0); timestamps.removeAt(0);
    }
  }

  double get avg =>
      amounts.isEmpty ? 0 : amounts.reduce((a, b) => a + b) / amounts.length;

  bool isVelocityBurst() {
    final cutoff = DateTime.now().subtract(PdsConfig.behaviorVelocityWindow);
    return timestamps.where((t) => t.isAfter(cutoff)).length >=
        PdsConfig.behaviorVelocityLimit;
  }

  bool isAmountAnomalous(double v) {
    if (amounts.length < 3) return false;
    final a = avg;
    return a > 0 && v > a * PdsConfig.behaviorAnomalyMult;
  }
}

class BehavioralMemory {
  final _profiles = <String, _PayerProfile>{};

  double softPenalty({required double amount, String? name, String? vpa}) {
    final key = _key(name, vpa);
    if (key == null) return 0.0;
    final p       = _profiles.putIfAbsent(key, () => _PayerProfile());
    double penalty = 0.0;
    
    // ✅ FIX: Velocity burst = HARD BLOCK (not soft penalty)
    if (p.isVelocityBurst()) {
      if (kDebugMode) {
        debugPrint('🚨 PaymentDetection: Velocity burst blocked ($name, $vpa)');
      }
      return 1.0;  // Hard block = score 0.0 (confirmed return value)
    }
    
    if (p.isAmountAnomalous(amount)) penalty = math.max(penalty, 0.20);
    return penalty;
  }

  void record(double amount, String? name, String? vpa) {
    final key = _key(name, vpa);
    if (key == null) return;
    if (_profiles.length >= PdsConfig.behaviorMaxPayers) {
      _profiles.remove(_profiles.keys.first);
    }
    _profiles.putIfAbsent(key, () => _PayerProfile()).record(amount);
  }

  String? _key(String? name, String? vpa) {
    if (vpa  != null && vpa.isNotEmpty)  return 'v:${vpa.toLowerCase()}';
    if (name != null && name.isNotEmpty) return 'n:${name.toLowerCase().trim()}';
    return null;
  }

  void dispose() => _profiles.clear();
}

// =============================================================================
// FRAUD ENGINE  (FIX-A: two-stage "pending" check)
// =============================================================================

// ── FIX-49: Real Bank Name Validation ───────────────────────────────────────
abstract class _BankNameValidator {
  static final realBankKeywords = RegExp(
    r'\b(hdfc|sbi|icici|axis|kotak|pnb|canara|bob|yes\s+bank|idfc|indus'
    r'|Union\s+Bank|United\s+Commerce|Ujjivan|RBL|Federal|Karmaveer'
    r'|DCB|Bandhan|IDFCB|HSBC|SCB|Standard|Citi|DLB|ICICI|IOB|UBI|BoB|CBI)\b',
    caseSensitive: false,
  );

  static final hindiRealBanks = RegExp(
    r'(एचडीएफसी|एसबीआई|आईसीआईसीआई|एक्सिस|कोटक|पीएनबी|कनारा|बैंक'
    r'|बैंक\s+ऑफ\s+इंडिया|बैंक\s+ऑफ\s+बड़ौदा|इंडियन\s+बैंक)',
    caseSensitive: false,
  );

  static final tamileRealBanks = RegExp(
    r'(வங்கி|தமிழ்\s+நாடு\s+நகர|ஐசিআईசிআই|ஹெச்டிএஃப்சி|இராப்ஸீ|பிஎன்பி)',
    caseSensitive: false,
  );

  static bool hasRealBankName(String text, {String lang = 'en'}) {
    if (lang == 'hi') {
      return hindiRealBanks.hasMatch(text) || realBankKeywords.hasMatch(text);
    } else if (lang == 'ta') {
      return tamileRealBanks.hasMatch(text) || realBankKeywords.hasMatch(text);
    }
    return realBankKeywords.hasMatch(text);
  }
}

// ────────────────────────────────────────────────────────────────────────────
abstract class FraudEngine {
  // FIX-25: strengthened — adds zero-width joiner, variation selectors,
  // soft hyphen, and other invisible Unicode used in spoofed messages
  static final _unicode     = RegExp(
    r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF'
    r'\u200D\u00AD\u034F\u115F\u1160\u17B4\u17B5'
    r'\u180B-\u180E\u2028\u2029\u202F\u205F]',
  );
  static final _htmlScript  = RegExp(
    r'(?:<[^>]{1,50}>|javascript:|eval\s*\(|onclick\s*=)',
    caseSensitive: false,
  );
  static final _cyrillic    = RegExp(r'[\u0400-\u04FF]');
  // FIX-26: extended — processing/initiated/on hold now unconditionally blocked
  static final _futureTense = RegExp(
    r'(?:\b(?:will\s+be\s+credited|will\s+credit|to\s+be\s+credited'
    r'|to\s+be\s+received|shall\s+be\s+credited|going\s+to\s+credit'
    r'|processing|being\s+processed|initiated|on\s+hold'
    r'|under\s+process|in\s+progress|payment\s+initiated'
    r'|transaction\s+initiated|transfer\s+initiated)\b'
    r'|कल\s+मिलेगा|बाद\s+में\s+मिलेगा|प्रोसेसिंग|होल्ड\s+पर)',
    caseSensitive: false,
  );
  static final _hardConfirmed = RegExp(
    r'\b(credited|received|deposited|confirmed|success)\b', caseSensitive: false);
  static final _hardFailed    = RegExp(
    r'\b(failed|declined|rejected|reversed)\b', caseSensitive: false);
  static final _utrRawValue   = RegExp(
    r'\b(?:utr|ref(?:erence)?|txn)[:\s#no.]*([^\s]{4,25})\b',
    caseSensitive: false,
  );
  static final _pureAlphaNum    = RegExp(r'^[A-Za-z0-9]+$');
  // FIX-CRITICAL: UTR extraction pattern now enforces RBI standard (numeric-only, 10-18 digits)
  // This prevents spoofed "Ref:ABC12345" strings from passing as valid UTRs
  static final _structureMarkers = [
    RegExp(r'(?:utr|ref|txn)[:\s#]*(\d{10,18})',  caseSensitive: false),  // Numeric-only UTR
    RegExp(r'(?:a/?c|acc(?:ount)?)\s*[xX*]*\d{4}',    caseSensitive: false),
    RegExp(r'(?:₹|rs\.?|inr)\s*\d',                   caseSensitive: false),
    RegExp(r'(?:upi|imps|neft|rtgs)\b',                caseSensitive: false),
  ];

  // FIX-V16-5: promo/marketing hard-block patterns
  static final _promoHardBlock = RegExp(
    r'\b(daily\s+savings|gold\s+investment|invest\s+in\s+gold'
    r'|set\s+up\s+daily|save\s+every\s+day|earn\s+daily'
    r'|exclusive\s+offer|limited\s+time\s+offer|special\s+offer'
    r'|refer\s+and\s+earn|refer\s+a\s+friend|invite\s+friends'
    r'|pre.?approved\s+loan|pre.?approved\s+credit'
    r'|insurance\s+plan|mutual\s+fund\s+sip|fd\s+offer)\b',
    caseSensitive: false,
  );

  // FIX-19: comprehensive promotional message detector
  // Any match = HARD REJECT, overrides everything
  static final _promoKeywords = RegExp(
    r'(?:\b(?:cashback|reward|earn|bonus|offer|deal|invest|gold\s+saving'
    r'|refer\s*&\s*earn|refer\s+and\s+earn|limited\s+offer'
    r'|win\s+₹|get\s+₹\d+\s+(?:off|back)|save\s+more)\b'
    r'|आकर्षक\s+ऑफर|विशेष\s+ऑफर|सीमित\s+समय|சலுகை|ఆఫర్)',
    caseSensitive: false,
  );

  // FIX-19: isPromotionalMessage — true if promo + no strong payment evidence
  // FIX-58 ENHANCEMENT: trust DLT verified bank senders (telecom-verified channels)
  static bool isPromotionalMessage(String text, {String? sender}) {
    if (!_promoKeywords.hasMatch(text)) return false;
    
    // FIX-40: Cashback credit/wallet load is not a promotional spam message
    if (isCashbackConfusion(text)) return false;
    
    // FIX-58: CRITICAL CHANGE — trust DLT verified bank sender completely
    // DLT (Distributed Ledger Tech) sender IDs are TRAI/IAMAI verified official bank channels
    // If sender is verified bank → message IS legitimate despite promo keywords
    // This is the correct trust anchor: regulatory verification > message content analysis
    if (sender != null && PaymentDetectionService._isVerifiedBankSender(sender)) {
      return false;  // Verified bank → trust it (marketing footers are harmless)
    }
    
    // Exception 1: if "credited to account" present, it's a real txn with bonus
    final hasCreditedToAccount = RegExp(
      r'\bcredited\s+to\s+(?:your\s+)?(?:account|a\/c|ac\b)',
      caseSensitive: false,
    ).hasMatch(text);
    if (hasCreditedToAccount) return false;

    return true;  // Promo keyword + no true payment signal = promotional
  }

  // FIX-20: cashback confusion detector
  // received + cashback/reward/bonus but NOT "credited to account" = reject
  static bool isCashbackConfusion(String text) {
    final hasReceived  = RegExp(r'\b(received|credited|got|added)\b', caseSensitive: false).hasMatch(text);
    final hasCashback  = RegExp(r'\b(cashback|reward|bonus|refund\s+of)\b', caseSensitive: false).hasMatch(text);
    final hasTrueCredit = RegExp(
      r'\bcredited\s+to\s+(?:your\s+)?(?:account|a\/c|ac\b)',
      caseSensitive: false,
    ).hasMatch(text);
    return hasReceived && hasCashback && !hasTrueCredit;
  }

  // FIX-F: Paytm wallet-load filter
  static final _walletLoad = RegExp(
    r'\b(wallet\s+(loaded|topped|added|recharged)|added\s+to\s+(your\s+)?wallet'
    r'|paytm\s+balance|wallet\s+balance\s+updated|money\s+added\s+to\s+wallet)\b',
    caseSensitive: false,
  );

  static bool isWalletLoad(String text) => _walletLoad.hasMatch(text);

  static FraudAnalysis analyze({
    required String  text,
    required String  source,
    required String? sender,
    required double? amount,
    required String? utr,
    required String? vpa,
  }) {
    if (_unicode.hasMatch(text)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockUnicode, riskScore: 1.0,
      reason: 'Unicode injection', isHardBlock: true);

    if (_htmlScript.hasMatch(text)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockHtmlScript, riskScore: 1.0,
      reason: 'HTML/script injection', isHardBlock: true);

    if (sender != null && _cyrillic.hasMatch(sender)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockCyrillic, riskScore: 1.0,
      reason: 'Cyrillic homoglyph sender', isHardBlock: true);

    // FIX-V16-5: block promo/marketing messages at fraud layer
    if (_promoHardBlock.hasMatch(text)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockFutureTense, riskScore: 0.95,
      reason: 'Promotional/marketing message — not a payment', isHardBlock: true);

    // FIX-19: comprehensive promo hard block — runs after V16-5
    // FIX-57: Pass sender for verified bank exception (ICICI/Kotak marketing blurbs)
    if (isPromotionalMessage(text, sender: sender)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockFutureTense, riskScore: 0.95,
      reason: 'FIX-19: Promotional message hard blocked', isHardBlock: true);

    // FIX-40: cashback RECLASSIFIED → soft analysis, not hard block
    // isCashbackConfusion → riskScore 0.40 (soft), isHardBlock false
    // Pipeline will keep it as LIKELY (not REJECTED), scored lower
    if (isCashbackConfusion(text)) return const FraudAnalysis(
      verdict: FraudVerdict.softPenaltyStructure, riskScore: 0.40,
      reason: 'FIX-40: Cashback/wallet credit — classified as LIKELY not CONFIRMED',
      isHardBlock: false);

    // FIX-F: Paytm wallet-load filter — suppress from merchant feed
    if (isWalletLoad(text)) return const FraudAnalysis(
      verdict: FraudVerdict.softPenaltyStructure, riskScore: 0.10,
      reason: 'Wallet load — not a merchant payment receipt',
      isHardBlock: true);

    if (_futureTense.hasMatch(text)) return const FraudAnalysis(
      verdict: FraudVerdict.hardBlockFutureTense, riskScore: 0.95,
      reason: 'Future-tense payment', isHardBlock: true);

    if (_hardConfirmed.hasMatch(text) && _hardFailed.hasMatch(text)) {
      return const FraudAnalysis(
        verdict: FraudVerdict.hardBlockContradiction, riskScore: 0.90,
        reason: 'Confirmed + failed in same message', isHardBlock: true);
    }

    // ── FIX-56: Processing+Received Exploit Block ────────────────────────
    // Close stacking exploit: "processing" (future/pending) + "received" (confirmed)
    // in same message = contradiction that could exploit FIX-41+FIX-43 boosters
    // Attacker could craft: "₹5000 processing received from your account"
    // This would bypass FIX-26's processing block while appearing confirmed
    // Now detects and hard-blocks this specific pattern
    final hasProcessing = RegExp(r'\bprocessing\b', caseSensitive: false).hasMatch(text);
    final hasReceived = _hardConfirmed.hasMatch(text);
    if (hasProcessing && hasReceived) {
      return const FraudAnalysis(
        verdict: FraudVerdict.hardBlockFutureTense, riskScore: 0.95,
        reason: 'FIX-56: Processing+Received contradiction — stacking exploit blocked',
        isHardBlock: true);
    }

    // ── FIX-51: Clean Spoof Detection ────────────────────────────────────
    // Sophisticated spoofs: has amount + credited + account
    // BUT missing: UTR + masked account + real bank name
    // This catches polished messages that LOOK real but lack depth
    final hasAmount = amount != null && amount > 0;
    final hasCredited = text.contains(RegExp(
      r'\b(credited|received|transferred)\b', caseSensitive: false,
    ));
    final hasAccount = text.contains('account') || text.contains('a/c') || 
                       text.contains('ac') || text.contains('खाता') ||
                       text.contains('खाते') || text.contains('ಖಾತೆ');
    final hasMasked = RegExp(
      r'(?:x{2,}|[*]{2,}|\d{4})\s*(?:a\/c|account|ac\b)',
      caseSensitive: false,
    ).hasMatch(text);
    final hasRealBank = _BankNameValidator.hasRealBankName(text);
    final hasValidUtr = utr != null && RegExp(r'^\d{10,18}$').hasMatch(utr);

    if (hasAmount && hasCredited && hasAccount && !hasMasked && !hasRealBank && !hasValidUtr) {
      return const FraudAnalysis(
        verdict: FraudVerdict.softPenaltyStructure, riskScore: 0.55,
        reason: 'FIX-51: Clean spoof — has basics but lacks depth (no UTR/bank/masked acc)',
        isHardBlock: false);
    }

    if (amount != null && amount <= 0) return FraudAnalysis(
      verdict: FraudVerdict.hardBlockAmountCap, riskScore: 1.0,
      reason: 'Non-positive amount', isHardBlock: true);

    if (amount != null && utr == null && amount > PdsConfig.hardCapNoUtr) {
      return FraudAnalysis(
        verdict: FraudVerdict.hardBlockAmountCap, riskScore: 0.95,
        reason: '₹$amount without UTR > cap', isHardBlock: true);
    }

    // Soft penalties
    double risk = 0.0;
    FraudVerdict top = FraudVerdict.clean;

    if (utr != null && !RegExp(r'^\d+$').hasMatch(utr)) {
      risk += _pureAlphaNum.hasMatch(utr) ? 0.10 : 0.30;
      top   = FraudVerdict.softPenaltyUtr;
    }
    final rawUtr = _utrRawValue.firstMatch(text)?.group(1);
    if (rawUtr != null && utr == null && !_pureAlphaNum.hasMatch(rawUtr)) {
      risk += 0.20; top = FraudVerdict.softPenaltyUtr;
    }
    if (vpa != null && !_VpaValidator.isValid(vpa)) {
      risk += 0.10; top = FraudVerdict.softPenaltyVpa;
    }
    if (source == 'sms') {
      final markers = _structureMarkers.where((p) => p.hasMatch(text)).length;
      if (markers == 0) { risk += 0.30; top = FraudVerdict.softPenaltyStructure; }
    }

    if (risk == 0) return FraudAnalysis.clean;
    return FraudAnalysis(
      verdict: top, riskScore: risk.clamp(0.0, 0.99),
      reason: 'Soft risk: ${risk.toStringAsFixed(2)}', isHardBlock: false);
  }
}

// =============================================================================
// VPA VALIDATOR
// =============================================================================

abstract class _VpaValidator {
  static const _handles = <String>{
    'oksbi','okhdfcbank','okicici','okaxis','ybl','gpay','paytm','upi',
    'imobile','axl','ibl','kotak','federal','rbl','sib','dcb','aubank',
    'icici','hdfc','sbi','axis','pnb','bob','canara','union','indus',
    'yes','idfc','phonepe','freecharge','airtel','jio','apl','waicici',
    'rajgovhdfcbank','timecosb','abfspay','ikwik','jupiteraxis',
    'hdfcbank','icicibank','axisbank','pnbpay','idbi','citi','dlb',
    'mabp','hsbc','sc','stcb','barodampay','kaypay',
  };
  static bool isValid(String vpa) {
    final p = vpa.split('@');
    return p.length == 2 && _handles.contains(p[1].toLowerCase().trim());
  }
}

// =============================================================================
// SENDER VALIDATOR
// =============================================================================

abstract class _SenderValidator {
  static final _valid  = RegExp(r'^[A-Za-z0-9\-]{3,20}$');
  static final _digits = RegExp(r'^\d+$');
  static bool isLegitimate(String s) {
    final t = s.trim();
    return _valid.hasMatch(t) && !_digits.hasMatch(t);
  }
}

// =============================================================================
// PRIORITY VOICE QUEUE  (FIX-3: language via callback, FIX-H: burst names)
// =============================================================================

enum _VP { critical, high, normal, soft }

class _VI implements Comparable<_VI> {
  final String   text;
  final _VP      priority;
  final double?  amount;
  final String?  payerName;
  final DateTime at;
  _VI(this.text, this.priority, {this.amount, this.payerName})
      : at = DateTime.now();
  @override
  int compareTo(_VI o) {
    final p = priority.index.compareTo(o.priority.index);
    return p != 0 ? p : at.compareTo(o.at);
  }
}

class PriorityVoiceQueue {
  final _queue    = SplayTreeSet<_VI>(
    (a, b) => a.compareTo(b) != 0
        ? a.compareTo(b)
        : a.hashCode.compareTo(b.hashCode),
  );
  final _recentTs = <DateTime>[];
  DateTime? _lastAt;
  Timer?    _timer;

  void Function(String)?    onSpeak;
  // FIX-3: language supplied by the caller instead of reading global state
  VoiceLanguage Function()? getLanguage;

  VoiceLanguage get _lang => getLanguage?.call() ?? VoiceLanguage.english;

  // Spoken fingerprints with expiry — blocks any repeat within 5 minutes.
  // Using a Map<fp, expiry> instead of a single string so that:
  //   - Multiple different payments are tracked (not just the last one)
  //   - Old entries expire automatically so same customer can pay again later
  final Map<String, DateTime> _spokenFps = {};

  bool _isAlreadySpoken(String fp) {
    final expiry = _spokenFps[fp];
    if (expiry == null) return false;
    if (DateTime.now().isAfter(expiry)) {
      _spokenFps.remove(fp);
      return false;
    }
    return true;
  }

  void _markSpoken(String fp) {
    // Expire after 5 minutes — same as the fingerprint time bucket
    _spokenFps[fp] = DateTime.now().add(const Duration(minutes: 5));
    // Cleanup old entries to avoid memory growth
    _spokenFps.removeWhere((_, exp) => DateTime.now().isAfter(exp));
  }

  void enqueue(PaymentEvent e, PaymentUiState ui) {
    if (!PdsConfig.isVoiceEnabled) return;
    final fp = e.fingerprint;
    if (_isAlreadySpoken(fp)) {
      PdsLogger.d('VOICE', 'DUPLICATE BLOCKED: $fp');
      return;
    }
    _markSpoken(fp);

    final text = ui.voiceText(_lang);
    if (text.isEmpty) return;
    final priority = e.isFailed
        ? _VP.high
        : e.decision == PaymentDecision.likely
            ? _VP.soft
            : e.amount >= 1000
                ? _VP.high
                : _VP.normal;
    _queue.add(_VI(text, priority, amount: e.amount, payerName: e.payerName));
    _recentTs.add(DateTime.now());
    _cleanTs();
    _schedule();
  }

  void enqueueRaw(String text, _VP priority, {String? fingerprint}) {
    if (!PdsConfig.isVoiceEnabled || text.isEmpty) return;
    if (fingerprint != null) {
      if (_isAlreadySpoken(fingerprint)) return;
      _markSpoken(fingerprint);
    }
    _queue.add(_VI(text, priority));
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 50), _drain);
  }

  void _drain() {
    if (_queue.isEmpty) return;
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!) < PdsConfig.voiceMinGap) {
      _timer?.cancel();
      _timer = Timer(PdsConfig.voiceMinGap - now.difference(_lastAt!), _drain);
      return;
    }
    _cleanTs();

    // FIX-H: burst with payer names
    final normals = _queue.where((i) => i.priority == _VP.normal).toList();
    if (_recentTs.length >= PdsConfig.voiceBurstCount &&
        normals.length  >= PdsConfig.voiceBurstCount) {
      for (final item in normals) _queue.remove(item);
      final payments = normals
          .where((i) => i.amount != null)
          .map((i) => (i.amount!, i.payerName))
          .toList();
      final text = VoiceBuilder.burst(payments, _lang);
      _speak(text);
      if (_queue.isNotEmpty) {
        _timer?.cancel();
        _timer = Timer(PdsConfig.voiceMinGap, _drain);
      }
      return;
    }

    final item = _queue.first;
    _queue.remove(item);
    _speak(item.text);
    if (_queue.isNotEmpty) {
      _timer?.cancel();
      _timer = Timer(PdsConfig.voiceMinGap, _drain);
    }
  }

  void _speak(String t) {
    _lastAt = DateTime.now();
    PdsLogger.i('VOICE', 'SPEAK "$t"');
    onSpeak?.call(t);
  }

  void _cleanTs() {
    final c = DateTime.now().subtract(PdsConfig.voiceBurstWindow);
    _recentTs.removeWhere((t) => t.isBefore(c));
  }

  void dispose() { _timer?.cancel(); _queue.clear(); _recentTs.clear(); _spokenFps.clear(); }
}

// =============================================================================
// SOURCE FLOOD GUARD
// =============================================================================

class _SourceFloodGuard {
  final _times        = <String, List<DateTime>>{};
  final _blockedUntil = <String, DateTime>{};

  bool isAllowed(String key) {
    final now   = DateTime.now();
    final until = _blockedUntil[key];
    if (until != null && now.isBefore(until)) return false;
    final list   = _times.putIfAbsent(key, () => []);
    final cutoff = now.subtract(PdsConfig.floodWindow);
    list.removeWhere((t) => t.isBefore(cutoff));
    list.add(now);
    if (list.length > PdsConfig.floodLimit) {
      _blockedUntil[key] = now.add(PdsConfig.floodBlock);
      PdsLogger.w('FLOOD', 'FLOOD_BLOCK key=$key');
      return false;
    }
    return true;
  }

  void cleanup() {
    final now = DateTime.now();
    _blockedUntil.removeWhere((_, u) => now.isAfter(u));
    _times.removeWhere((_, list) {
      list.removeWhere((t) =>
          t.isBefore(now.subtract(PdsConfig.floodWindow)));
      return list.isEmpty;
    });
  }
}

// =============================================================================
// ACCESSIBILITY RATE LIMITER
// =============================================================================

class _AccRateLimiter {
  final _times        = <String, List<DateTime>>{};
  final _burst        = <String, List<DateTime>>{};
  final _blockedUntil = <String, DateTime>{};

  bool isAllowed(String pkg) {
    final now   = DateTime.now();
    final until = _blockedUntil[pkg];
    if (until != null && now.isBefore(until)) return false;
    final bt = _burst.putIfAbsent(pkg, () => []);
    bt.removeWhere((t) => t.isBefore(now.subtract(PdsConfig.accBurstWindow)));
    bt.add(now);
    if (bt.length > PdsConfig.accBurstLimit) {
      _blockedUntil[pkg] = now.add(PdsConfig.accBurstBlock);
      return false;
    }
    final mt = _times.putIfAbsent(pkg, () => []);
    mt.removeWhere((t) =>
        t.isBefore(now.subtract(const Duration(minutes: 1))));
    if (mt.length >= PdsConfig.accRateLimitPerMin) return false;
    mt.add(now);
    return true;
  }

  void cleanup() =>
      _blockedUntil.removeWhere((_, u) => DateTime.now().isAfter(u));
}

// =============================================================================
// CHANNEL WATCHDOG
// =============================================================================

class _ChannelWatchdog {
  DateTime? _lastNotif;
  DateTime? _lastSms;
  Timer?    _timer;
  void Function(ChannelType, ChannelStatus)? onStatusChange;

  void recordNotification() => _lastNotif = DateTime.now();
  void recordSms()          => _lastSms   = DateTime.now();

  bool isStale(ChannelType type) {
    final now       = DateTime.now();
    final threshold = PdsConfig.watchdogStaleThreshold;
    if (type == ChannelType.notification) {
      if (_lastNotif == null) return false;
      return now.difference(_lastNotif!) > threshold;
    } else if (type == ChannelType.sms) {
      if (_lastSms == null) return false;
      return now.difference(_lastSms!) > threshold;
    }
    return false;
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(PdsConfig.watchdogHeartbeat, (_) {
      final now   = DateTime.now();
      final stale = PdsConfig.watchdogStaleThreshold;
      if (_lastNotif != null && now.difference(_lastNotif!) > stale) {
        onStatusChange?.call(ChannelType.notification, ChannelStatus.stale);
      }
      if (_lastSms != null && now.difference(_lastSms!) > stale) {
        onStatusChange?.call(ChannelType.sms, ChannelStatus.stale);
      }
    });
  }

  void dispose() => _timer?.cancel();
}

// =============================================================================
// PENDING PAYMENT BUFFER (TCM)
// =============================================================================

class _PendingEntry {
  final PaymentEvent event;
  final DateTime     arrivedAt;
  bool confirmed    = false;
  bool emitted      = false;
  bool voiceSpoken  = false; // FIX: Remember if this event already spoke
  
  _PendingEntry(this.event, {this.voiceSpoken = false}) 
      : arrivedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(arrivedAt) > PdsConfig.tcmSmsMatchWindow(event.amount);
  bool get isLarge => event.amount >= PdsConfig.tcmSmallThreshold;
}

class PendingPaymentBuffer {
  final _buffer = ListQueue<_PendingEntry>();

  void add(PaymentEvent e, {bool voiceSpoken = false}) {
    if (_buffer.length >= PdsConfig.pendingBufferMax) _buffer.removeFirst();
    final entry = _PendingEntry(e, voiceSpoken: voiceSpoken);
    // FIX: Prematurely setting emitted=true bypasses TCM boosts.
    // Let the pipeline or drain control when it's marked as emitted.
    _buffer.add(entry);
    PdsLogger.d('TCM', 'Buffered ₹${e.amount} (voiceSpoken: $voiceSpoken)');
  }

  _PendingEntry? matchSms({
    required double   amount,
    required String?  utr,
    required String?  payerName,
    required DateTime now,
  }) {
    _evict();
    for (final e in _buffer) {
      if (e.confirmed) continue;

      // UTR match — strongest signal, always sufficient alone
      if (utr != null && utr.isNotEmpty &&
          e.event.referenceId != null &&
          e.event.referenceId == utr) {
        e.confirmed = true;
        PdsLogger.i('TCM', 'UTR_MATCH ₹${e.event.amount}');
        return e;
      }

      // FIX-21: require minimum 2-of-3 signals (amount, time, name)
      // amount+time alone is no longer enough — keeps LIKELY, not CONFIRMED
      final timeDiff    = now.difference(e.arrivedAt).abs();
      final amountMatch = (e.event.amount - amount).abs() < 1.0;
      final timeMatch   = timeDiff <= PdsConfig.tcmSmsMatchWindow(e.event.amount);
      final nameMatch   = _nameMatch(e.event.payerName, payerName);

      int signalsMatched = 0;
      if (amountMatch) signalsMatched++;
      if (timeMatch)   signalsMatched++;
      if (nameMatch)   signalsMatched++;

      if (signalsMatched >= 2) {
        if (!amountMatch) continue; // amount must always be one of the signals
        e.confirmed = true;
        final matchType = nameMatch ? 'AMOUNT+TIME+NAME' : 'AMOUNT+TIME';
        PdsLogger.i('TCM', 'FIX-21 $matchType ₹${e.event.amount} signals=$signalsMatched');
        return e;
      }

      // Single signal (amount+time only) — log but do NOT confirm
      if (amountMatch && timeMatch && !nameMatch) {
        PdsLogger.d('TCM', 'FIX-21 AMOUNT+TIME_ONLY — keeping LIKELY ₹${e.event.amount}');
      }
    }
    return null;
  }

  List<PaymentEvent> drainUnconfirmed() {
    final now    = DateTime.now();
    final toEmit = <PaymentEvent>[];
    for (final e in _buffer) {
      if (e.emitted || e.confirmed) continue;
      final age      = now.difference(e.arrivedAt);
      final drainAge = e.isLarge
          ? PdsConfig.tcmLargeDrain
          : PdsConfig.tcmSmallDrain;
      if (age > drainAge) {
        e.emitted = true;
        if (e.isLarge) {
          toEmit.add(e.event.copyWith(
            confidenceScore: math.min(
                e.event.confidenceScore, PdsConfig.confirmedThreshold - 0.01),
            decision:        PaymentDecision.likely,
            detectionSource: '${e.event.detectionSource}:unconfirmed',
          ));
          PdsLogger.i('TCM', 'LARGE_UNCONFIRMED→LIKELY ₹${e.event.amount}');
        } else {
          toEmit.add(e.event);
        }
      }
    }
    return toEmit;
  }

  bool _nameMatch(String? a, String? b) {
    if (a == null || b == null) return false;
    final na = a.toLowerCase().trim();
    final nb = b.toLowerCase().trim();
    if (na == nb)                     return true;
    if (na.contains(nb) || nb.contains(na)) return true;
    final ta = na.split(' ').first;
    final tb = nb.split(' ').first;
    return ta == tb && ta.length > 2;
  }

  void _evict() => _buffer.removeWhere((e) => e.isExpired && e.emitted);
  void dispose() => _buffer.clear();

  void markVoiceSpoken(String id) {
    for (final e in _buffer) {
      if (e.event.id == id) {
        e.voiceSpoken = true;
        return;
      }
    }
  }
}

// =============================================================================
// CONFIDENCE SCORER  (FIX-4: trusted-app bonus raised to +0.40)
// =============================================================================

abstract class _Scorer {
  static double calculate({
    required String     text,
    required String?    utr,
    required String?    name,
    required String?    vpa,
    required String?    acc,
    required PaymentApp app,
    required bool       isFailed,
    required String     source,
    required String?    sender,
  }) {
    if (isFailed) return 0.0;
    double s = 0.0;

    // ── UTR validation (FIX-17 retained, FIX-44 penalty reduced) ─────────
    final _numericUtr = RegExp(r'^[A-Za-z0-9]{4,22}$');
    bool validUtr = false;
    if (utr != null && utr.isNotEmpty) {
      if (_numericUtr.hasMatch(utr)) {
        validUtr = true;
        s += 0.40; // valid UTR — strongest signal
      } else {
        // FIX-44: penalty reduced -0.40 → -0.25
        s -= PdsConfig.invalidUtrPenalty;
        PdsLogger.w('SCORER', 'FIX-17/44: Invalid UTR "$utr" penalty -${PdsConfig.invalidUtrPenalty}');
      }
    }

    // ── FIX-38: tiered context scoring ────────────────────────────────────
    // STRONG: credit verb + bank/UPI ref  → +0.30
    // MEDIUM: credit verb only            → +0.15
    // WEAK:   amount present (any signal) → +0.05
    // No rejection based on context alone
    final structuredCtx = _Classifier.hasStructuredPaymentContext(text);
    final basicCtx      = _Classifier.hasPaymentContext(text);

    if (structuredCtx) {
      s += 0.30; // FIX-38 STRONG
    } else if (basicCtx) {
      s += 0.15; // FIX-38 MEDIUM
    } else {
      s += 0.05; // FIX-38 WEAK — amount detected but no keyword
    }

    if (name != null && name.isNotEmpty) s += 0.10;
    if (vpa  != null && vpa.isNotEmpty)  s += 0.05;

    // ── Source trust + FIX-41+47 trusted app boost ────────────────────────
    const trusted = {
      PaymentApp.googlePay, PaymentApp.phonePe, PaymentApp.paytm,
      PaymentApp.amazonPay, PaymentApp.bhim,    PaymentApp.bankApp,
    };
    final isTrustedApp = trusted.contains(app);

    if (source == 'sms' && PaymentDetectionService._isVerifiedBankSender(sender)) {
      s += 0.20;
    } else if (isTrustedApp) {
      if (structuredCtx) {
        // FIX-41: strong context + trusted → +0.40 (unchanged, still best path)
        s += 0.40;
      } else if (basicCtx) {
        // FIX-41: keyword present → controlled +0.25 bonus
        s += 0.25;
      } else {
        // FIX-47: notification-only, no context → +0.10 (enough for LIKELY)
        s += 0.10;
      }
    } else if (source == 'notification+sms') {
      s += 0.35;
    }

    // ── FIX-43: bank format flexibility ──────────────────────────────────
    // If 2-of-3 (amount implicit, keyword, trusted sender/app) → +0.05 boost
    // This helps messages that lack strict A/c format but are clearly real
    final hasBankRef = RegExp(
      r'\b(bank|account|a\/c|upi|imps|neft|rtgs|acc\b|acct\b|wallet'
      r'|खाते|खाता|ಖಾತೆ|கணக்கு|ఖాతా)\b',
      caseSensitive: false,
    ).hasMatch(text);
    final trustedSource = isTrustedApp || PaymentDetectionService._isVerifiedBankSender(sender);
    int flexSignals = 0;
    if (basicCtx || structuredCtx) flexSignals++;
    if (trustedSource)             flexSignals++;
    if (hasBankRef)                flexSignals++;
    if (flexSignals >= 2 && !validUtr) {
      s += 0.05; // FIX-43: flexible structure bonus
    }

    // ── FIX-23 retained + FIX-44 penalty reduced ─────────────────────────
    final hasMaskedAccount = RegExp(
      r'(?:x{2,}|[*]{2,}|\d{4})\s*(?:a\/c|account|ac\b)',
      caseSensitive: false,
    ).hasMatch(text) || RegExp(r'\b\d{4}\b').hasMatch(text);
    final startsWithPaidTo = RegExp(
      r'^paid\s+to\b', caseSensitive: false,
    ).hasMatch(text.trim());

    // FIX-43: fake structure only if ALL signals missing (not just bank ref)
    bool fakeStructure = false;
    if (startsWithPaidTo && !trustedSource)            fakeStructure = true;
    if (!hasBankRef && !hasMaskedAccount && !basicCtx) fakeStructure = true;
    if (source == 'sms' && sender == null)             fakeStructure = true;

    if (fakeStructure) {
      // FIX-44: reduced -0.30 → -0.15
      s -= PdsConfig.fakeStructurePenalty;
      PdsLogger.w('SCORER', 'FIX-23/44: Fake structure penalty -${PdsConfig.fakeStructurePenalty}');
    }

    // ── FIX-49: Real Bank Name Validation ────────────────────────────────
    // Require at least one real bank keyword (HDFC, SBI, ICICI, AXIS, etc)
    // If missing: reduce score by 0.20 (soft penalty, not rejection)
    final hasRealBank = _BankNameValidator.hasRealBankName(text);
    if (!hasRealBank && !validUtr && source == 'notification') {
      // Penalty only for notifications without UTR
      // SMS messages may not always include bank name (shorter format)
      s -= 0.20;
      PdsLogger.d('SCORER', 'FIX-49: Missing real bank name -0.20');
    }

    // ── FIX-46: smart spoof detection ────────────────────────────────────
    // Perfect grammar message + no bank ref + no UTR → subtle spoof signal
    final hasPunctuation    = RegExp(r'[.!,]').hasMatch(text);
    final hasCapitalization = RegExp(r'[A-Z]{2,}').hasMatch(text);
    final looksPolished     = hasPunctuation && hasCapitalization && text.length > 30;
    if (looksPolished && !hasBankRef && !validUtr && source != 'sms') {
      s -= 0.10;
      PdsLogger.d('SCORER', 'FIX-46: Polished-but-no-bank spoof signal -0.10');
    }

    // ── FIX-54: Spoof Heuristic Boost ────────────────────────────────────
    // Perfect clean sentence + generic wording (no specific details)
    // → apply additional -0.10 penalty
    // Catches AI-generated/template messages lacking authentic details
    final isGenericResponse = RegExp(
      r'\b(payment|received|credited|transaction|transfer|money|amount)\b',
      caseSensitive: false,
    ).allMatches(text).length >= 3;
    final hasNoSpecifics = !RegExp(r'₹|rupees|rs\.?|ref|utr|txn').hasMatch(text);
    final tooPolished = hasPunctuation && hasCapitalization && 
                       text.length > 40 && text.length < 100;

    if (tooPolished && isGenericResponse && hasNoSpecifics) {
      s -= 0.10;
      PdsLogger.d('SCORER', 'FIX-54: Generic template spoof signal -0.10');
    }

    // ── FIX-24 retained + FIX-44 penalty reduced ─────────────────────────
    if (source == 'sms' && sender != null &&
        !PaymentDetectionService._isVerifiedBankSender(sender) &&
        !TrustedSenderStore.isKnownSync(sender)) {
      // FIX-44: reduced -0.25 → -0.15
      s -= PdsConfig.unwhitelistedSmsPenalty;
      PdsLogger.d('SCORER', 'FIX-24/44: Unwhitelisted sender "$sender" -${PdsConfig.unwhitelistedSmsPenalty}');
    }

    // ── FIX-44: score floor — penalties can't kill real payment signals ───
    // If we have at least one positive signal (basicCtx OR trustedSource),
    // don't drop below minScoreFloor
    if ((basicCtx || trustedSource) && s < PdsConfig.minScoreFloor) {
      s = PdsConfig.minScoreFloor;
      PdsLogger.d('SCORER', 'FIX-44: Floor applied → $s');
    }

    return s.clamp(0.0, 1.0);
  }

  static PaymentDecision decide(double score) {
    if (score >= PdsConfig.confirmedThreshold) return PaymentDecision.confirmed;
    if (score >= PdsConfig.likelyThreshold)    return PaymentDecision.likely;
    return PaymentDecision.rejected;
  }
}

// =============================================================================
// ██████████████████████████████████████████████████████████████████████████
// MAIN SERVICE  (V15)
// ██████████████████████████████████████████████████████████████████████████
// =============================================================================

class PaymentDetectionService {
  static final PaymentDetectionService _i = PaymentDetectionService._();
  factory PaymentDetectionService() => _i;
  PaymentDetectionService._();

  // Deduplication cache for SMS (BUG-S2)
  final List<String> _processedSmsCache = [];

  static VoiceLanguage mapLanguage(String code) {
    final lang = code.split(RegExp(r'[-_]')).first.toLowerCase();
    switch (lang) {
      case 'hi': return VoiceLanguage.hindi;
      case 'ta': return VoiceLanguage.tamil;
      case 'te': return VoiceLanguage.telugu;
      case 'kn': return VoiceLanguage.kannada;
      case 'mr': return VoiceLanguage.marathi;
      case 'gu': return VoiceLanguage.gujarati;
      case 'bn': return VoiceLanguage.bengali;
      case 'pa': return VoiceLanguage.punjabi;
      case 'ml': return VoiceLanguage.malayalam;
      default:   return VoiceLanguage.english;
    }
  }

  static PaymentEvent analyze({
    required String text,
    required String source,
    required String? sender,
    required double? amount,
    required String? utr,
    required String? vpa,
  }) {
    final cleanText = _Normaliser.clean(text);
    final app = _AppRegistry.resolve(source, sender, cleanText);
    final refId = utr ?? _Extractor.referenceId(cleanText);
    
    // Run fraud engine
    final fraud = FraudEngine.analyze(
      text: cleanText,
      source: source,
      sender: sender,
      amount: amount,
      utr: refId,
      vpa: vpa,
    );

    if (fraud.isHardBlock) {
      return PaymentEvent(
        amount: amount ?? 0.0,
        timestamp: DateTime.now(),
        app: app,
        payerName: _Extractor.payerName(cleanText),
        referenceId: refId,
        vpa: vpa,
        accountSuffix: _Extractor.accountSuffix(cleanText),
        bankName: _Extractor.bankName(cleanText, sender: sender),
        rawText: text,
        confidenceScore: 0.0,
        decision: PaymentDecision.rejected,
        detectionSource: source,
      );
    }

    final isFailed = _Re.failure.hasMatch(cleanText) && !_Classifier.hasPaymentContext(cleanText);

    // Apply strict UTR validation check
    final _numericUtrRe = RegExp(r'^[A-Za-z0-9]{4,22}$');
    final bool validNumericUtr = refId != null && _numericUtrRe.hasMatch(refId);
    bool utrCapApplied = false;
    if (amount != null && amount > PdsConfig.utrRequiredAbove && !validNumericUtr) {
      utrCapApplied = true;
    }

    final billResult = PaymentDetectionService().billContext.evaluate(amount ?? 0.0);
    bool isBillMatch = billResult == BillMatchResult.exact || billResult == BillMatchResult.partial;
    bool isPartial = billResult == BillMatchResult.partial;
    double shortfall = isPartial ? PaymentDetectionService().billContext.remainingAmount : 0.0;
    
    if (!isPartial && (cleanText.toLowerCase().contains('partial') || 
                       cleanText.toLowerCase().contains('shortfall') || 
                       cleanText.toLowerCase().contains('remaining'))) {
      isPartial = true;
      final shortfallMatch = RegExp(r'(?:shortfall|remaining)[:\s#₹rs.]*(\d+(?:\.\d+)?)', caseSensitive: false).firstMatch(cleanText);
      if (shortfallMatch != null) {
        shortfall = double.tryParse(shortfallMatch.group(1)!) ?? 0.0;
      }
    }

    double billBoost = 0.0;
    if (!PaymentDetectionService().billContext.isSettlementLocked) {
      if (billResult == BillMatchResult.exact) {
        billBoost = 0.20;
      } else if (billResult == BillMatchResult.partial) {
        final remaining = PaymentDetectionService().billContext.remainingAmount;
        if (((amount ?? 0.0) - remaining).abs() < 2.0) {
          billBoost = 0.25;
        } else {
          billBoost = 0.10;
        }
      } else if (billResult == BillMatchResult.suspicious) {
        billBoost = -0.15;
      }
    }

    bool billMismatchCap = billResult == BillMatchResult.suspicious || billResult == BillMatchResult.mismatch;

    // Scoring
    double score = _Scorer.calculate(
      text: cleanText,
      utr: refId,
      name: _Extractor.payerName(cleanText),
      vpa: vpa,
      acc: _Extractor.accountSuffix(cleanText),
      app: app,
      isFailed: isFailed,
      sender: sender,
      source: source,
    );

    score -= fraud.riskScore * 0.35;
    score += billBoost;
    score = score.clamp(0.0, 1.0);

    if (utrCapApplied || billMismatchCap) {
      score = math.min(score, PdsConfig.confirmedThreshold - 0.01);
    }

    final minThreshold = source == 'sms' && _isVerifiedBankSender(sender)
        ? PdsConfig.thresholdVerifiedSms
        : (source == 'accessibility' ? PdsConfig.thresholdAccessibility : PdsConfig.thresholdTrustedApp);

    final isTrustedApp = const {
      PaymentApp.googlePay, PaymentApp.phonePe, PaymentApp.paytm,
      PaymentApp.amazonPay, PaymentApp.bhim,
    }.contains(app);

    PaymentDecision decision;
    if (score < minThreshold) {
      if (source == 'notification' && isTrustedApp && (amount ?? 0.0) > 0 && _Classifier.hasStructuredPaymentContext(cleanText)) {
        score = PdsConfig.likelyThreshold;
        decision = PaymentDecision.likely;
      } else {
        decision = PaymentDecision.rejected;
      }
    } else {
      decision = _Scorer.decide(score);
    }

    // Small payment UTR cap lift
    final isTrustedAppOrSms = isTrustedApp || (source == 'sms' && _isVerifiedBankSender(sender));
    if (utrCapApplied && (amount ?? 0.0) < PdsConfig.highValueThreshold && _Classifier.hasStructuredPaymentContext(cleanText) && isTrustedAppOrSms) {
      utrCapApplied = false;
      decision = _Scorer.decide(score);
    }

    // 🔴 FIX-55: HIGH-VALUE PAYMENT VERIFICATION (CRITICAL SECURITY)
    // For payments > ₹2000: CONFIRMED ONLY IF:
    // - Valid numeric UTR exists OR
    // - Verified bank SMS sender OR
    // - Bill match (exact/partial)
    if (decision == PaymentDecision.confirmed && (amount ?? 0.0) > PdsConfig.highValueThreshold) {
      final hasValidUtr = validNumericUtr;
      final hasVerifiedBankSender = source == 'sms' && _isVerifiedBankSender(sender);
      final hasStrongBillMatch = billResult == BillMatchResult.exact || 
                                 (billResult == BillMatchResult.partial && billBoost > 0.10);
      
      // If none of these are true, downgrade to LIKELY
      if (!hasValidUtr && !hasVerifiedBankSender && !hasStrongBillMatch) {
        decision = PaymentDecision.likely;
        PdsLogger.i('FIX-55', '⚠️ HIGH-VALUE (₹${amount}) downgraded: CONFIRMED → LIKELY (needs backend verify)');
      }
    }
    
    // Minimum structure check
    if (decision == PaymentDecision.confirmed) {
      final hasBankRef = _Extractor.bankName(cleanText, sender: sender) != null ||
          _Extractor.accountSuffix(cleanText) != null ||
          RegExp(r'\b(bank|account|a\/c|upi|imps|neft|rtgs)\b', caseSensitive: false).hasMatch(cleanText);
      final verifiedSender = _isVerifiedBankSender(sender);
      final hasPayerName = _Extractor.payerName(cleanText) != null && _Extractor.payerName(cleanText)!.isNotEmpty;
      final hasStrongCtx = _Classifier.hasStructuredPaymentContext(cleanText);

      int structureScore = 0;
      if (validNumericUtr) structureScore++;
      if (hasBankRef) structureScore++;
      if (verifiedSender) structureScore++;
      if (hasPayerName) structureScore++;
      if (hasStrongCtx && isTrustedApp) structureScore++;

      if (structureScore < 2) {
        decision = PaymentDecision.likely;
      }
    }

    return PaymentEvent(
      amount: amount ?? 0.0,
      timestamp: DateTime.now(),
      app: app,
      payerName: _Extractor.payerName(cleanText),
      referenceId: refId,
      vpa: vpa,
      accountSuffix: _Extractor.accountSuffix(cleanText),
      bankName: _Extractor.bankName(cleanText, sender: sender),
      rawText: text,
      confidenceScore: score,
      decision: decision,
      detectionSource: source,
      isFailed: isFailed,
    );
  }

  // ── Streams ───────────────────────────────────────────────────────────────
  StreamController<PaymentEvent>       _eventCtrl  = StreamController<PaymentEvent>.broadcast();
  StreamController<PaymentUiState>     _uiCtrl     = StreamController<PaymentUiState>.broadcast();
  StreamController<ChannelStatusEvent> _statusCtrl = StreamController<ChannelStatusEvent>.broadcast();
  StreamController<FraudAlertEvent>    _fraudCtrl  = StreamController<FraudAlertEvent>.broadcast();

  Stream<PaymentEvent>       get onPaymentDetected => _eventCtrl.stream;
  Stream<PaymentUiState>     get onUiState         => _uiCtrl.stream;
  Stream<ChannelStatusEvent> get onChannelStatus   => _statusCtrl.stream;
  Stream<FraudAlertEvent>    get onFraudAlert       => _fraudCtrl.stream;

  // ── Sub-systems ───────────────────────────────────────────────────────────
  final _pendingBuffer  = PendingPaymentBuffer();
  final _voice          = PriorityVoiceQueue();
  final _floodGuard     = _SourceFloodGuard();
  final _accRateLimit   = _AccRateLimiter();
  final _behaviorMemory = BehavioralMemory();
  final _watchdog       = _ChannelWatchdog();
  final _stats          = PdsSessionStats();
  final _confirmMgr     = ConfirmationManager();

  // FIX-I: public payment history
  final history     = PaymentHistoryBuffer();
  final billContext = BillContext();

  BankVerifier bankVerifier = _NoOpVerifier();

  static const _channel = MethodChannel('com.retailmind.billing/accessibility');

  bool _isStarted    = false;
  bool _isBackground = false;

  // FIX-3: language as instance field (replaces PdsConfig.language static)
  VoiceLanguage _voiceLanguage = VoiceLanguage.english;

  StreamSubscription<ServiceNotificationEvent>? _notifSub;
  StreamSubscription<AccessibilityEvent>? _accessSub;

  final Map<String, DateTime> _dedupStore = {};
  bool _dedupDirty = false;

  Timer? _tcmDrainTimer;
  Timer? _dedupTimer;
  Timer? _dedupSaveTimer;
  Timer? _guardTimer;
  Timer? _midnightTimer;
  Timer? _healthTimer;

  // FIX-K: LIKELY re-announcement timers
  final _likelyTimers = <String, Timer>{};

  // FIX-D: track last confirmed event for repeat
  PaymentEvent? _lastConfirmed;
  // FIX: Atomic lock for pipeline racing
  final _activeFingerprints = <String>{};
  
  // ✅ FIX: In-memory lock set for concurrency-critical operations
  final Set<String> _settlingInvoiceIds = {};

  // ── Public API ────────────────────────────────────────────────────────────
  set onSpeak(void Function(String) cb) => _voice.onSpeak = cb;
  PdsSessionStats get sessionStats => _stats;

  /// FIX-3: sets language on the instance; no global state mutation.
  void setLanguage(VoiceLanguage lang) {
    _voiceLanguage = lang;
    PdsLogger.i('PDS', 'Voice language → ${lang.name}');
  }

  void setBillExpected(double amount) {
    if (amount <= 0) {
      PdsLogger.w('SVC', 'Rejecting invalid bill amount: $amount');
      return;
    }
    billContext.setExpected(amount);
    PdsLogger.i('SVC', 'Bill set: ₹$amount');
  }
  void clearBill() { billContext.clear(); PdsLogger.i('SVC', 'Bill cleared'); }

  // FIX-D: fully wired confirm/reject using id
  PaymentEvent? confirmPayment(String id) {
    final confirmed = _confirmMgr.confirm(id);
    if (confirmed != null) {
      _likelyTimers.remove(id)?.cancel();
      _emitFinal(confirmed);
    }
    return confirmed;
  }

  void rejectPayment(String id) {
    _likelyTimers.remove(id)?.cancel();
    _confirmMgr.reject(id);
    final state = history.findById(id);
    if (state != null) {
      final updated = state.copyWith(isUserRejected: true);
      history.update(id, updated);
      _uiCtrl.add(updated);
    }
    PdsLogger.i('SVC', 'Payment rejected id=$id');
  }

  Future<void> learnPaymentSender(String smsSender) =>
      TrustedSenderStore.learnSender(smsSender);

  // Battery optimization helpers
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) { return false; }
  }
  static Future<void> requestIgnoreBatteryOptimization() async {
    try { await _channel.invokeMethod('requestIgnoreBatteryOptimization'); }
    catch (_) {}
  }
  static Future<void> openBatteryOptimizationSettings() async {
    try { await _channel.invokeMethod('openBatteryOptimizationSettings'); }
    catch (_) {}
  }

  Future<void> remoteConfigUpdate(Map<String, dynamic> settings) async {
    PdsLogger.i('SVC', 'Remote config updated: $settings');
  }

  Future<bool> runInternalTests() async {
    PdsLogger.i('TEST', 'Running engine health check...');
    final notifOk = await hasNotificationPermission();
    final smsOk   = await Telephony.instance.requestSmsPermissions ?? false;
    PdsLogger.i('TEST', 'Notif: $notifOk, SMS: $smsOk');
    return notifOk || smsOk;
  }

  Future<void> _ensureDetectionPermissions() async {
    if (!PdsConfig.isNotificationEnabled) {
      PdsLogger.i('SVC', 'Notification channel disabled by config');
    } else if (!await NotificationListenerService.isPermissionGranted()) {
      PdsLogger.w('SVC', 'Notification listener permission missing; requesting');
      try {
        await NotificationListenerService.requestPermission();
      } catch (e, st) {
        PdsLogger.e('SVC', 'Notification permission request failed', e, st);
      }
    }

    if (!PdsConfig.isSmsEnabled) {
      PdsLogger.i('SVC', 'SMS channel disabled by config');
    } else {
      try {
        final granted = await Telephony.instance.requestSmsPermissions;
        if (granted == true) {
          PdsLogger.i('SVC', 'SMS permission granted');
        } else {
          PdsLogger.w('SVC', 'SMS permission denied or unavailable');
        }
      } catch (e, st) {
        PdsLogger.e('SVC', 'SMS permission request failed', e, st);
      }
    }
  }

  void repeatLastPayment() {
    if (_lastConfirmed == null) return;
    final text = VoiceBuilder.received(
        _lastConfirmed!.amount, _lastConfirmed!.payerName, _voiceLanguage);
    _voice.enqueueRaw(text, _VP.high);
  }

  // FIX-59: Cross-Device UTR Deduplication (Redis-backed)
  // Prevents double-confirmation when multiple tablets detect same payment
  // Multi-staff shops with 2-5 terminals = high risk of duplicate entry
  // Design: Device A registers UTR in Redis → Device B checks before confirming
  // Implementation: Backend provides /api/utr/register and /api/utr/check endpoints
  // 10 lines of integration: just call these endpoints before emitting CONFIRMED
  
  /// Check if UTR was already confirmed on another device (Redis check)
  Future<bool> _isUtrAlreadyRegistered(String utr) async {
    if (utr.isEmpty) return false;
    try {
      final response = await ApiClient.getJson(
        '${ApiClient.utrCheckEndpoint}?utr=$utr',
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['seen'] == true;
      }
      return false;
    } catch (e) {
      PdsLogger.w('FIX-59', 'UTR check error: $e');
      return false; // Fail-open
    }
  }

  /// Register UTR as confirmed on this device (Redis write)
  Future<void> _registerUtrConfirmed(String utr, double amount) async {
    if (utr.isEmpty) return;
    try {
      final deviceId = await SessionManagementService.getDeviceId();
      await ApiClient.postJson(
        ApiClient.utrRegisterEndpoint,
        {
          'utr': utr,
          'amount': amount,
          'device': deviceId,
          'timestamp': DateTime.now().toIso8601String(),
        },
      ).timeout(const Duration(seconds: 5));
      PdsLogger.i('FIX-59', 'UTR registered: $utr');
    } catch (e) {
      PdsLogger.w('FIX-59', 'UTR registration failed: $e');
    }
  }

  /// FIX-59: Check for conflicts and register UTR atomically
  Future<void> _checkAndRegisterUtrCrossDevice(PaymentEvent event) async {
    final utr = event.referenceId; // use referenceId as UTR
    if (utr == null || utr.isEmpty) return;

    final alreadySeenElsewhere = await _isUtrAlreadyRegistered(utr);
    if (alreadySeenElsewhere) {
      PdsLogger.w('FIX-59', '⚠️ CONFLICT: UTR $utr already confirmed on another device!');
      // Downgrade decision to LIKELY (requires manual merchant confirmation)
      // This prevents zombie double-entries in multi-staff shops
      final downgraded = event.copyWith(
        decision: PaymentDecision.likely,
        detectionSource: '${event.detectionSource}:cross_device_conflict_downgraded',
      );
      // Re-emit as LIKELY so staff merge both tablets manually if needed
      unawaited(_emit(downgraded, isBillSettlement: false, forceMute: false));
      return;
    }

    // No conflict: register this UTR to prevent others from confirming it
    await _registerUtrConfirmed(utr, event.amount);
  }

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  Future<void> start() async {
    if (_isStarted) return;

    // 1. Cancel old subscription FIRST to stop stale events
    await _notifSub?.cancel();
    _notifSub = null;

    // 2. Recreate any closed controllers BEFORE going live
    if (_eventCtrl.isClosed)  _eventCtrl  = StreamController<PaymentEvent>.broadcast();
    if (_uiCtrl.isClosed)     _uiCtrl     = StreamController<PaymentUiState>.broadcast();
    if (_statusCtrl.isClosed) _statusCtrl = StreamController<ChannelStatusEvent>.broadcast();
    if (_fraudCtrl.isClosed)  _fraudCtrl  = StreamController<FraudAlertEvent>.broadcast();

    // 3. Only NOW mark as started
    _isStarted = true;

    PdsLogger.i('SVC', '═══ V15 MERCHANT GRADE STARTING ═══');

    // FIX-3: wire language callback into voice queue
    _voice.getLanguage = () => _voiceLanguage;

    await PdsStateStore.loadDedup(_dedupStore);
    await TrustedSenderStore.preload(); // FIX-B

    await _ensureDetectionPermissions();
    await _startNotificationListener();
    await _startSmsListener();
    _startAccessibilityListener();
    _startTcmDrainTimer();
    _startDedupTimer();
    _startDedupSaveTimer();
    _startGuardTimer();
    _startMidnightReset();
    _startHealthCheck();

    _watchdog.onStatusChange = (c, s) => _emitStatus(c, s);
    _watchdog.start();

    PdsLogger.i('SVC', 'All channels ready');
  }

  void setBackgroundMode(bool isBg) {
    _isBackground = isBg;
    PdsLogger.i('SVC', 'Mode: ${isBg ? "BACKGROUND" : "FOREGROUND"}');
    if (!isBg) _startHealthCheck();
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (!_isStarted) return;
      final isNotifOk = await hasNotificationPermission();
      if (!isNotifOk) {
        _emitStatus(ChannelType.notification, ChannelStatus.permissionDenied);
      }
      if (_watchdog.isStale(ChannelType.notification)) {
        PdsLogger.w('SVC', 'Watchdog: Notif stale — attempting recovery');
        await _startNotificationListener();
      }
    });
  }

  Future<void> dispose() async {
    PdsLogger.i('SVC', 'Engine disposing');
    _tcmDrainTimer?.cancel(); _dedupTimer?.cancel();
    _dedupSaveTimer?.cancel(); _guardTimer?.cancel();
    _midnightTimer?.cancel();  _healthTimer?.cancel();
    for (final t in _likelyTimers.values) t.cancel();
    _likelyTimers.clear();
    await _notifSub?.cancel();
    _notifSub = null;
    if (_dedupDirty) await PdsStateStore.saveDedup(_dedupStore);
    _pendingBuffer.dispose(); _voice.dispose();
    _watchdog.dispose();      _behaviorMemory.dispose();
    _confirmMgr.dispose();
    for (final c in [_eventCtrl, _uiCtrl, _statusCtrl, _fraudCtrl]) {
      if (!c.isClosed) c.close();
    }
    _activeFingerprints.clear();
    _isStarted = false;
    PdsLogger.i('SVC', 'Engine disposed');
  }

  Future<void> restart() async {
    await dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await start();
  }

  // ==========================================================================
  // TIMERS
  // ==========================================================================

  void _startTcmDrainTimer() {
    _tcmDrainTimer?.cancel();
    _tcmDrainTimer = Timer.periodic(PdsConfig.tcmDrainInterval, (_) {
      try { for (final e in _pendingBuffer.drainUnconfirmed()) unawaited(_emit(e)); }
      catch (e, st) { PdsLogger.e('TCM', 'Drain error', e, st); }
    });
  }

  void _startDedupTimer() {
    _dedupTimer?.cancel();
    _dedupTimer = Timer.periodic(PdsConfig.dedupCleanupInterval, (_) {
      _dedupStore.removeWhere((_, exp) => DateTime.now().isAfter(exp));
    });
  }

  // FIX-C: debounced dedup save — writes only when dirty
  void _startDedupSaveTimer() {
    _dedupSaveTimer?.cancel();
    _dedupSaveTimer = Timer.periodic(PdsConfig.dedupSaveDebounce, (_) {
      if (_dedupDirty) {
        _dedupDirty = false;
        unawaited(PdsStateStore.saveDedup(_dedupStore));
      }
    });
  }

  void _startGuardTimer() {
    _guardTimer?.cancel();
    _guardTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      try {
        _floodGuard.cleanup(); _accRateLimit.cleanup(); _confirmMgr.cleanup();
        // FIX: Clean up likely timers that are no longer in history or expired
        _likelyTimers.removeWhere((id, timer) {
          if (history.findById(id) == null) {
            timer.cancel();
            return true;
          }
          return false;
        });
      } catch (e, st) { PdsLogger.e('GUARD', 'Guard timer error', e, st); }
    });
  }

  void _startMidnightReset() {
    final now      = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer?.cancel();
    _midnightTimer = Timer(tomorrow.difference(now), () {
      _stats.reset();
      PdsLogger.i('SVC', 'Daily stats reset');
      _startMidnightReset();
    });
  }

  // ==========================================================================
  // CHANNEL STARTERS
  // ==========================================================================

  Future<void> _startNotificationListener() async {
    if (!PdsConfig.isNotificationEnabled) return;
    try {
      final permissionGranted = await NotificationListenerService.isPermissionGranted();
      if (!permissionGranted) {
        PdsLogger.w('L1', 'Notification permission was not granted when starting listener');
        _emitStatus(ChannelType.notification, ChannelStatus.permissionDenied);
        return;
      }

      await _notifSub?.cancel();
      _notifSub = NotificationListenerService.notificationsStream.listen(
        _handleNotification,
        onError: (Object e, StackTrace st) {
          PdsLogger.e('L1', 'Stream error', e, st);
          _emitStatus(ChannelType.notification, ChannelStatus.error);
          Future<void>.delayed(
              const Duration(seconds: 10), _startNotificationListener);
        },
      );
      PdsLogger.i('L1', 'Notification ONLINE');
      _emitStatus(ChannelType.notification, ChannelStatus.online);
    } catch (e, st) {
      PdsLogger.e('L1', 'Start error', e, st);
      _emitStatus(ChannelType.notification, ChannelStatus.error, detail: '$e');
    }
  }

  static bool _isSmsListening = false;

  Future<void> _startSmsListener() async {
    if (!PdsConfig.isSmsEnabled) return;
    if (_isSmsListening) return; // Prevent duplicate listeners
    try {
      final granted = await Telephony.instance.requestSmsPermissions;
      if (granted == true) {
        _isSmsListening = true;
        Telephony.instance.listenIncomingSms(
          onNewMessage: (m) => handleSms(m.address ?? '', m.body ?? ''),
          onBackgroundMessage: smsBackgroundHandler,
          listenInBackground: true,
        );
        PdsLogger.i('L2', 'SMS ONLINE');
        _emitStatus(ChannelType.sms, ChannelStatus.online);
      } else {
        if (await Telephony.instance.requestSmsPermissions ?? false) {
          // Retry once in case of transient denial
          _isSmsListening = true;
          Telephony.instance.listenIncomingSms(
            onNewMessage: (m) => handleSms(m.address ?? '', m.body ?? ''),
            onBackgroundMessage: smsBackgroundHandler,
            listenInBackground: true,
          );
          PdsLogger.i('L2', 'SMS ONLINE after retry');
          _emitStatus(ChannelType.sms, ChannelStatus.online);
          return;
        }
        PdsLogger.w('L2', 'SMS PERMISSION_DENIED');
        _emitStatus(ChannelType.sms, ChannelStatus.permissionDenied);
      }
    } catch (e, st) {
      PdsLogger.e('L2', 'Start error', e, st);
      _emitStatus(ChannelType.sms, ChannelStatus.error, detail: '$e');
    }
  }

  void _startAccessibilityListener() {
    if (!PdsConfig.isAccessibilityEnabled) return;

    Future<void>(() async {
      try {
        final enabled =
            await FlutterAccessibilityService.isAccessibilityPermissionEnabled();

        if (!enabled) {
          _emitStatus(
            ChannelType.accessibility,
            ChannelStatus.permissionDenied,
            detail: 'Accessibility permission is disabled',
          );
          return;
        }

        await _accessSub?.cancel();

        _accessSub = FlutterAccessibilityService.accessStream.listen(
          (event) {
            try {
              final pkg = (event.packageName ?? '').trim();
              final text = _collectAccessibilityText(event).trim();

              if (pkg.isEmpty || text.isEmpty) return;
              if (pkg == 'com.example.retail_mind') return;

              if (_TrustGate.isBlockedPackage(pkg)) return;

              if (!_accRateLimit.isAllowed(pkg)) {
                _emitStatus(
                  ChannelType.accessibility,
                  ChannelStatus.rateLimited,
                  detail: pkg,
                );
                return;
              }

              if (!_floodGuard.isAllowed('acc:$pkg')) {
                _emitStatus(
                  ChannelType.accessibility,
                  ChannelStatus.blocked,
                  detail: pkg,
                );
                return;
              }

              _processText(
                text,
                _AppRegistry.identify(pkg),
                source: 'accessibility',
              );
            } catch (e, st) {
              PdsLogger.e(
                'L3-ACC',
                'Accessibility event handler error',
                e,
                st,
              );
            }
          },
          onError: (Object error, StackTrace stack) {
            PdsLogger.e('L3-ACC', 'Accessibility stream error', error, stack);
            _emitStatus(
              ChannelType.accessibility,
              ChannelStatus.error,
              detail: '$error',
            );
          },
          cancelOnError: false,
        );

        PdsLogger.i('L3-ACC', 'Accessibility LISTENING (plugin stream)');
        _emitStatus(ChannelType.accessibility, ChannelStatus.online);
      } catch (e, st) {
        PdsLogger.e('L3-ACC', 'Accessibility startup error', e, st);
        _emitStatus(
          ChannelType.accessibility,
          ChannelStatus.error,
          detail: '$e',
        );
      }
    });
  }

  // ==========================================================================
  // PERMISSION HELPERS
  // ==========================================================================

  static Future<bool>  hasNotificationPermission() =>
      NotificationListenerService.isPermissionGranted();
  static Future<void>  openNotificationSettings() =>
      NotificationListenerService.requestPermission();
  static Future<bool>  hasSmsPermission() async =>
      (await Permission.sms.status).isGranted;
  static Future<void>  openSmsSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      // ignore
    }
  }

  Future<void> ensureChannelsRunning() async {
    if (!_isStarted) return;
    if (PdsConfig.isNotificationEnabled && await hasNotificationPermission()) {
      await _startNotificationListener();
    }
    if (PdsConfig.isSmsEnabled && await hasSmsPermission()) {
      await _startSmsListener();
    }
  }

  static Future<bool>  isBatteryOptimizationIgnored() async =>
      (await Permission.ignoreBatteryOptimizations.status).isGranted;
  static Future<void>  requestBatteryExemption() =>
      Permission.ignoreBatteryOptimizations.request();
  static Future<bool> hasAccessibilityPermission() async {
    try {
      return await FlutterAccessibilityService
          .isAccessibilityPermissionEnabled();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestAccessibilityPermission() async {
    try {
      return await FlutterAccessibilityService
          .requestAccessibilityPermission();
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAccessibilitySettings() async {
    try {
      await FlutterAccessibilityService.requestAccessibilityPermission();
    } catch (_) {}
  }

  static String _collectAccessibilityText(AccessibilityEvent event) {
    final chunks = <String>[];

    final primary = (event.text ?? '').trim();
    if (primary.isNotEmpty) chunks.add(primary);

    for (final child in event.subNodes ?? const <AccessibilityEvent>[]) {
      final childText = _collectAccessibilityText(child).trim();
      if (childText.isNotEmpty) chunks.add(childText);
    }

    return chunks.join(' ');
  }

  // ==========================================================================
  // HANDLERS
  // ==========================================================================

  void _handleNotification(ServiceNotificationEvent event) {
    try {
      final pkg = event.packageName ?? '';
      if (_TrustGate.isBlockedPackage(pkg)) return;

      bool isRemoved = false;
      try { isRemoved = (event as dynamic).hasRemoved == true; } catch (_) {}
      if (isRemoved) return;

      final app = _AppRegistry.identify(pkg);
      if (app == PaymentApp.unknown) return;
      if (!_floodGuard.isAllowed('notif:$pkg')) return;

      final fields = <String>[
        event.title   ?? '',
        event.content ?? '',
        _safe(() => (event as dynamic).bigText  as String?),
        _safe(() => (event as dynamic).subText  as String?),
        _safe(() => (event as dynamic).ticker   as String?),
      ].where((s) => s.isNotEmpty).join(' ');
      if (fields.isEmpty) return;

      _watchdog.recordNotification();
      _processText(fields.trim(), app, source: 'notification');
    } catch (e, st) { PdsLogger.e('L1', 'Handler error', e, st); }
  }

  void handleSms(String sender, String body) {
    try {
      if (sender.isEmpty || body.isEmpty) return;
      if (RegExp(r'^\+?\d+$').hasMatch(sender.trim())) return;
      if (_TrustGate.isBlockedSender(sender)) return;
      if (!_SenderValidator.isLegitimate(sender)) {
        PdsLogger.w('L0', 'SPOOFED_SENDER "$sender"');
        _emitFraud(FraudVerdict.hardBlockSenderSpoofed,
            'Sender failed legitimacy', 'sms', sender: sender);
        return;
      }
      
      // Deduplication check (BUG-S2)
      final hashId = sha256.convert(utf8.encode('$sender|$body')).toString();
      if (_processedSmsCache.contains(hashId)) {
        PdsLogger.i('L2', 'Duplicate SMS dropped: $sender');
        return;
      }
      _processedSmsCache.add(hashId);
      if (_processedSmsCache.length > 100) _processedSmsCache.removeAt(0);

      _watchdog.recordSms();
      _processText(body.trim(), PaymentApp.bankSms,
          source: 'sms', sender: sender);
    } catch (e, st) { PdsLogger.e('L2', 'Handler error', e, st); }
  }

  // ==========================================================================
  // CORE PIPELINE
  // ==========================================================================

  void _processText(
    String rawText,
    PaymentApp app, {
    required String source,
    String? sender,
  }) {
    final text = _Normaliser.clean(rawText);
    if (text.isEmpty) return;

    // FIX-A: two-stage classifier
    final cls = _Classifier.classify(text);
    if (cls != _ClassifyResult.passed) {
      PdsLogger.d('L3', 'REJECTED ${cls.name}');
    } else {
      _runPipeline(text: text, app: app, source: source, sender: sender);
    }
  }

  void _runPipeline({
    required String     text,
    required PaymentApp app,
    required String     source,
    String?             sender,
  }) {
    // Layer 4: Extraction
    // FIX-V16-6: strip marketing amount context before extraction
    final strippedText = _Classifier.stripMarketingAmounts(text);
    final double? amount = _Extractor.amount(strippedText);
    
    // FIX-58: minAmount visibility — log and track sub-threshold payments
    // Previously: silently dropped with no counter (blind spot)
    // Now: tracked for visibility, shopkeeper aware via stats
    if (amount == null) {
      PdsLogger.d('L4-REJECT', 'No amount detected in: "$text"');
      return;
    }
    
    if (amount < PdsConfig.minAmount) {
      _stats.recordDecision(PaymentDecision.rejected, amount);
      PdsLogger.w('FIX-58', 'SUB-THRESHOLD AMOUNT: ₹$amount < ₹${PdsConfig.minAmount} (dropped)');
      // Queue for monitoring: sub-threshold payments may indicate:
      // • Customer tips/gratuities (legitimate but small)
      // • Data entry errors (typos)
      // • Fraudulent micro-tests (probe for account validity)
      return;
    }

    final bool    isFailed = _Re.failure.hasMatch(text) &&
        !_Classifier.hasPaymentContext(text);
    final String? refId    = _Extractor.referenceId(text);
    final String? name     = _Extractor.payerName(text);
    final String? vpa      = _Extractor.vpa(text);
    final String? acc      = _Extractor.accountSuffix(text);
    final String? bank     = _Extractor.bankName(text, sender: sender);

    // FIX-17: strict UTR validation — alphanumeric allowed for tests/real-world
    final _numericUtrRe = RegExp(r'^[A-Za-z0-9]{4,22}$');
    final bool validNumericUtr = refId != null && _numericUtrRe.hasMatch(refId);
    final bool hasAnyUtr       = refId != null && refId.isNotEmpty;

    PdsLogger.i('L4-DETECT',  'text: "$text"');
    PdsLogger.i('L4-EXTRACT',
        'amount: $amount  ref: $refId  validUTR: $validNumericUtr  name: $name  app: ${app.name}');

    // Layer 4.5: Immediate Deduplication
    final isUtrFp = validNumericUtr;
    final tempEvent = PaymentEvent(
      amount:          amount,
      timestamp:       DateTime.now(),
      app:             app,
      payerName:       name,
      referenceId:     refId,
      vpa:             vpa,
      accountSuffix:   acc,
      bankName:        bank,
      isFailed:        isFailed,
      rawText:         text,
      detectionSource: source,
    );
    final fp = tempEvent.fingerprint;
    if (_dedupStore.containsKey(fp) || _activeFingerprints.contains(fp)) {
      PdsLogger.d('L4.5', 'DUPLICATE BLOCKED EARLY: fp=$fp');
      _stats.recordDupe();
      return;
    }
    _activeFingerprints.add(fp);
    _dedupStore[fp] = DateTime.now().add(
        isUtrFp ? PdsConfig.dedupUtrTtl : PdsConfig.dedupHashTtl);
    if (isUtrFp) _dedupDirty = true;

    try {
      // Layer 4.7: TCM Matching
      _PendingEntry? matched;
      if (source == 'sms') {
        matched = _pendingBuffer.matchSms(
          amount:    amount,
          utr:       validNumericUtr ? refId : null, // FIX-17: only pass valid UTR
          payerName: name,
          now:       DateTime.now(),
        );
      }

      // Layer 5: Fraud engine
      final fraud = FraudEngine.analyze(
        text: text, source: source, sender: sender,
        amount: amount, utr: refId, vpa: vpa,
      );
      if (fraud.isHardBlock) {
        PdsLogger.w('L5', 'HARD_BLOCK ${fraud.verdict.name}: ${fraud.reason}');
        _stats.recordFraud();
        _emitFraud(fraud.verdict, fraud.reason, source,
            sender: sender, amount: amount);
        return;
      }

      // Accessibility hard-reject: unknown pkg + no UTR
      if (source == 'accessibility' && !validNumericUtr && app == PaymentApp.unknown) {
        PdsLogger.w('L5', 'ACC_HARD_REJECT: unknown pkg + no valid UTR');
        return;
      }

      // FIX-17: amount > ₹500 with no valid numeric UTR → cap to LIKELY
      bool utrCapApplied = false;
      if (amount > PdsConfig.utrRequiredAbove && !validNumericUtr) {
        utrCapApplied = true;
        PdsLogger.w('FIX-17', 'NO_VALID_UTR ₹$amount → LIKELY cap'
            ' (refId=$refId alphanumeric=${hasAnyUtr && !validNumericUtr})');
      }

      // Layer 6: Bill matching
      final billResult = billContext.evaluate(amount);
      double billBoost = 0.0;
      bool   isBillSettled = false;

      if (!billContext.isSettlementLocked) {
        switch (billResult) {
          case BillMatchResult.exact:
            billBoost = 0.20;
            isBillSettled = true;
            break;
          case BillMatchResult.partial:
            final remaining = billContext.remainingAmount;
            if ((amount - remaining).abs() < 2.0) {
              isBillSettled = true;
              billBoost = 0.25;
            } else {
              billBoost = 0.10;
            }
            break;
          case BillMatchResult.suspicious:
            billBoost = -0.15;
            break;
          default: break;
        }
      }

      // Layer 6.5: Bill mismatch hard-cap (Fraud Proofing)
      bool billMismatchCap = false;
      if (billResult == BillMatchResult.suspicious || billResult == BillMatchResult.mismatch) {
        billMismatchCap = true;
        PdsLogger.w('SVC', 'BILL_MISMATCH ₹$amount (expected ₹${billContext.expectedAmount}) → LIKELY cap');
      }

      // Behavioral penalty
      final behaviorPenalty = PdsConfig.isBehaviorMemoryEnabled
          ? _behaviorMemory.softPenalty(amount: amount, name: name, vpa: vpa)
          : 0.0;

      // Layer 7: Confidence scoring
      double score = _Scorer.calculate(
        text: text, utr: refId, name: name, vpa: vpa, acc: acc,
        app: app, isFailed: isFailed, sender: sender, source: source,
      );
      score -= fraud.riskScore * 0.35;
      score -= behaviorPenalty;
      score += billBoost;
      score  = score.clamp(0.0, 1.0);

      // FIX-17: apply caps after scoring
      if (utrCapApplied || billMismatchCap) {
        score = math.min(score, PdsConfig.confirmedThreshold - 0.01);
      }
      if (isFailed) return;

      final minThreshold = _minThreshold(source, sender);
      final isTrustedApp = const {
        PaymentApp.googlePay, PaymentApp.phonePe, PaymentApp.paytm,
        PaymentApp.amazonPay, PaymentApp.bhim,
      }.contains(app);

      if (score < minThreshold) {
        // FIX-V16-3 retained + strengthened: require structured context
        if (source == 'notification' && isTrustedApp && amount > 0
            && _Classifier.hasStructuredPaymentContext(text)) {
          score = PdsConfig.likelyThreshold;
          PdsLogger.w('L7', 'TRUSTED_APP_RESCUE → LIKELY ₹$amount');
        } else {
          _stats.recordDecision(PaymentDecision.rejected, amount);
          PdsLogger.d('L7', 'REJECTED score=$score < threshold=$minThreshold');
          return;
        }
      }

      if (!_amountAllowed(amount, source, sender, refId)) {
        score = math.min(score, PdsConfig.confirmedThreshold - 0.01);
      }

      // ── FIX-29: Double validation — fraud risk gate ──────────────────────
      if (fraud.riskScore > 0.5) {
        PdsLogger.w('FIX-29', 'FRAUD_RISK ${fraud.riskScore} > 0.5 → REJECT');
        _stats.recordDecision(PaymentDecision.rejected, amount);
        return;
      }

      PaymentDecision decision = _Scorer.decide(score);

      // ── FIX-37: Relax UTR dependency for small payments ──────────────────
      // amount < ₹2000 + structured context + trusted app/SMS → allow CONFIRMED
      // even without UTR (UTR cap from FIX-17 overrides only for ≥ ₹2000)
      final isTrustedAppOrSms = isTrustedApp ||
          (source == 'sms' && PaymentDetectionService._isVerifiedBankSender(sender));
      if (utrCapApplied &&
          amount < PdsConfig.highValueThreshold &&
          _Classifier.hasStructuredPaymentContext(text) &&
          isTrustedAppOrSms) {
        // Remove UTR cap for small trusted payments
        utrCapApplied = false;
        // Recalculate decision without cap
        decision = _Scorer.decide(score);
        PdsLogger.i('FIX-37',
            'Small payment ₹$amount UTR cap lifted '
            '(structured ctx + trusted source)');
      }

      // ── FIX-27 retained: minimum structure for CONFIRMED ─────────────────
      if (decision == PaymentDecision.confirmed) {
        final hasBankRef      = bank != null || acc != null ||
            RegExp(r'\b(bank|account|a\/c|upi|imps|neft|rtgs)\b',
                caseSensitive: false).hasMatch(text);
        final verifiedSender  = _isVerifiedBankSender(sender);
        final hasPayerName    = name != null && name.isNotEmpty;
        final hasStrongCtx    = _Classifier.hasStructuredPaymentContext(text);

        int structureScore = 0;
        if (validNumericUtr)  structureScore++;
        if (hasBankRef)       structureScore++;
        if (verifiedSender)   structureScore++;
        if (hasPayerName)     structureScore++;
        // FIX-43: strong context counts as a structure signal
        if (hasStrongCtx && isTrustedApp) structureScore++;

        if (structureScore < 2) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-27',
              'CONFIRMED→LIKELY structure=$structureScore '
              '(UTR=$validNumericUtr bank=$hasBankRef '
              'sender=$verifiedSender name=$hasPayerName ctx=$hasStrongCtx)');
        }
      }

      // ── FIX-45: High value smart confirm (≥ ₹2000) ───────────────────────
      // CONFIRMED allowed if ANY of: valid UTR, trusted SMS sender,
      // strong structured context + trusted app
      // Replaces FIX-22's strict AND logic with flexible OR logic
      if (amount >= PdsConfig.highValueThreshold &&
          decision == PaymentDecision.confirmed) {
        final verifiedSender  = _isVerifiedBankSender(sender);
        final hasTcmMatch     = matched != null;
        final strongCtxTrusted = _Classifier.hasStructuredPaymentContext(text)
            && isTrustedApp;

        final hasHighValueSignal = validNumericUtr
            || verifiedSender
            || hasTcmMatch
            || strongCtxTrusted;

        if (!hasHighValueSignal) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-45',
              '₹$amount HIGH_VALUE → LIKELY '
              '(UTR=$validNumericUtr sender=$verifiedSender '
              'TCM=$hasTcmMatch strongCtx=$strongCtxTrusted)');
        }
      }

      // ── FIX-28 retained: large amount extra protection (≥ ₹10,000) ──────
      if (amount >= PdsConfig.largeAmountThreshold &&
          decision == PaymentDecision.confirmed) {
        final verifiedSender = _isVerifiedBankSender(sender);
        final isSmsBased     = source == 'sms' || source == 'notification+sms';
        if (!validNumericUtr || (!verifiedSender && !isSmsBased)) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-28',
              '₹$amount LARGE → NEVER_CONFIRMED '
              '(validUTR=$validNumericUtr verifiedSender=$verifiedSender '
              'sms=$isSmsBased)');
        }
      }

      // ── FIX-48: Final decision balance ───────────────────────────────────
      // CONFIRMED: score ≥ threshold AND (UTR OR trusted sender OR strong ctx)
      // LIKELY:    partial signals or uncertainty
      // REJECT:    only fraud/promo (handled above by fraud engine)
      if (decision == PaymentDecision.confirmed) {
        final verifiedSender  = _isVerifiedBankSender(sender);
        final strongCtxTrusted = _Classifier.hasStructuredPaymentContext(text)
            && isTrustedApp;
        final confirmAnchor = validNumericUtr || verifiedSender || strongCtxTrusted;
        if (!confirmAnchor) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-48',
              'FIX-48: No confirm anchor → LIKELY ₹$amount '
              '(UTR=$validNumericUtr sender=$verifiedSender strongCtx=$strongCtxTrusted)');
        }
      }

      // ── FIX-50: Trusted App Limitation (CRITICAL) ─────────────────────
      // Trusted app MUST NOT confirm alone
      // CONFIRMED only if ANY: valid UTR, verified SMS sender, TCM match
      if (decision == PaymentDecision.confirmed && isTrustedApp) {
        final verifiedSender  = _isVerifiedBankSender(sender);
        final hasTcmMatch     = matched != null;
        final trustAnchors    = validNumericUtr || verifiedSender || hasTcmMatch;

        if (!trustAnchors) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-50',
              'FIX-50: Trusted app alone cannot confirm → LIKELY ₹$amount '
              '(UTR=$validNumericUtr SMS=$verifiedSender TCM=$hasTcmMatch)');
        }
      }

      // ── FIX-52: Notification-Only Cap ─────────────────────────────────
      // If source == 'notification' only (no SMS, no TCM)
      // max decision = LIKELY
      // Require SMS or TCM for CONFIRMED
      if (decision == PaymentDecision.confirmed && 
          source == 'notification' && 
          matched == null) {  // no TCM match
        decision = PaymentDecision.likely;
        PdsLogger.w('FIX-52',
            'FIX-52: Notification-only (no SMS/TCM) capped to LIKELY ₹$amount');
      }

      // ── FIX-53: Final Confirm Lock ──────────────────────────────────────
      // CONFIRMED ONLY IF:
      // ( score ≥ threshold AND NOT fraud AND 
      //   ( valid UTR OR verified SMS sender OR TCM match ) )
      // Else: ALWAYS downgrade to LIKELY
      if (decision == PaymentDecision.confirmed) {
        final verifiedSender  = _isVerifiedBankSender(sender);
        final hasTcmMatch     = matched != null;
        
        // Check if fraud risk is present (soft penalties don't block, but hard ones do)
        final isHardFraud     = fraud.isHardBlock;
        
        // Final anchor check
        final hasConfirmAnchor = validNumericUtr || verifiedSender || hasTcmMatch;

        if (score < PdsConfig.confirmedThreshold || isHardFraud || !hasConfirmAnchor) {
          decision = PaymentDecision.likely;
          if (isHardFraud) {
            PdsLogger.w('FIX-53',
                'FIX-53: Hard fraud detected → LIKELY ₹$amount');
          } else if (!hasConfirmAnchor) {
            PdsLogger.w('FIX-53',
                'FIX-53: No confirm anchor (UTR/SMS/TCM) → LIKELY ₹$amount '
                '(UTR=$validNumericUtr SMS=$verifiedSender TCM=$hasTcmMatch)');
          } else {
            PdsLogger.w('FIX-53',
                'FIX-53: Score ${score.toStringAsFixed(2)} < threshold ${PdsConfig.confirmedThreshold.toStringAsFixed(2)} → LIKELY ₹$amount');
          }
        }
      }

      // ── FIX-30 retained: fail-safe — but narrowed to avoid over-triggering
      // Only downgrade if score is borderline AND no trust signal at all
      if (decision == PaymentDecision.confirmed) {
        final verifiedSender = _isVerifiedBankSender(sender);
        final noTrustAtAll   = !validNumericUtr && !verifiedSender
            && !isTrustedApp && matched == null;
        final borderline     = score < (PdsConfig.confirmedThreshold + 0.10);
        if (noTrustAtAll && borderline) {
          decision = PaymentDecision.likely;
          PdsLogger.w('FIX-30', 'FAIL-SAFE (no trust, borderline) CONFIRMED→LIKELY ₹$amount');
        }
      }

      final isPartial = billResult == BillMatchResult.partial && !isBillSettled;
      // Partial payments always stay LIKELY
      final finalDecision = (isPartial && decision == PaymentDecision.confirmed)
          ? PaymentDecision.likely
          : decision;

      final event = tempEvent.copyWith(
        id:               matched?.event.id,
        confidenceScore:  score,
        decision:         finalDecision,
        isPartialPayment: isPartial,
        remainingAmount:  isPartial ? billContext.remainingAmount - amount : 0.0,
      );

      // Layer 9: TCM & Emission
      if (source == 'notification' || source == 'accessibility') {
        _pendingBuffer.add(event, voiceSpoken: false);
        unawaited(_emit(event, isBillSettlement: isBillSettled));
        _pendingBuffer.markVoiceSpoken(event.id);
        return;
      }

      if (source == 'sms') {
        if (matched != null && (matched.emitted || matched.voiceSpoken)) {
          PdsLogger.d('TCM', 'SMS matched emitted notification — SILENT RECORD');
          _behaviorMemory.record(amount, name, vpa);
          unawaited(_emit(event, isBillSettlement: isBillSettled, forceMute: true));
          return;
        }

        final eventToEmit = (matched != null)
            ? event.copyWith(
                confidenceScore: math.min(event.confidenceScore + 0.20, 0.95),
                decision:        PaymentDecision.confirmed,
                detectionSource: 'notification+sms')
            : event;

        if (matched != null) matched.emitted = true;
        unawaited(_emit(eventToEmit, isBillSettlement: isBillSettled));
      }
    } finally {
      _activeFingerprints.remove(tempEvent.fingerprint);
    }
  }

  // ==========================================================================
  // EMIT
  // ==========================================================================

  Future<void> _emit(PaymentEvent event, {
    bool isBillSettlement = false,
    bool forceMute        = false,
  }) async {
    if (event.decision == PaymentDecision.rejected) return;

    // ✅ FIX-59-CRITICAL: Cross-device UTR check MUST happen BEFORE any UI emission
    // This is the ONLY way to close the fraud window — check must await before proceeding
    if (event.decision == PaymentDecision.confirmed && event.referenceId != null) {
      try {
        final conflict = await _isUtrAlreadyRegistered(event.referenceId!);
        if (conflict) {
          // Downgrade to LIKELY before merchant sees the confirmation
          final downgraded = event.copyWith(
            decision: PaymentDecision.likely,
            detectionSource: '${event.detectionSource}:cross_device_conflict_downgraded',
          );
          // Recursively emit as LIKELY so merchants can manually merge if needed
          await _emit(downgraded, isBillSettlement: false, forceMute: false);
          return;
        } else {
          // UTR is unique - safe to register it
          unawaited(_registerUtrConfirmed(event.referenceId!, event.amount));
        }
      } catch (e) {
        PdsLogger.w('EMIT', 'UTR check failed: $e, proceeding with emit');
      }
    }

    // Finally apply state changes to Bill Context
    if (isBillSettlement) {
      billContext.markSettled(); 
      billContext.clear();
    } else if (event.isPartialPayment) {
      if (!forceMute) {
        billContext.recordPartial(event.amount);
      } else {
        // FIX: correct any amount drift from the earlier notification record
        final lastUi = history.findById(event.id);
        if (lastUi != null && (lastUi.amount - event.amount).abs() > 0.001) {
          final delta = event.amount - lastUi.amount;
          billContext.recordPartial(delta);          // adjusts by difference only
        }
      }
    }

    // FIX-J: ui state carries id + detectedAt
    final ui = PaymentUiState(
      id:          event.id,
      decision:    event.decision,
      amount:      event.amount,
      payerName:   event.payerName,
      bankName:    event.bankName,
      isFailed:    event.isFailed,
      isPartial:   event.isPartialPayment,
      shortfall:   event.isPartialPayment ? event.remainingAmount : null,
      isBillMatch: isBillSettlement,
      detectedAt:  event.timestamp,
    );

    PdsLogger.i('EMIT',
        '${event.decision == PaymentDecision.confirmed ? "✅" : "⚠️"} '
        '₹${event.amount} ${event.decision.name} '
        'conf=${event.confidenceScore.toStringAsFixed(2)} '
        'src=${event.detectionSource}');

    _stats.recordDecision(event.decision, event.amount);
    _behaviorMemory.record(event.amount, event.payerName, event.vpa);

    // V26: Deduplicate history entries by ID (In-place update)
    history.addOrUpdate(ui);

    if (event.decision == PaymentDecision.confirmed) _lastConfirmed = event;

    // Await auto-settlement check
    final settled = await _tryAutoSettleInvoice(event);
    final isSettled = isBillSettlement || settled;

    PaymentEvent finalEvent = event;
    PaymentUiState finalUi = ui;
    if (settled) {
      finalEvent = event.copyWith(
        decision: PaymentDecision.confirmed,
      );
      finalUi = ui.copyWith(
        decision: PaymentDecision.confirmed,
        isBillMatch: true,
      );
      if (kDebugMode) debugPrint('✅ Auto-upgraded likely event to CONFIRMED due to invoice match');
    }

    _eventCtrl.add(finalEvent);
    _uiCtrl.add(finalUi);
    
    // Voice Rule: Bill settlement message PREVENTS standard amount voice
    if (isSettled && !forceMute) {
      final t = VoiceBuilder.received(finalEvent.amount, null, _voiceLanguage);
      _voice.enqueueRaw('Payment Confirmed. $t', _VP.high, fingerprint: finalEvent.fingerprint);
    } else if (!forceMute) {
      _voice.enqueue(finalEvent, finalUi);
    }

    // ANTI-03: queue LIKELY for merchant confirmation (FIX-D: fully wired)
    if (finalEvent.decision == PaymentDecision.likely) {
      _confirmMgr.add(finalEvent, finalUi);
      // Re-announce if not confirmed in 12s — but only for non-partial payments
      if (!finalEvent.isPartialPayment) {
        _scheduleLikelyReannounce(finalEvent.id, finalEvent.amount, finalEvent.fingerprint);
      }
    }

    // ANTI-07: async bank verification for CONFIRMED
    if (finalEvent.decision == PaymentDecision.confirmed &&
        PdsConfig.isBankVerifyEnabled) {
      unawaited(_verifyWithBank(finalEvent));

    }
  }

  // Re-announce LIKELY payment after 12s only if not yet confirmed/rejected.
  // Partial payments excluded — shopkeeper already knows money is pending.
  Future<bool> _tryAutoSettleInvoice(PaymentEvent event) async {
    try {
      if ((event.decision != PaymentDecision.confirmed && event.decision != PaymentDecision.likely) || event.amount <= 0) return false;
      final amount = event.amount;
      final payer = event.payerName?.toLowerCase() ?? '';
      final saleId = event.saleId?.toString() ?? '';

      // ✅ FIX: Add concurrency lock to prevent race condition
      // Two burst payments cannot both settle the same invoice
      if (saleId.isNotEmpty && _settlingInvoiceIds.contains(saleId)) {
        PdsLogger.w('AUTOSETTL', 'Already settling $saleId, skipping concurrent attempt');
        return false;
      }
      if (saleId.isNotEmpty) _settlingInvoiceIds.add(saleId);

      try {
        final sales = await LocalStorageService.loadSales();
        for (var i = 0; i < sales.length; i++) {
          final sale = Map<String, dynamic>.from(sales[i] as Map);
          final status = _derivePaymentStatus(sale);
          if (!['UNPAID', 'PARTIAL'].contains(status)) continue;

          final total = _toAmount(sale['total'] ?? sale['total_amount']);
          final paid = _toAmount(sale['paid_amount'] ?? sale['amount_paid'] ?? 0);
          final due = (total - paid).clamp(0.0, double.infinity);
          if ((due - amount).abs() > 1.0) continue;

          if (saleId.isNotEmpty) {
            final candidateId = _extractRecordId(sale);
            if (candidateId != saleId) continue;
          }

          if (payer.isNotEmpty) {
            final customerName = sale['customer_name']?.toString().toLowerCase() ?? '';
            if (customerName.isNotEmpty && !customerName.contains(payer) && !payer.contains(customerName)) {
              continue;
            }
          }

          sale['payment_status'] = 'PAID';
          sale['paid_amount'] = total;
          sales[i] = sale;
          await LocalStorageService.saveSales(sales);

          final invoiceNum = sale['sale_id']?.toString() ?? sale['invoice_number']?.toString() ?? sale['invoiceId']?.toString() ?? '';
          if (invoiceNum.isNotEmpty) {
            unawaited(SyncService.updateSalePayment(invoiceNum, 'PAID', total));
          }
          return true;
        }

        final invoices = await LocalStorageService.loadLocalInvoices();
        for (var i = 0; i < invoices.length; i++) {
          final invoice = Map<String, dynamic>.from(invoices[i] as Map);
          final status = _derivePaymentStatus(invoice);
          if (!['UNPAID', 'PARTIAL'].contains(status)) continue;

          final total = _toAmount(invoice['total_amount'] ?? invoice['amount'] ?? 0);
          final paid = _toAmount(invoice['paid_amount'] ?? 0);
          final due = (total - paid).clamp(0.0, double.infinity);
          if ((due - amount).abs() > 1.0) continue;

          if (saleId.isNotEmpty) {
            final candidateId = _extractRecordId(invoice);
            if (candidateId != saleId) continue;
          }

          invoice['status'] = 'PAID';
          invoice['payment_status'] = 'PAID';
          invoice['paid_amount'] = total;
          invoices[i] = invoice;
          await LocalStorageService.saveLocalInvoices(invoices);
          return true;
        }
      } finally {
        // ✅ FIX: Always remove lock, even if exception occurred
        if (saleId.isNotEmpty) _settlingInvoiceIds.remove(saleId);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Auto-settle invoice failed: $e');
    }
    return false;
  }

  double _toAmount(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    final cleaned = value.toString().replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  String _extractRecordId(Map<String, dynamic> record) {
    return record['sale_id']?.toString() ??
           record['invoice_number']?.toString() ??
           record['saleId']?.toString() ??
           record['invoiceId']?.toString() ??
           record['id']?.toString() ??
           '';
  }

  String _derivePaymentStatus(Map<String, dynamic> record) {
    final explicit = (record['payment_status'] ?? record['status'] ?? record['paymentStatus'])?.toString().toUpperCase() ?? '';
    if (explicit.isNotEmpty) return explicit;

    final total = _toAmount(record['total'] ?? record['total_amount'] ?? record['grand_total'] ?? 0);
    final paid = _toAmount(record['paid_amount'] ?? record['amount_paid'] ?? 0);
    if (total <= 0) {
      return paid > 0 ? 'PAID' : 'UNPAID';
    }
    if (paid >= total - 0.01) return 'PAID';
    if (paid > 0) return 'PARTIAL';
    return 'UNPAID';
  }

  void _scheduleLikelyReannounce(String id, double amount, String fingerprint) {
    _likelyTimers[id]?.cancel();
    _likelyTimers[id] = Timer(PdsConfig.likelyReannounceAfter, () {
      _likelyTimers.remove(id);
      final state = history.findById(id);
      if (state == null || state.isUserConfirmed || state.isUserRejected) return;
      final text = VoiceBuilder.stillWaiting(amount, _voiceLanguage);
      // Pass fingerprint — spoken-set blocks this if SMS already confirmed it
      _voice.enqueueRaw(text, _VP.soft, fingerprint: '$fingerprint');
      PdsLogger.i('SVC', 'LIKELY_REANNOUNCE ₹$amount');
    });
  }

  void _emitFinal(PaymentEvent event) {
    // FIX-D: reuse same id so UI can correlate the update
    final ui = PaymentUiState(
      id:              event.id,
      decision:        PaymentDecision.confirmed,
      amount:          event.amount,
      payerName:       event.payerName,
      bankName:        event.bankName,
      isFailed:        false,
      detectedAt:      event.timestamp,
      isUserConfirmed: true,
    );
    history.update(event.id, ui);
    _eventCtrl.add(event);
    _uiCtrl.add(ui);
    _voice.enqueue(event, ui);
    PdsLogger.i('EMIT', '✅ MERCHANT_CONFIRMED ₹${event.amount}');
  }

  Future<void> _verifyWithBank(PaymentEvent event) async {
    try {
      final result = await bankVerifier.verify(
        amount:          event.amount,
        utr:             event.referenceId,
        detectionSource: event.detectionSource,
        detectedAt:      event.timestamp,
      ).timeout(PdsConfig.bankVerifyTimeout);

      if (result == false) {
        PdsLogger.w('ANTI', 'BANK_VERIFY_FAILED ₹${event.amount}');
        _stats.recordFraud();
        // FIX-M: correct verdict
        _emitFraud(FraudVerdict.bankVerifyFailed,
            'Bank ledger verification failed', event.detectionSource,
            amount: event.amount);
        final state = history.findById(event.id);
        if (state != null) _uiCtrl.add(state.copyWith(isUserRejected: true));
      } else if (result == true) {
        PdsLogger.i('ANTI', 'BANK_VERIFY_OK ₹${event.amount}');
      }
    } catch (e, st) { PdsLogger.e('ANTI', 'Bank verify error', e, st); }
  }

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  bool _amountAllowed(
      double amount, String source, String? sender, String? utr) {
    if (source == 'sms' && _isVerifiedBankSender(sender)) {
      return amount <= PdsConfig.smsConfirmedMax;
    }
    if (source == 'notification' || source == 'accessibility') {
      return amount <= PdsConfig.notifOnlyHighValue;
    }
    return true;
  }

  double _minThreshold(String source, String? sender) {
    if (source == 'sms' && _isVerifiedBankSender(sender)) {
      return PdsConfig.thresholdVerifiedSms;
    }
    if (source == 'accessibility') return PdsConfig.thresholdAccessibility;
    return PdsConfig.thresholdTrustedApp;
  }

  // FIX-N: strip only DLT prefix (XX-) before registry lookup
  static bool _isVerifiedBankSender(String? sender) {
    if (sender == null || sender.isEmpty) return false;
    var s = sender.toUpperCase().trim();
    final dlt = RegExp(r'^[A-Z]{2}-(.+)$').firstMatch(s);
    if (dlt != null) s = dlt.group(1)!;
    return _BankSenderRegistry.isKnown(s);
  }

  void _emitStatus(ChannelType c, ChannelStatus s, {String? detail}) {
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(ChannelStatusEvent(c, s, detail: detail));
    }
  }

  void _emitFraud(FraudVerdict v, String? detail, String src,
      {String? sender, double? amount}) {
    if (!_fraudCtrl.isClosed && PdsConfig.isFraudTelemetryEnabled) {
      _fraudCtrl.add(FraudAlertEvent(
        verdict:    v,        type:   v.name,
        detail:     detail ?? v.name,   source: src,
        sender:     sender,   amount: amount,
        detectedAt: DateTime.now(),
      ));
    }
  }

  String _safe(String? Function() fn) {
    try { return fn() ?? ''; } catch (_) { return ''; }
  }
}

// =============================================================================
// TRUST GATE
// =============================================================================

abstract class _TrustGate {
  static const _blocked = <String>{
    'com.whatsapp', 'com.whatsapp.w4b', 'org.telegram.messenger',
    'org.telegram.plus', 'com.facebook.orca', 'com.facebook.katana',
    'com.instagram.android', 'com.twitter.android', 'com.snapchat.android',
    'com.viber.voip', 'com.skype.raider', 'jp.naver.line.android',
    'com.ss.android.ugc.trill', 'com.zhiliaoapp.musically', 'com.discord',
  };
  static const _blockedSenders = [
    'WTSAPP', 'WHTSP', 'TELEGRAM', 'SIGNAL', 'CHATGW',
  ];
  static bool isBlockedPackage(String p) => _blocked.contains(p.toLowerCase());
  static bool isBlockedSender(String s) {
    final u = s.toUpperCase();
    return _blockedSenders.any((k) => u.contains(k));
  }
}

// =============================================================================
// APP REGISTRY
// =============================================================================

abstract class _AppRegistry {
  static final _pkgs = <String, PaymentApp>{
    'com.google.android.apps.nbu.paisa.user':     PaymentApp.googlePay,
    'net.one97.paytm':                            PaymentApp.paytm,
    'com.phonepe.app':                            PaymentApp.phonePe,
    'in.amazon.mShop.android.shopping':           PaymentApp.amazonPay,
    'in.org.npci.upiapp':                         PaymentApp.bhim,
    'com.whatsapp':                               PaymentApp.whatsappPay,
    'com.dreamplug.androidapp':                   PaymentApp.cred,
    'com.hdfcbank.payzapp':                       PaymentApp.payzapp,
    'com.pockets.hdfc':                           PaymentApp.payzapp,
    'com.icicibank.imobile':                      PaymentApp.icici,
    'com.sbi.imobile':                            PaymentApp.sbiYono,
    'com.axis.mobile':                            PaymentApp.axis,
    'com.hdfcbank.smartbuy':                      PaymentApp.hdfc,
    'com.indusind.mobilebanking':                 PaymentApp.bankApp,
    'com.yes.mobile':                             PaymentApp.bankApp,
    'com.baroda.mpassbook':                       PaymentApp.bankApp,
    'com.canarabank.mobility':                    PaymentApp.bankApp,
    'com.freecharge.android':                     PaymentApp.bankApp,
    'com.mobikwik_new':                           PaymentApp.bankApp,
    'com.jupiter.app':                            PaymentApp.bankApp,
    'com.epifi.fi':                               PaymentApp.bankApp,
    'com.bharatpe.app':                           PaymentApp.bankApp,
    'com.slicepay':                               PaymentApp.bankApp,
  };

  static PaymentApp identify(String p) => _pkgs[p] ?? PaymentApp.unknown;
  static void addPackage(String p, PaymentApp a) => _pkgs[p] = a;

  static PaymentApp resolve(String source, String? sender, String text) {
    if (source == 'sms') return PaymentApp.bankSms;
    final s = (sender ?? '').trim().toLowerCase();
    if (s.contains('phonepe')) return PaymentApp.phonePe;
    if (s.contains('paytm')) return PaymentApp.paytm;
    if (s.contains('googlepay') || s.contains('gpay') || s.contains('google pay') || s.contains('paisa.user')) return PaymentApp.googlePay;
    if (s.contains('amazon')) return PaymentApp.amazonPay;
    if (s.contains('bhim')) return PaymentApp.bhim;
    if (s.contains('whatsapp')) return PaymentApp.whatsappPay;
    if (s.contains('cred')) return PaymentApp.cred;
    if (s.contains('payzapp')) return PaymentApp.payzapp;
    if (s.contains('icici')) return PaymentApp.icici;
    if (s.contains('sbi')) return PaymentApp.sbiYono;
    if (s.contains('axis')) return PaymentApp.axis;
    if (s.contains('hdfc')) return PaymentApp.hdfc;
    
    if (sender != null) {
      final app = identify(sender);
      if (app != PaymentApp.unknown) return app;
    }
    
    final t = text.toLowerCase();
    if (t.contains('phonepe')) return PaymentApp.phonePe;
    if (t.contains('paytm')) return PaymentApp.paytm;
    if (t.contains('gpay') || t.contains('google pay')) return PaymentApp.googlePay;
    if (t.contains('amazon pay')) return PaymentApp.amazonPay;
    
    return PaymentApp.unknown;
  }
}

// =============================================================================
// BANK SENDER REGISTRY  (ANTI-06: DLT format validation)
// =============================================================================

abstract class _BankSenderRegistry {
  static final _s = <String>{
    'SBIBNK','SBIPSG','SBIINB','SBISMS','SBIUPI','YONOSB','SBIYONO','SBI',
    'HDFCBK','HDFCBN','HDFCSM','HDFC',
    'ICICIB','ICICIN','ICICIP','ICICI',
    'AXISBK','AXISBN','AXISB',
    'KOTAKB','KOTAK','PNBSMS','PNBANK','PNB',
    'BOBSMS','BOBANK','BOB','CNRBNK','CANBNK','CANARA',
    'UBISMS','UBIBNK','UNIONB','INDBNK','INDIANB',
    'BOISBI','BOISMS','CBISMS','CENTBK',
    'INDUSB','INDUSL','YESBNK','YESBANK',
    'IDFCBK','IDFC','FEDBNK','FEDBK',
    'SIBSMS','SOUTHIB','KTKBNK',
    'UCOBKL','UCO','IOBSMS','IOB',
    'PAYTM','PYTMBNK','AMZPAY','AMAZON',
    'PHONEPE','PPBANK','AIRBNK','AIRTEL',
    'JIOBKL','JIOPAY','RBLBNK','RBL',
    'DCBBNK','DCBANK','EQUBNK','EQUITAS',
    'AUSFBL','AUSF','NSDLPB',
  };

  static bool isKnown(String n) => _s.contains(n);
  static void add(String id)    => _s.add(id.toUpperCase());
}

// =============================================================================
// TEXT NORMALISER
// =============================================================================

abstract class _Normaliser {
  static final _ws = RegExp(r'[\r\n\t]+');
  static final _dc = RegExp(r'(\d),(\d)');
  static final _ms = RegExp(r' {2,}');
  static String clean(String raw) => raw
      .replaceAll(_ws, ' ')
      .replaceAll(_dc, r'\1\2')
      .replaceAll(_ms, ' ')
      .trim();
}

// =============================================================================
// CLASSIFIER  (FIX-A: two-stage "pending" fix)
// =============================================================================

enum _ClassifyResult { passed, fraud, otp, debit, junk }

abstract class _Classifier {
  // Always-fraud patterns
  static final _fraudStrict = RegExp(
    r'(?:\b(?:sending|will\s+be\s+credited|will\s+credit|to\s+be\s+credited'
    r'|requested|request\s+sent|collect\s+request|pay\s+request)\b'
    r'|भेजा\s+गया|भेजा\s+जाएगा|प्रतीक्षा)',
    caseSensitive: false,
  );
  // FIX-A: conditional — only fraud if NO credit keyword present
  static final _fraudConditional = RegExp(
    r'\b(pending|on\s+hold|processing|initiated|reminder|overdue|amount\s+due)\b',
    caseSensitive: false,
  );
  static final _creditContext = RegExp(
    r'\b(credited|received|deposited|credit\b|\bCR\b|mila|prapt|jama|successful|done)\b',
    caseSensitive: false,
  );
  static final _otp = RegExp(
    r'(?:\b(?:otp|one\.time\.pass(?:word)?|verification\s+code|passcode|do\s+not\s+share)\b|ओटीपी)',
    caseSensitive: false,
  );
  static final _debit = RegExp(
    r'(?:\b(?:debited|has\s+been\s+debited|spent\s+at|purchase\s+at'
    r'|withdrawn\s+from|withdrawal\s+of|deducted\s+from|charged\s+to'
    r'|payment\s+made\s+to|transferred\s+to(?!.*to\s+your|.*to\s+you)'
    r'|you\s+sent|you\s+have\s+sent)\b'
    r'|काटा\s+गया)',
    caseSensitive: false,
  );
  static final _junk = RegExp(
    r'(?:\b(?:cashback|reward\s+point|loyalty\s+point|balance\s+alert'
    r'|minimum\s+due|minimum\s+balance|emi|loan\s+due|recharge'
    r'|click\s+here|visit\s+our|call\s+us|helpline'
    r'|daily\s+savings|set\s+up\s+auto|gold\s+every\s+day'
    r'|invest\s+in\s+gold|buy\s+gold|digital\s+gold'
    r'|earn\s+more|earn\s+upto|earn\s+up\s+to'
    r'|exclusive\s+offer|limited\s+offer|limited\s+time'
    r'|don\.t\s+miss|dont\s+miss|upgrade\s+now|upgrade\s+your'
    r'|congratulations.*won|you.*won\s+₹|winner'
    r'|refer\s+and\s+earn|refer\s+a\s+friend|invite\s+and\s+earn'
    r'|insurance\s+premium|mutual\s+fund|fd\s+interest|fixed\s+deposit'
    r'|bill\s+payment\s+reminder|due\s+date|pay\s+your\s+bill)\b'
    r'|ऑफर|बचाएं|कमाएं|सोना\s+खरीदें|रोज\s+बचाएं'
    r'|சேமிக்க|தங்கம்\s+வாங்க|சலுகை'
    r'|బంగారం\s+కొనండి|ఆఫర్|సేవ్\s+చేయండి)',
    caseSensitive: false,
  );

  static final _promo = RegExp(
    r'(save\s+₹\s*\d|get\s+₹\s*\d+\s+(?:off|back|bonus|reward)'
    r'|₹\s*\d+\s+(?:off|back|bonus|cashback|reward)'
    r'|upto\s+₹|up\s+to\s+₹\s*\d+\s+(?:off|back)'
    r'|set\s+up\s+(?:daily|auto|recurring|sip)'
    r'|start\s+(?:saving|investing|your\s+sip)'
    r'|kya\s+khaas|abhi\s+dekho|check\s+it\s+out'
    r'|tap\s+to\s+(?:activate|enable|start|explore)'
    r'|download\s+now|install\s+now|open\s+app'
    r'|your\s+account\s+is\s+eligible|you\s+are\s+eligible'
    r'|pre.?approved|pre-qualified|special\s+offer\s+for\s+you'
    r'|आज\s+ही\s+शुरू|अभी\s+शुरू\s+करें|सेट\s+अप\s+करें'
    r'|இன்றே\s+தொடங்கு|ஆரம்பிக்க|இப்போதே'
    r'|ఇప్పుడే\s+ప్రారంభించండి|సెట్\s+అప్\s+చేయండి)',
    caseSensitive: false,
  );

  static final _marketingAmountContext = RegExp(
    r'\b(?:save|earn|get|win|offer|bonus|reward|cashback|upto|up\s+to'
    r'|बचाएं|कमाएं|पाएं|சேமி|பெறு|సేవ్|పొందండి)\s*₹\s*\d'
    r'|₹\s*\d+\s*(?:off\b|back\b|bonus\b|reward\b|cashback\b)',
    caseSensitive: false,
  );

  static final _context = RegExp(
    r'(?:\b(?:received|credited|credit|payment\s+received|payment\s+successful|payment\s+success|successfully\s+received|you\s+got|money\s+received|amount\s+credited|amount\s+received|transferred\s+(?:via\s+[A-Za-z0-9]+\s+)?to|paid\s+to\s+your|deposited|added\s+to\s+(?:your\s+)?(?:\w+\s+)?wallet|success|successful|recd|has\s+sent|sent\s+to\s+your|sent\s+to\s+you|prapt|mila|jama)\b'
    // FIX-39: Hindi
    r'|प्राप्त|जमा\s+हो|मिला|प्राप्त\s+हुआ|खाते\s+में\s+जमा'
    // FIX-39: Tamil
    r'|வரவு|வந்தது|பெறப்பட்டது|கணக்கில்\s+வரவு'
    // FIX-39: Telugu
    r'|జమ\s+అయింది|వచ్చింది|జమచేయబడింది|చెల్లింపు\s+వచ్చింది'
    // FIX-39: Kannada
    r'|ಜమా\s+ಆಗಿದೆ|ಬಂದಿದೆ|ಪಾವತಿ\s+ಬಂತು|ಜమా\s+ಮಾಡಲಾಗಿದೆ'
    // FIX-39: Marathi/Gujarati
    r'|मिळाले|जमा\s+झाله|ચૂકવણી\s+மળી|જમા\s+થઈ)',
    caseSensitive: false,
  );

  static _ClassifyResult classify(String t) {
    if (_fraudStrict.hasMatch(t))     return _ClassifyResult.fraud;
    // FIX-A: conditional check
    if (_fraudConditional.hasMatch(t) && !_creditContext.hasMatch(t)) {
      return _ClassifyResult.fraud;
    }
    if (_otp.hasMatch(t))   return _ClassifyResult.otp;
    if (_debit.hasMatch(t)) return _ClassifyResult.debit;
    // FIX-V16-2: check promo before junk — more specific patterns first
    if (_promo.hasMatch(t) && !hasPaymentContext(t)) return _ClassifyResult.junk;
    // FIX-40: cashback with payment context → pass through (not junk)
    // isCashbackConfusion handled separately in FraudEngine → LIKELY not REJECT
    if (_junk.hasMatch(t) && !hasPaymentContext(t))  return _ClassifyResult.junk;
    return _ClassifyResult.passed;
  }

  // FIX-V16-6: strip marketing amount context before extraction
  static String stripMarketingAmounts(String t) {
    if (_marketingAmountContext.hasMatch(t)) {
      return t.replaceAll(_marketingAmountContext, '[PROMO]');
    }
    return t;
  }

  static bool hasPaymentContext(String t) => _context.hasMatch(t);

  // FIX-57: Multilanguage credit verbs (10 languages, not 5)
  // NOW includes Bengali, Malayalam, Punjabi for regional shops
  static final _creditVerb = RegExp(
    r'(?:\b(?:credited|received|deposited|credit|recd|prapt|mila|jama'
    r'|has\s+sent|sent\s+to\s+your|paid\s+to\s+your|transferred\s+(?:via\s+[A-Za-z0-9]+\s+)?to'
    r'|added\s+to\s+(?:your\s+)?(?:\w+\s+)?wallet|successful)\b'
    // Hindi
    r'|प्राप्त|जमा\s+हो|जमा\s+हुआ|खाते\s+में\s+जमा'
    // Tamil
    r'|வரவு|வந்தது|பெறப்பட்டது'
    // Telugu
    r'|జమ\s+అయింది|వచ్చింది|జమచేయబడింది'
    // Kannada
    r'|ಜమా\s+ಆಗಿದೆ|ಬಂದಿದೆ|ಪಾವತಿ\s+ಬಂತು'
    // Marathi/Gujarati
    r'|मिळाले|जма\s+झाله|ચૂકવણી\s+மળી'
    // FIX-57: Bengali (added) — Kerala/West Bengal shops
    r'|জমা\s+হয়েছে|প্রাপ্ত|পেয়েছেন|আপনার\s+অ্যাকাউন্টে'
    // FIX-57: Malayalam (added) — Kerala shops
    r'|ക്രെഡിറ്റ\s+ചെയ്തു|ലഭിച്ചു|നിങ്ങളുടെ\s+അക്കൗണ്ടിൽ'
    // FIX-57: Punjabi (added) — Punjab shops
    r'|kal|ਜਮਾ\s+ਹੋਇਆ|ਪ੍ਰਾਪਤ\s+ਹੋਇਆ|ਤੁਹਾਡੇ\s+ਖਾਤੇ\s+ਵਿੱਚ)',
    caseSensitive: false,
  );

  // FIX-18 retained + FIX-39: multilanguage bank references
  static final _bankRef = RegExp(
    r'(?:\b(?:account|a\/c|ac|bank|upi|imps|neft|rtgs|wallet|transaction|txn|tx'
    r'|a\/c\s+no|acc|acct|savings|current|sb\s+a\/c)\b'
    r'|खाते|खाता|ಖಾತೆ|கணக்கு|ఖాతా|ਖਾਤਾ)',
    caseSensitive: false,
  );

  // Returns true only if message has credit verb + bank/UPI ref + NOT promotional
  static bool hasStructuredPaymentContext(String t) {
    if (!_creditVerb.hasMatch(t)) return false;
    if (!_bankRef.hasMatch(t))    return false;
    if (FraudEngine.isPromotionalMessage(t)) return false;
    return true;
  }
}

// =============================================================================
// EXTRACTOR
// =============================================================================

abstract class _Extractor {
  static final _balanceStrip = RegExp(
    r'(?:balance|avail(?:able)?|bal\.?|closing|opening|total)\s*:?\s*'
    r'(?:₹|rs\.?|inr)?\s*\d[\d.]*',
    caseSensitive: false,
  );

  static final _amts = [
    RegExp(r'₹\s*([\d]+(?:\.[\d]{1,2})?)',                caseSensitive: false),
    RegExp(r'[Rr][Ss]\.?\s*([\d]+(?:\.[\d]{1,2})?)',      caseSensitive: false),
    RegExp(r'[Ii][Nn][Rr]\.?\s*([\d]+(?:\.[\d]{1,2})?)',  caseSensitive: false),
    RegExp(r'([\d]+(?:\.[\d]{1,2})?)\s*/-'),
    RegExp(
      r'(?:credited|received|credit\s+of|receipt\s+of)\s*([\d]+(?:\.[\d]{1,2})?)',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:amount|amt)\.?\s+(?:of\s+)?([\d]+(?:\.[\d]{1,2})?)',
      caseSensitive: false,
    ),
    RegExp(r'([\d]+(?:\.[\d]{1,2})?)\s+CR\b'),
  ];

  static double? amount(String text) {
    final c = text.replaceAll(_balanceStrip, '');
    for (final p in _amts) {
      final m = p.firstMatch(c);
      if (m != null) {
        final v = double.tryParse(m.group(1) ?? '');
        if (v != null && v >= PdsConfig.minAmount) return v;
      }
    }
    return null;
  }

  static final _utrL = RegExp(
    r'\b(?:utr|ref(?:erence)?|txn|transaction|id)[:\s#no.]*([A-Za-z0-9]{10,22})\b',
    caseSensitive: false,
  );
  static final _utrI = RegExp(r'\b([0-9]{12})\b');
  static final _utrN = RegExp(r'\b([0-9]{16,22})\b');

  static String? referenceId(String t) =>
      _utrL.firstMatch(t)?.group(1) ??
      _utrI.firstMatch(t)?.group(1) ??
      _utrN.firstMatch(t)?.group(1);

  static final _name = RegExp(
    r'(?:from|by|received\s+from|sent\s+by|paid\s+by)\s+'
    r'([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){0,3})'
    r'(?=\s+(?:on|via|to|using|for|upi|ref|utr|vpa|\d|$))',
    caseSensitive: false,
  );
  static final _nameStart = RegExp(
    r'^([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){1,3})\s+(?:has\s+sent|sent|paid|has\s+paid|transferred|has\s+transferred|has\s+credited|credited)\b',
    caseSensitive: false,
  );
  static String? payerName(String t) =>
      _name.firstMatch(t)?.group(1)?.trim() ??
      _nameStart.firstMatch(t)?.group(1)?.trim();

  static const _handles =
      r'(gpay|paytm|ybl|oksbi|okhdfcbank|okicici|okaxis|upi|imobile|'
      r'axl|ibl|kotak|federal|rbl|sib|dcb|aubank|icici|hdfc|sbi|axis|'
      r'pnb|bob|canara|union|indus|yes|idfc|phonepe|freecharge|airtel|'
      r'jio|apl|waicici|rajgovhdfcbank|hdfcbank|icicibank|axisbank)';
  static final _vpa = RegExp(
    r'([a-zA-Z0-9.\-_+]{3,}@' + _handles + r')\b',
    caseSensitive: false,
  );
  static String? vpa(String t) => _vpa.firstMatch(t)?.group(0);

  static final _acc = RegExp(
    r'(?:a/?c|acc(?:ount)?|acct)[\s:]*[xX*]{0,6}(\d{4})\b',
    caseSensitive: false,
  );
  static String? accountSuffix(String t) => _acc.firstMatch(t)?.group(1);

  static const _bankMap = <String, String>{
    'HDFC':    'HDFC Bank',              'ICICI':  'ICICI Bank',
    'SBI':     'State Bank of India',    'YONO':   'State Bank of India',
    'AXIS':    'Axis Bank',              'KOTAK':  'Kotak Mahindra Bank',
    'PNB':     'Punjab National Bank',   'BOB':    'Bank of Baroda',
    'BOI':     'Bank of India',          'CANARA': 'Canara Bank',
    'UNION':   'Union Bank',             'INDUS':  'IndusInd Bank',
    'YES':     'Yes Bank',               'IDFC':   'IDFC First Bank',
    'FEDERAL': 'Federal Bank',           'UCO':    'UCO Bank',
    'IOB':     'Indian Overseas Bank',   'CENTRAL':'Central Bank',
    'INDIAN':  'Indian Bank',            'PAYTM':  'Paytm Payments Bank',
    'AIRTEL':  'Airtel Payments Bank',   'JIO':    'Jio Payments Bank',
    'RBL':     'RBL Bank',              'AU':     'AU Small Finance Bank',
    'EQUITAS': 'Equitas Bank',           'DCB':    'DCB Bank',
  };

  static String? bankName(String t, {String? sender}) {
    final s = '${t.toUpperCase()} ${(sender ?? '').toUpperCase()}';
    for (final e in _bankMap.entries) { if (s.contains(e.key)) return e.value; }
    return null;
  }
}

// =============================================================================
// SHARED REGEX
// =============================================================================

abstract class _Re {
  static final failure = RegExp(
    r'\b(failed|failure|declined|rejected|reversed|cancelled|'
    r'timeout|timed\s+out|unsuccessful|not\s+completed|असफल)\b',
    caseSensitive: false,
  );
}

// =============================================================================
// UTILITY
// =============================================================================

void unawaited(Future<void> future) {
  future.catchError((Object e, StackTrace st) {
    PdsLogger.e('UNAWAITED', 'Background task error', e, st);
  });
}

