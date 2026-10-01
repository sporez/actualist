import Foundation
import GRDB

/// Migration ids Actual 26.9.0 (`59fe126f`) ships in
/// `packages/loot-core/migrations`. Mock migrations under `src/mocks` are not
/// part of a real budget file and are omitted.
///
/// A portable file with no `__migrations__` table is still accepted: synthetic
/// seeds and older files have no watermark. An id that is not in this set is a
/// newer or unknown schema and is rejected. The named account-groups migration
/// (`BudgetDatabase.accountGroupsMigrationID`) is in the set.
enum PortableBudgetSchema {
    static let knownMigrationIDs: Set<Int64> = [
        1_548_957_970_627,
        1_550_601_598_648,
        1_555_786_194_328,
        1_561_751_833_510,
        1_567_699_552_727,
        1_582_384_163_573,
        1_597_756_566_448,
        1_608_652_596_043,
        1_608_652_596_044,
        1_612_625_548_236,
        1_614_782_639_336,
        1_615_745_967_948,
        1_616_167_010_796,
        1_618_975_177_358,
        1_632_571_489_012,
        1_679_728_867_040,
        1_681_115_033_845,
        1_682_974_838_138,
        1_685_007_876_842,
        1_686_139_660_866,
        1_688_749_527_273,
        1_688_841_238_000,
        1_691_233_396_000,
        1_694_438_752_000,
        1_697_046_240_000,
        1_704_572_023_730,
        1_704_572_023_731,
        1_707_267_033_000,
        1_712_784_523_000,
        1_716_359_441_000,
        1_720_310_586_000,
        1_720_664_867_241,
        1_720_665_000_000,
        1_722_717_601_000,
        1_722_804_019_000,
        1_723_665_565_000,
        1_730_744_182_000,
        1_736_640_000_000,
        1_737_158_400_000,
        1_738_491_452_000,
        1_739_139_550_000,
        1_740_506_588_539,
        1_745_425_408_000,
        1_749_799_110_000,
        1_749_799_110_001,
        1_754_611_200_000,
        1_759_260_219_000,
        1_759_842_823_172,
        1_762_178_745_667,
        1_765_518_577_215,
        1_768_872_504_000,
        1_769_000_000_000,
        1_778_510_362_740,
        1_780_099_200_000,
        1_780_327_681_000,
        1_780_606_215_000,
        1_780_606_215_001,
        1_783_004_650_757,
        BudgetDatabase.accountGroupsMigrationID
    ]

    static func rejectUnknownMigrations(in db: Database) throws {
        let tableExists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = '__migrations__'
                )
                """
        ) ?? false
        guard tableExists else {
            return
        }

        let ids: [Int64]
        do {
            ids = try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__")
        } catch {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .unsupportedSchema)
        }
        guard ids.allSatisfy(knownMigrationIDs.contains) else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .unsupportedSchema)
        }
    }
}
