// Coarse location → city/state/country via reverse geocode.
// Cached in SharedPreferences for 24h so we don't re-prompt or re-geocode
// every time the user opens the Breaking News tab.

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Locality {
  final String city; // "Bengaluru"
  final String state; // "Karnataka"
  final String country; // "India"
  final String iso; // "IN" — ISO 3166-1 alpha-2
  const Locality({
    required this.city,
    required this.state,
    required this.country,
    required this.iso,
  });

  bool get isEmpty => city.isEmpty && state.isEmpty && country.isEmpty;

  Map<String, String> toMap() => {
        'city': city,
        'state': state,
        'country': country,
        'iso': iso,
      };

  factory Locality.fromMap(Map<String, String> m) => Locality(
        city: m['city'] ?? '',
        state: m['state'] ?? '',
        country: m['country'] ?? '',
        iso: m['iso'] ?? '',
      );
}

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const _prefsKey = 'cached_locality';
  static const _tsKey = 'cached_locality_ts';
  static const _ttl = Duration(hours: 24);

  /// One of: 'granted', 'denied' (user said no this time, can retry),
  /// 'permanently_denied' (user picked "don't ask again"), 'disabled'
  /// (location services are off at OS level).
  Future<String> permissionStatusLabel() async {
    if (!await Geolocator.isLocationServiceEnabled()) return 'disabled';
    final p = await Geolocator.checkPermission();
    if (p == LocationPermission.deniedForever) return 'permanently_denied';
    if (p == LocationPermission.denied) return 'denied';
    return 'granted';
  }

  /// Returns the cached Locality if fresh (< 24h). Doesn't touch GPS.
  Future<Locality?> readCached() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_tsKey);
    if (ts == null) return null;
    final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts));
    if (age > _ttl) return null;
    final city = prefs.getString('$_prefsKey:city') ?? '';
    if (city.isEmpty) return null;
    return Locality(
      city: city,
      state: prefs.getString('$_prefsKey:state') ?? '',
      country: prefs.getString('$_prefsKey:country') ?? '',
      iso: prefs.getString('$_prefsKey:iso') ?? '',
    );
  }

  /// Asks for permission if not yet granted, gets a coarse fix, reverse
  /// geocodes, caches, and returns. Returns null when:
  ///   - user denies permission
  ///   - location services are off
  ///   - reverse geocode fails
  /// Throws nothing — failures land as null with a printed diagnostic.
  Future<Locality?> resolveLocality() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        print('[Location] services disabled');
        return null;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        print('[Location] permission $perm');
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final places = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (places.isEmpty) {
        print('[Location] no placemark');
        return null;
      }
      final p = places.first;
      final locality = Locality(
        city: (p.locality ?? p.subAdministrativeArea ?? '').trim(),
        state: (p.administrativeArea ?? '').trim(),
        country: (p.country ?? '').trim(),
        iso: (p.isoCountryCode ?? '').trim().toUpperCase(),
      );
      await _writeCache(locality);
      return locality;
    } catch (e) {
      print('[Location] resolve failed: $e');
      return null;
    }
  }

  Future<void> _writeCache(Locality l) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefsKey:city', l.city);
    await prefs.setString('$_prefsKey:state', l.state);
    await prefs.setString('$_prefsKey:country', l.country);
    await prefs.setString('$_prefsKey:iso', l.iso);
    await prefs.setInt(_tsKey, DateTime.now().millisecondsSinceEpoch);
  }
}
