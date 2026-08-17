import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/sync_contract.dart';

void main() {
  test('lease validity and fencing fields are preserved', () {
    final now = DateTime.utc(2026, 1, 1);
    final lease = SyncLease(
      catalogIdentity: 'catalog', ownerDeviceId: 'device-a',
      ownerDeviceName: 'Laptop', generation: '4', token: 'opaque-token',
      issuedAt: now, expiresAt: now.add(const Duration(minutes: 5)),
      lastRenewedAt: now,
    );
    expect(lease.isValidAt(now), isTrue);
    expect(lease.isValidAt(now.add(const Duration(minutes: 6))), isFalse);
    expect(lease.generation, '4');
  });

  test('contention and lease loss are distinguishable', () {
    final lease = SyncLease(
      catalogIdentity: 'catalog', ownerDeviceId: 'device-a',
      ownerDeviceName: 'Laptop', generation: '1', token: 't',
      issuedAt: DateTime.utc(2026), expiresAt: DateTime.utc(2027),
      lastRenewedAt: DateTime.utc(2026),
    );
    expect(SyncLeaseContendedException(lease).toString(), contains('owned'));
    expect(const SyncLeaseLostException().toString(), contains('lost'));
  });
}
