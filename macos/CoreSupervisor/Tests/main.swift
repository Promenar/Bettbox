import Foundation
do { let cases = try runSSIFixtures(); print("IDENTITY_FIXTURES_PASS \(cases.count)") } catch { print("IDENTITY_FIXTURES_FAILED"); exit(1) }
