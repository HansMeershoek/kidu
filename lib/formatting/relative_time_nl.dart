/// Dutch relative time phrases for dashboards and settings summaries.
///
/// Uses elapsed wall-clock duration (no calendar dates or clock times).
String formatRelativeTimeNl(DateTime value, {DateTime? now}) {
  final reference = (now ?? DateTime.now()).toLocal();
  final v = value.toLocal();

  if (!v.isBefore(reference)) return 'Zojuist';

  final diff = reference.difference(v);

  // < 1 minute
  if (diff < const Duration(minutes: 1)) return 'Zojuist';

  // 1–59 minutes (sub-hour)
  if (diff < const Duration(hours: 1)) {
    final minutes = diff.inMinutes.clamp(1, 59);
    return minutes == 1 ? '1 minuut geleden' : '$minutes minuten geleden';
  }

  // 1–23 hours (sub-day)
  if (diff < const Duration(days: 1)) {
    final hours = diff.inHours.clamp(1, 23);
    return hours == 1 ? '1 uur geleden' : '$hours uur geleden';
  }

  final days = diff.inDays;

  // 1–6 days (sub-week)
  if (days >= 1 && days < 7) {
    return days == 1 ? '1 dag geleden' : '$days dagen geleden';
  }

  // Whole weeks vs years: at most 52 full week units, otherwise years-by-days.
  final weekCount = (days + 6) ~/ 7;
  if (weekCount <= 52) {
    return weekCount == 1 ? '1 week geleden' : '$weekCount weken geleden';
  }

  final yearsRaw = days ~/ 365;
  final years = yearsRaw < 1 ? 1 : yearsRaw;

  if (years >= 100) return '99 jaar geleden';
  return years == 1 ? '1 jaar geleden' : '$years jaar geleden';
}
