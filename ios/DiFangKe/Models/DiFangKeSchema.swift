import SwiftData

enum DiFangKeSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Footprint.self,
            Place.self,
            TransportManualSelection.self,
            ActivityType.self,
            DailyInsight.self,
            TransportRecord.self
        ]
    }
}

enum DiFangKeSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Footprint.self,
            Place.self,
            TransportManualSelection.self,
            ActivityType.self,
            DailyInsight.self,
            TransportRecord.self,
            FutureTrip.self
        ]
    }
}

enum DiFangKeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DiFangKeSchemaV1.self, DiFangKeSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: DiFangKeSchemaV1.self, toVersion: DiFangKeSchemaV2.self)
        ]
    }
}
